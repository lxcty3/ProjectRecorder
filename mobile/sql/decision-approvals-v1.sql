-- ============================================================
-- Project Recorder - Phase 2A decision center and unified approvals
--
-- Deployment order:
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   unified-platform.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--
-- All business tables stay private. Clients read and write through the
-- SECURITY DEFINER RPCs at the end of this file.
-- ============================================================

-- ------------------------------------------------------------ decision queue
create table if not exists public.decision_items (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  source_type text not null
    check (source_type in ('task','project','worklog','approval',
                           'identity_motion','change','governance',
                           'finance','risk','manual')),
  source_id uuid,
  title text not null,
  detail text not null default '',
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  impact_days integer not null default 0 check (impact_days >= 0),
  impact_amount numeric not null default 0 check (impact_amount >= 0),
  waiting_since timestamptz not null default now(),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  status text not null default 'open'
    check (status in ('open','acknowledged','assigned','deferred',
                      'resolved','dismissed')),
  resolution text not null default '',
  due_at timestamptz not null default (now() + interval '3 days'),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, source_type, source_id)
);

create index if not exists decision_items_queue_idx
  on public.decision_items(enterprise_id, status, due_at, risk);

create table if not exists public.decision_events (
  id bigint generated always as identity primary key,
  decision_id uuid not null
    references public.decision_items(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  note text not null default '',
  idempotency_key text not null default '',
  created_at timestamptz not null default now()
);

create unique index if not exists decision_event_idempotency_idx
  on public.decision_events(decision_id, idempotency_key)
  where idempotency_key <> '';

-- ------------------------------------------------------------ approval inbox
create table if not exists public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  kind text not null
    check (kind in ('leave','worklog','expense','purchase','reward',
                    'task_extension','identity_motion')),
  source_id uuid not null,
  requester_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  title text not null,
  detail text not null default '',
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  amount numeric not null default 0 check (amount >= 0),
  impact_days integer not null default 0 check (impact_days >= 0),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  required_level text not null default 'manager'
    check (required_level in ('manager','executive')),
  required_permission text not null,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','returned','cancelled')),
  idempotency_key text not null default '',
  decision_note text not null default '',
  due_at timestamptz not null default (now() + interval '2 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, kind, source_id)
);

create unique index if not exists approval_idempotency_idx
  on public.approval_requests(enterprise_id, idempotency_key)
  where idempotency_key <> '';

create index if not exists approval_inbox_idx
  on public.approval_requests(enterprise_id, status, due_at, risk);

create table if not exists public.approval_events (
  id bigint generated always as identity primary key,
  approval_id uuid not null
    references public.approval_requests(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  note text not null default '',
  idempotency_key text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists approval_event_idempotency_idx
  on public.approval_events(approval_id, idempotency_key)
  where idempotency_key <> '';

alter table public.decision_items enable row level security;
alter table public.decision_events enable row level security;
alter table public.approval_requests enable row level security;
alter table public.approval_events enable row level security;

revoke all on table public.decision_items from public;
revoke all on table public.decision_items from anon;
revoke all on table public.decision_items from authenticated;
revoke all on table public.decision_events from public;
revoke all on table public.decision_events from anon;
revoke all on table public.decision_events from authenticated;
revoke all on table public.approval_requests from public;
revoke all on table public.approval_requests from anon;
revoke all on table public.approval_requests from authenticated;
revoke all on table public.approval_events from public;
revoke all on table public.approval_events from anon;
revoke all on table public.approval_events from authenticated;

-- ------------------------------------------------------------ pure helpers
create or replace function public._decision_risk(p_risk text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v text:=lower(btrim(coalesce(p_risk,'healthy')));
begin
  if v in ('severe','critical') then return 'severe'; end if;
  if v in ('risk','high') then return 'risk'; end if;
  if v in ('attention','medium','') then return 'attention'; end if;
  if v='healthy' or v='low' then return 'healthy'; end if;
  return 'attention';
end;
$fn$;

create or replace function public._decision_risk_weight(p_risk text)
returns integer
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return case public._decision_risk(p_risk)
    when 'severe' then 50
    when 'risk' then 35
    when 'attention' then 20
    else 0
  end;
end;
$fn$;

create or replace function public._decision_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permission text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  v_permissions:=public._identity_role_permissions(p_eid,p_uid);
  return coalesce(v_permissions ? p_permission,false);
end;
$fn$;

create or replace function public._decision_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  v_permissions:=public._identity_role_permissions(p_eid,p_uid);
  return coalesce(
    v_permissions ?| array[
      'company.manage','projects.view_all','projects.manage',
      'people.view_all','people.manage','worklogs.approve',
      'tasks.assign','tasks.grade','finance.view','finance.manage',
      'reports.view','audit.read','rewards.manage','leave.approve',
      'identity.manage_templates','identity.manage_shares',
      'governance.manage','governance.vote'
    ]::text[],
    false
  );
end;
$fn$;

create or replace function public._decision_is_executive(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if exists(
    select 1 from public.enterprises e
     where e.id=p_eid and e.owner_profile_id=p_uid
  ) then
    return true;
  end if;
  return exists(
    select 1
      from public.enterprise_members m
      join public.enterprise_role_catalog r on r.key=m.role_key
     where m.enterprise_id=p_eid
       and m.profile_id=p_uid
       and m.status='active'
       and r.rank>=75
  );
end;
$fn$;

create or replace function public._decision_approval_permission(p_kind text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return case lower(coalesce(p_kind,''))
    when 'leave' then 'leave.approve'
    when 'worklog' then 'worklogs.approve'
    when 'expense' then 'finance.manage'
    when 'purchase' then 'finance.manage'
    when 'reward' then 'rewards.manage'
    when 'task_extension' then 'tasks.grade'
    when 'identity_motion' then 'governance.vote'
    else ''
  end;
end;
$fn$;

create or replace function public._decision_required_level(
  p_amount numeric,
  p_risk text
) returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if public._decision_risk(p_risk) in ('severe','risk')
     or coalesce(p_amount,0)>=50000 then
    return 'executive';
  end if;
  return 'manager';
end;
$fn$;

create or replace function public._decision_approval_can_act(
  p_eid uuid,
  p_kind text,
  p_action text,
  p_uid uuid,
  p_requester uuid,
  p_owner uuid,
  p_amount numeric,
  p_risk text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_action text:=lower(coalesce(p_action,''));
  v_kind text:=lower(coalesce(p_kind,''));
  v_required text:=public._decision_approval_permission(p_kind);
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if v_action='cancelled' then
    if v_kind='identity_motion' then
      return p_uid in (p_requester,p_owner);
    end if;
    return p_uid in (p_requester,p_owner)
      or public._decision_has_permission(p_eid,p_uid,v_required);
  end if;
  if v_action not in ('approved','rejected','returned') then
    return false;
  end if;
  if v_kind='identity_motion' then
    if v_action='returned' then return false; end if;
    return (
      public._decision_has_permission(p_eid,p_uid,'governance.vote')
      or public._decision_has_permission(p_eid,p_uid,'governance.manage')
    ) and public._identity_shares(p_eid,p_uid)>0;
  end if;
  if v_required='' then return false; end if;
  if not public._decision_has_permission(p_eid,p_uid,v_required) then
    return false;
  end if;
  if public._decision_required_level(p_amount,p_risk)='executive'
     and not public._decision_is_executive(p_eid,p_uid) then
    return false;
  end if;
  return true;
end;
$fn$;

create or replace function public._decision_actions(
  p_eid uuid,
  p_uid uuid,
  p_status text,
  p_owner uuid
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_open boolean:=coalesce(p_status,'open') in
  ('open','acknowledged','assigned','deferred');
begin
  if not v_open then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'acknowledge',true,
    'assign',true,
    'defer',true,
    'resolve',true,
    'dismiss',true
  );
end;
$fn$;

create or replace function public._approval_actions(
  p_eid uuid,
  p_uid uuid,
  p_kind text,
  p_status text,
  p_requester uuid,
  p_owner uuid,
  p_amount numeric,
  p_risk text
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if coalesce(p_status,'pending')<>'pending' then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'approve',public._decision_approval_can_act(
      p_eid,p_kind,'approved',p_uid,p_requester,p_owner,p_amount,p_risk),
    'reject',public._decision_approval_can_act(
      p_eid,p_kind,'rejected',p_uid,p_requester,p_owner,p_amount,p_risk),
    'return',public._decision_approval_can_act(
      p_eid,p_kind,'returned',p_uid,p_requester,p_owner,p_amount,p_risk),
    'cancel',public._decision_approval_can_act(
      p_eid,p_kind,'cancelled',p_uid,p_requester,p_owner,p_amount,p_risk)
  );
end;
$fn$;

-- ------------------------------------------------------------ approval source sync
alter table public.task_requests drop constraint if exists task_requests_status_check;
alter table public.task_requests
  add constraint task_requests_status_check
  check (status in ('pending','approved','rejected','returned','cancelled'));

create or replace function public._decision_upsert_approval(
  p_eid uuid,
  p_kind text,
  p_source uuid,
  p_requester uuid,
  p_owner uuid,
  p_title text,
  p_detail text,
  p_evidence jsonb,
  p_amount numeric,
  p_impact_days integer,
  p_risk text,
  p_due_at timestamptz,
  p_status text,
  p_created_at timestamptz
) returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_id uuid;
  v_risk text:=public._decision_risk(p_risk);
  v_permission text:=public._decision_approval_permission(p_kind);
begin
  insert into public.approval_requests(
    enterprise_id,kind,source_id,requester_profile_id,owner_profile_id,
    title,detail,evidence,amount,impact_days,risk,required_level,
    required_permission,status,idempotency_key,due_at,created_at,updated_at
  ) values(
    p_eid,p_kind,p_source,p_requester,p_owner,
    coalesce(nullif(btrim(p_title),''),p_kind),
    coalesce(p_detail,''),
    coalesce(p_evidence,'[]'::jsonb),
    greatest(coalesce(p_amount,0),0),
    greatest(coalesce(p_impact_days,0),0),
    v_risk,
    public._decision_required_level(p_amount,p_risk),
    v_permission,
    p_status,
    p_kind||':'||p_source::text,
    coalesce(p_due_at,now()+interval '2 days'),
    coalesce(p_created_at,now()),
    now()
  )
  on conflict (enterprise_id,kind,source_id) do update set
    requester_profile_id=excluded.requester_profile_id,
    owner_profile_id=excluded.owner_profile_id,
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    amount=excluded.amount,
    impact_days=excluded.impact_days,
    risk=excluded.risk,
    required_level=excluded.required_level,
    required_permission=excluded.required_permission,
    status=excluded.status,
    due_at=excluded.due_at,
    updated_at=now()
  returning id into v_id;
  return v_id;
end;
$fn$;

create or replace function public._decision_sync_leave()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_days integer:=greatest(0,ceil(coalesce(NEW.days,0))::integer);
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when v_days>=10 then 'severe'
    when v_days>=4 then 'risk'
    else 'attention'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'leave',NEW.id,NEW.profile_id,NEW.boss_id,
    'Leave '||NEW.from_date::text||' to '||NEW.to_date::text,
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','leave_request','id',NEW.id,'from_date',NEW.from_date,
      'to_date',NEW.to_date,'days',NEW.days,'status',NEW.status)),
    v_days,v_days,v_risk,
    NEW.created_at+interval '2 days',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_worklog()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_status text:=case lower(coalesce(NEW.approval_status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when coalesce(NEW.hours,0)>16 then 'risk'
    when coalesce(NEW.hours,0)>12 then 'attention'
    else 'healthy'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'worklog',NEW.id,NEW.employee_id,NEW.boss_id,
    'Worklog '||NEW.work_date::text,
    coalesce(NEW.content,''),
    jsonb_build_array(jsonb_build_object(
      'type','worklog','id',NEW.id,'task_id',NEW.task_id,
      'work_date',NEW.work_date,'hours',NEW.hours,
      'status',NEW.approval_status)),
    coalesce(NEW.hours,0)*10,0,v_risk,
    NEW.work_date::timestamptz+interval '1 day',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_redemption()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'given' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when coalesce(NEW.cost,0)>=50000 then 'severe'
    when coalesce(NEW.cost,0)>=5000 then 'risk'
    when coalesce(NEW.cost,0)>=1000 then 'attention'
    else 'healthy'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'reward',NEW.id,NEW.profile_id,NEW.boss_id,
    'Reward: '||NEW.title,
    'Reward redemption',
    jsonb_build_array(jsonb_build_object(
      'type','redemption','id',NEW.id,'reward_id',NEW.reward_id,
      'cost',NEW.cost,'status',NEW.status)),
    NEW.cost,0,v_risk,
    NEW.created_at+interval '2 days',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_task_extension()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_plan_date date;
  v_task_title text:='Task';
  v_days integer:=0;
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text;
begin
  select t.plan_date,t.title into v_plan_date,v_task_title
    from public.tasks t where t.id=NEW.task_id;
  v_days:=greatest(0,coalesce(NEW.to_date-v_plan_date,0));
  v_risk:=case
    when v_days>=8 then 'severe'
    when v_days>=3 then 'risk'
    else 'attention'
  end;
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'task_extension',NEW.id,NEW.employee_id,NEW.boss_id,
    'Task extension: '||coalesce(v_task_title,'Task'),
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','task_request','id',NEW.id,'task_id',NEW.task_id,
      'plan_date',v_plan_date,'to_date',NEW.to_date,'status',NEW.status)),
    v_days,v_days,v_risk,
    NEW.created_at+interval '1 day',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_identity_motion()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_owner uuid;
  v_target text;
  v_status text:=case lower(coalesce(NEW.status,'open'))
    when 'passed' then 'approved'
    when 'rejected' then 'rejected'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
begin
  select e.owner_profile_id into v_owner
    from public.enterprises e where e.id=NEW.enterprise_id;
  select p.name into v_target
    from public.profiles p where p.id=NEW.target_profile_id;
  perform public._decision_upsert_approval(
    NEW.enterprise_id,
    'identity_motion',NEW.id,NEW.proposer_profile_id,v_owner,
    'Identity motion: '||NEW.kind||' '||coalesce(v_target,'member'),
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','identity_motion','id',NEW.id,'motion_kind',NEW.kind,
      'target_profile_id',NEW.target_profile_id,
      'proposed_role_key',NEW.proposed_role_key,
      'motion_class',NEW.motion_class,'status',NEW.status,
      'share_snapshot',NEW.share_snapshot)),
    0,0,'severe',NEW.closes_at,v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

drop trigger if exists trg_decision_sync_leave on public.leave_requests;
create trigger trg_decision_sync_leave
  after insert or update on public.leave_requests
  for each row execute function public._decision_sync_leave();

drop trigger if exists trg_decision_sync_worklog on public.worklogs;
create trigger trg_decision_sync_worklog
  after insert or update on public.worklogs
  for each row execute function public._decision_sync_worklog();

drop trigger if exists trg_decision_sync_redemption on public.redemptions;
create trigger trg_decision_sync_redemption
  after insert or update on public.redemptions
  for each row execute function public._decision_sync_redemption();

drop trigger if exists trg_decision_sync_task_extension on public.task_requests;
create trigger trg_decision_sync_task_extension
  after insert or update on public.task_requests
  for each row execute function public._decision_sync_task_extension();

drop trigger if exists trg_decision_sync_identity_motion
  on public.enterprise_role_motions;
create trigger trg_decision_sync_identity_motion
  after insert or update on public.enterprise_role_motions
  for each row execute function public._decision_sync_identity_motion();

-- Backfill rows created before this migration.
select public._decision_upsert_approval(
  public._identity_bootstrap(l.boss_id),'leave',l.id,l.profile_id,l.boss_id,
  'Leave '||l.from_date::text||' to '||l.to_date::text,
  coalesce(l.reason,''),
  jsonb_build_array(jsonb_build_object('type','leave_request','id',l.id)),
  greatest(0,ceil(coalesce(l.days,0))::integer),
  greatest(0,ceil(coalesce(l.days,0))::integer),
  case when l.days>=10 then 'severe'
       when l.days>=4 then 'risk' else 'attention' end,
  l.created_at+interval '2 days',
  case lower(coalesce(l.status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  l.created_at
)
from public.leave_requests l;

select public._decision_upsert_approval(
  public._identity_bootstrap(w.boss_id),'worklog',w.id,w.employee_id,w.boss_id,
  'Worklog '||w.work_date::text,coalesce(w.content,''),
  jsonb_build_array(jsonb_build_object('type','worklog','id',w.id)),
  coalesce(w.hours,0)*10,0,
  case when coalesce(w.hours,0)>16 then 'risk'
       when coalesce(w.hours,0)>12 then 'attention' else 'healthy' end,
  w.work_date::timestamptz+interval '1 day',
  case lower(coalesce(w.approval_status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  w.created_at
)
from public.worklogs w;

select public._decision_upsert_approval(
  public._identity_bootstrap(r.boss_id),'reward',r.id,r.profile_id,r.boss_id,
  'Reward: '||r.title,'Reward redemption',
  jsonb_build_array(jsonb_build_object('type','redemption','id',r.id)),
  r.cost,0,
  case when r.cost>=50000 then 'severe'
       when r.cost>=5000 then 'risk'
       when r.cost>=1000 then 'attention' else 'healthy' end,
  r.created_at+interval '2 days',
  case lower(coalesce(r.status,'pending'))
    when 'approved' then 'approved' when 'given' then 'approved'
    when 'rejected' then 'rejected' when 'returned' then 'returned'
    when 'cancelled' then 'cancelled' else 'pending' end,
  r.created_at
)
from public.redemptions r;

select public._decision_upsert_approval(
  public._identity_bootstrap(q.boss_id),'task_extension',q.id,q.employee_id,q.boss_id,
  'Task extension: '||coalesce(t.title,'Task'),coalesce(q.reason,''),
  jsonb_build_array(jsonb_build_object('type','task_request','id',q.id)),
  greatest(0,coalesce(q.to_date-t.plan_date,0)),
  greatest(0,coalesce(q.to_date-t.plan_date,0)),
  case when coalesce(q.to_date-t.plan_date,0)>=8 then 'severe'
       when coalesce(q.to_date-t.plan_date,0)>=3 then 'risk'
       else 'attention' end,
  q.created_at+interval '1 day',
  case lower(coalesce(q.status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  q.created_at
)
from public.task_requests q
left join public.tasks t on t.id=q.task_id;

select public._decision_upsert_approval(
  m.enterprise_id,'identity_motion',m.id,m.proposer_profile_id,e.owner_profile_id,
  'Identity motion: '||m.kind,
  coalesce(m.reason,''),
  jsonb_build_array(jsonb_build_object(
    'type','identity_motion','id',m.id,'motion_class',m.motion_class,
    'share_snapshot',m.share_snapshot)),
  0,0,'severe',m.closes_at,
  case lower(coalesce(m.status,'open'))
    when 'passed' then 'approved' when 'rejected' then 'rejected'
    when 'cancelled' then 'cancelled' else 'pending' end,
  m.created_at
)
from public.enterprise_role_motions m
join public.enterprises e on e.id=m.enterprise_id;

-- ------------------------------------------------------------ decision generation
create or replace function public._decision_refresh(
  p_eid uuid,
  p_uid uuid
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  -- Revalidate source records before rendering the queue. Manual dismissal and
  -- resolution are retained, while source completion closes generated items.
  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then
           'Source approval is no longer pending' else d.resolution end,
         version=d.version+1,
         updated_at=now()
   where d.enterprise_id=p_eid
     and d.source_type='approval'
     and d.status in ('open','acknowledged','assigned','deferred')
     and exists(
       select 1 from public.approval_requests a
        where a.id=d.source_id and a.status<>'pending');

  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then
           'Task now has completion evidence' else d.resolution end,
         version=d.version+1,
         updated_at=now()
   where d.enterprise_id=p_eid
     and d.source_type='task'
     and d.status in ('open','acknowledged','assigned','deferred')
     and exists(select 1 from public.task_logs l where l.task_id=d.source_id);

  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    a.enterprise_id,'approval',a.id,
    'Approval: '||a.title,a.detail,a.evidence,a.risk,
    a.impact_days,a.amount,a.created_at,a.owner_profile_id,'open','',
    a.due_at,a.created_at,now()
  from public.approval_requests a
  where a.enterprise_id=p_eid
    and a.status='pending'
    and (
      a.required_level='executive'
      or a.risk in ('severe','risk')
      or a.impact_days>=3
      or a.due_at<=now()+interval '1 day'
    )
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    risk=excluded.risk,
    impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,
    owner_profile_id=excluded.owner_profile_id,
    due_at=excluded.due_at,
    updated_at=now();

  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    public._identity_bootstrap(t.boss_id),'task',t.id,
    'Overdue task: '||t.title,
    coalesce(t.detail,''),
    jsonb_build_array(jsonb_build_object(
      'type','task','id',t.id,'plan_date',t.plan_date,
      'accept_status',t.accept_status,'est_hours',t.est_hours)),
    case when current_date-t.plan_date>=5 then 'severe'
         when current_date-t.plan_date>=2 then 'risk'
         else 'attention' end,
    greatest(0,current_date-t.plan_date),0,
    t.plan_date::timestamptz,t.employee_id,'open','',
    t.plan_date::timestamptz,t.plan_date::timestamptz,now()
  from public.tasks t
  where t.boss_id=(select e.owner_profile_id
                    from public.enterprises e where e.id=p_eid)
    and t.plan_date<current_date
    and not exists(select 1 from public.task_logs l where l.task_id=t.id)
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    risk=excluded.risk,
    impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,
    owner_profile_id=excluded.owner_profile_id,
    due_at=excluded.due_at,
    updated_at=now();
end;
$fn$;

create or replace function public.get_decision_center()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._decision_has_management(v_eid,v_uid) then
    raise exception 'management permission required';
  end if;

  perform public._decision_refresh(v_eid,v_uid);

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'decisions',(
      select coalesce(jsonb_agg(
        to_jsonb(d)||jsonb_build_object(
          'owner_name',coalesce(p.name,''),
          'actions',public._decision_actions(
            v_eid,v_uid,d.status,d.owner_profile_id)
        ) order by
          (d.impact_days*4+d.impact_amount/10000
           +public._decision_risk_weight(d.risk)) desc,
          d.due_at,d.created_at
      ),'[]'::jsonb)
      from public.decision_items d
      left join public.profiles p on p.id=d.owner_profile_id
      where d.enterprise_id=v_eid
        and d.status in ('open','acknowledged','assigned','deferred')
    ),
    'approvals',(
      select coalesce(jsonb_agg(
        to_jsonb(a)||jsonb_build_object(
          'requester_name',coalesce(rp.name,''),
          'owner_name',coalesce(op.name,''),
          'actions',public._approval_actions(
            v_eid,v_uid,a.kind,a.status,a.requester_profile_id,
            a.owner_profile_id,a.amount,a.risk)
        ) order by
          (a.impact_days*4+a.amount/10000
           +public._decision_risk_weight(a.risk)) desc,
          a.due_at,a.created_at
      ),'[]'::jsonb)
      from public.approval_requests a
      left join public.profiles rp on rp.id=a.requester_profile_id
      left join public.profiles op on op.id=a.owner_profile_id
      where a.enterprise_id=v_eid and a.status='pending'
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',m.profile_id,'name',p.name,'role_key',m.role_key
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
    )
  );
end;
$fn$;

-- ------------------------------------------------------------ decision actions
create or replace function public.act_on_decision(
  p_decision uuid,
  p_action text,
  p_owner uuid default null,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.decision_items%rowtype;
  v_action text:=lower(btrim(coalesce(p_action,'')));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_note text:=btrim(coalesce(p_note,''));
  v_existing_action text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_key='' then raise exception 'idempotency key required'; end if;
  select * into v_row from public.decision_items
   where id=p_decision for update;
  if not found then raise exception 'decision not found'; end if;
  if not public._decision_has_management(v_row.enterprise_id,v_uid) then
    raise exception 'management permission required';
  end if;

  select action into v_existing_action
    from public.decision_events
   where decision_id=p_decision and idempotency_key=v_key
   order by id desc limit 1;
  if found then
    if v_existing_action<>v_action then
      raise exception 'idempotency key already used for another action';
    end if;
    return jsonb_build_object(
      'ok',true,'status',v_row.status,'duplicate',true);
  end if;

  if v_action not in ('acknowledged','assigned','deferred',
                      'resolved','dismissed') then
    raise exception 'invalid action';
  end if;
  if v_row.status not in ('open','acknowledged','assigned','deferred') then
    if v_row.status=v_action then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'decision already closed';
  end if;
  if v_action='assigned' then
    if p_owner is null and v_row.owner_profile_id is null then
      raise exception 'owner required';
    end if;
    if p_owner is not null and not public._identity_is_member(
      v_row.enterprise_id,p_owner
    ) then
      raise exception 'owner must be an active enterprise member';
    end if;
  end if;
  if v_action in ('deferred','dismissed') and v_note='' then
    raise exception 'note required';
  end if;

  update public.decision_items set
    status=v_action,
    owner_profile_id=case when v_action='assigned'
      then coalesce(p_owner,owner_profile_id) else owner_profile_id end,
    resolution=case when v_action in ('resolved','dismissed')
      then v_note else resolution end,
    version=version+1,
    updated_at=now()
  where id=p_decision;

  insert into public.decision_events(
    decision_id,actor_profile_id,action,note,idempotency_key
  ) values(p_decision,v_uid,v_action,v_note,v_key);

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'decision.'||v_action,
    coalesce(p_owner,v_row.owner_profile_id),
    jsonb_build_object('decision_id',p_decision,'note',v_note,
                       'idempotency_key',v_key)
  );

  return jsonb_build_object(
    'ok',true,'status',v_action,'duplicate',false);
end;
$fn$;

-- ------------------------------------------------------------ approval actions
create or replace function public.act_on_approval(
  p_approval uuid,
  p_action text,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.approval_requests%rowtype;
  v_action text:=lower(btrim(coalesce(p_action,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_required text;
  v_existing_action text;
  v_worklog public.worklogs%rowtype;
  v_redemption public.redemptions%rowtype;
  v_request public.task_requests%rowtype;
  v_task public.tasks%rowtype;
  v_points integer:=0;
  v_vote jsonb;
  v_motion_status text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_key='' then raise exception 'idempotency key required'; end if;
  select * into v_row from public.approval_requests
   where id=p_approval for update;
  if not found then raise exception 'approval not found'; end if;

  select action into v_existing_action
    from public.approval_events
   where approval_id=p_approval and idempotency_key=v_key
   order by id desc limit 1;
  if found then
    if v_existing_action<>v_action
       and not (v_row.kind='identity_motion'
                and v_existing_action=case v_action
                  when 'approved' then 'vote_yes'
                  when 'rejected' then 'vote_no'
                  else '' end) then
      raise exception 'idempotency key already used for another action';
    end if;
    return jsonb_build_object(
      'ok',true,'status',v_row.status,'duplicate',true);
  end if;

  if v_action not in ('approved','rejected','returned','cancelled') then
    raise exception 'invalid action';
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_action then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'approval already decided';
  end if;
  if not public._identity_is_member(v_row.enterprise_id,v_uid) then
    raise exception 'approval permission required';
  end if;

  if v_row.kind='identity_motion' then
    if v_action='returned' then
      raise exception 'identity motions are decided by shareholder vote';
    end if;
    if v_action='cancelled' then
      if v_uid not in (v_row.requester_profile_id,v_row.owner_profile_id) then
        raise exception 'approval permission required';
      end if;
      perform public.cancel_enterprise_role_vote(v_row.source_id);
      insert into public.approval_events(
        approval_id,actor_profile_id,action,note,idempotency_key,metadata
      ) values(
        p_approval,v_uid,'cancelled',v_note,v_key,
        jsonb_build_object('motion_id',v_row.source_id));
      insert into public.enterprise_identity_audit(
        enterprise_id,actor_profile_id,action,target_profile_id,details
      ) values(
        v_row.enterprise_id,v_uid,'approval.cancelled',null,
        jsonb_build_object('approval_id',p_approval,'kind',v_row.kind,
                           'note',v_note,'idempotency_key',v_key));
      return jsonb_build_object(
        'ok',true,'status','cancelled','duplicate',false);
    end if;
    if not (
      public._decision_has_permission(
        v_row.enterprise_id,v_uid,'governance.vote')
      or public._decision_has_permission(
        v_row.enterprise_id,v_uid,'governance.manage')
    ) or public._identity_shares(v_row.enterprise_id,v_uid)<=0 then
      raise exception 'only shareholders may vote';
    end if;

    v_vote:=public.cast_enterprise_role_vote(
      v_row.source_id,
      case v_action when 'approved' then 'yes' else 'no' end
    );
    select status into v_motion_status
      from public.enterprise_role_motions where id=v_row.source_id;
    insert into public.approval_events(
      approval_id,actor_profile_id,action,note,idempotency_key,metadata
    ) values(
      p_approval,v_uid,
      case v_action when 'approved' then 'vote_yes' else 'vote_no' end,
      v_note,v_key,
      jsonb_build_object('vote',v_vote,'motion_status',v_motion_status));
    insert into public.enterprise_identity_audit(
      enterprise_id,actor_profile_id,action,target_profile_id,details
    ) values(
      v_row.enterprise_id,v_uid,'approval.vote',v_row.requester_profile_id,
      jsonb_build_object('approval_id',p_approval,'motion_id',v_row.source_id,
                         'choice',case v_action when 'approved' then 'yes'
                           else 'no' end,'note',v_note,
                         'idempotency_key',v_key));
    select status into v_motion_status
      from public.approval_requests where id=p_approval;
    return jsonb_build_object(
      'ok',true,'status',v_motion_status,'duplicate',false,
      'vote',v_vote);
  end if;

  v_required:=public._decision_approval_permission(v_row.kind);
  if v_required='' or not public._decision_has_permission(
    v_row.enterprise_id,v_uid,v_required
  ) then
    raise exception 'approval permission required';
  end if;
  if public._decision_required_level(v_row.amount,v_row.risk)='executive'
     and not public._decision_is_executive(v_row.enterprise_id,v_uid) then
    raise exception 'executive approval required';
  end if;

  if v_row.kind='leave' then
    update public.leave_requests set
      status=v_action,
      decision_note=v_note,
      decided_at=now(),
      version=version+1
    where id=v_row.source_id;
  elsif v_row.kind='worklog' then
    select * into v_worklog from public.worklogs
     where id=v_row.source_id for update;
    if not found then raise exception 'worklog not found'; end if;
    update public.worklogs set
      approval_status=v_action,
      approved_by=case when v_action='approved' then v_uid
                       else approved_by end,
      approved_at=case when v_action='approved' then now()
                       else approved_at end,
      version=version+1
    where id=v_worklog.id;
    if v_action='approved' then
      v_points:=floor(least(greatest(v_worklog.hours,0),24)*10)::integer;
      if v_points<>0 and not exists(
        select 1 from public.merit_ledger
         where source_id=v_worklog.id and kind='hours'
      ) then
        insert into public.merit_ledger(
          boss_id,profile_id,amount,kind,reason,source_id,status,settled_at
        ) values(
          v_worklog.boss_id,v_worklog.employee_id,v_points,'hours','',
          v_worklog.id,'posted',now()
        );
      end if;
    end if;
  elsif v_row.kind='reward' then
    select * into v_redemption from public.redemptions
     where id=v_row.source_id for update;
    if not found then raise exception 'redemption not found'; end if;
    update public.redemptions set
      status=case when v_action='approved' then 'given' else v_action end,
      decided_at=now(),
      version=version+1
    where id=v_redemption.id;
    if v_action='approved' then
      if not exists(
        select 1 from public.merit_ledger
         where kind='redeem' and source_id=v_redemption.id
      ) then
        insert into public.merit_ledger(
          boss_id,profile_id,amount,kind,reason,source_id,status
        ) values(
          v_redemption.boss_id,v_redemption.profile_id,
          -v_redemption.cost,'redeem','',v_redemption.id,'posted'
        );
      end if;
      update public.rewards set
        stock=case when stock is null then null
                   else greatest(0,stock-1) end
      where id=v_redemption.reward_id;
    end if;
  elsif v_row.kind='task_extension' then
    select * into v_request from public.task_requests
     where id=v_row.source_id for update;
    if not found then raise exception 'task request not found'; end if;
    select * into v_task from public.tasks
     where id=v_request.task_id for update;
    if not found then raise exception 'task not found'; end if;
    update public.task_requests set
      status=v_action,
      decision_note=v_note,
      decided_at=now()
    where id=v_request.id;
    if v_action='approved' then
      update public.tasks set
        plan_date=v_request.to_date,
        updated_at=now()
      where id=v_task.id;
      insert into public.task_events(
        id,boss_id,employee_id,task_id,kind,title,work_date
      ) values(
        gen_random_uuid(),v_task.boss_id,v_task.employee_id,v_task.id,
        'extend_ok',v_task.title,v_request.to_date
      );
    elsif v_action='rejected' then
      insert into public.task_events(
        id,boss_id,employee_id,task_id,kind,title
      ) values(
        gen_random_uuid(),v_task.boss_id,v_task.employee_id,v_task.id,
        'extend_no',v_task.title
      );
    end if;
  end if;

  update public.approval_requests set
    status=v_action,
    decision_note=v_note,
    updated_at=now()
  where id=p_approval;

  insert into public.approval_events(
    approval_id,actor_profile_id,action,note,idempotency_key,metadata
  ) values(
    p_approval,v_uid,v_action,v_note,v_key,
    jsonb_build_object('kind',v_row.kind,'source_id',v_row.source_id)
  );

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'approval.'||v_action,
    v_row.requester_profile_id,
    jsonb_build_object('approval_id',p_approval,'kind',v_row.kind,
                       'source_id',v_row.source_id,'note',v_note,
                       'idempotency_key',v_key)
  );

  return jsonb_build_object(
    'ok',true,'status',v_action,'duplicate',false);
end;
$fn$;

-- ------------------------------------------------------------ least privilege
revoke all on function public._decision_risk(text) from public;
revoke all on function public._decision_risk(text) from anon;
revoke all on function public._decision_risk(text) from authenticated;
revoke all on function public._decision_risk_weight(text) from public;
revoke all on function public._decision_risk_weight(text) from anon;
revoke all on function public._decision_risk_weight(text) from authenticated;
revoke all on function public._decision_has_permission(uuid,uuid,text) from public;
revoke all on function public._decision_has_permission(uuid,uuid,text) from anon;
revoke all on function public._decision_has_permission(uuid,uuid,text) from authenticated;
revoke all on function public._decision_has_management(uuid,uuid) from public;
revoke all on function public._decision_has_management(uuid,uuid) from anon;
revoke all on function public._decision_has_management(uuid,uuid) from authenticated;
revoke all on function public._decision_is_executive(uuid,uuid) from public;
revoke all on function public._decision_is_executive(uuid,uuid) from anon;
revoke all on function public._decision_is_executive(uuid,uuid) from authenticated;
revoke all on function public._decision_approval_permission(text) from public;
revoke all on function public._decision_approval_permission(text) from anon;
revoke all on function public._decision_approval_permission(text) from authenticated;
revoke all on function public._decision_required_level(numeric,text) from public;
revoke all on function public._decision_required_level(numeric,text) from anon;
revoke all on function public._decision_required_level(numeric,text) from authenticated;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from public;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from anon;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from authenticated;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from public;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from anon;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from authenticated;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from public;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from anon;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from authenticated;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from public;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from anon;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from authenticated;
revoke all on function public._decision_refresh(uuid,uuid) from public;
revoke all on function public._decision_refresh(uuid,uuid) from anon;
revoke all on function public._decision_refresh(uuid,uuid) from authenticated;

revoke all on function public.get_decision_center() from public;
revoke all on function public.get_decision_center() from anon;
revoke all on function public.get_decision_center() from authenticated;
grant execute on function public.get_decision_center() to authenticated;

revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from public;
revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from anon;
revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from authenticated;
grant execute on function public.act_on_decision(uuid,text,uuid,text,text)
  to authenticated;

revoke all on function public.act_on_approval(uuid,text,text,text)
  from public;
revoke all on function public.act_on_approval(uuid,text,text,text)
  from anon;
revoke all on function public.act_on_approval(uuid,text,text,text)
  from authenticated;
grant execute on function public.act_on_approval(uuid,text,text,text)
  to authenticated;
