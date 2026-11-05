-- ============================================================
-- Project Recorder - Enterprise identity and share-weighted voting
--
-- Run this file once after unified-platform.sql.
-- All writes go through SECURITY DEFINER RPCs. Governance tables
-- are not writable through the public REST API.
-- ============================================================

-- ------------------------------------------------------------ role catalog
create table if not exists public.enterprise_role_catalog (
  key         text primary key,
  name        text not null,
  description text not null default '',
  permissions jsonb not null default '[]'::jsonb,
  rank        integer not null default 0
);

insert into public.enterprise_role_catalog(key,name,description,permissions,rank) values
('chairperson','Chairperson','Leads the board and company governance',
 '["company.manage","projects.view_all","projects.manage","people.view_all","people.manage","worklogs.approve","tasks.assign","tasks.grade","rewards.manage","leave.approve","finance.view","finance.manage","reports.view","audit.read","identity.view","community.post"]',100),
('director','Director','Sets strategy and supervises management',
 '["projects.view_all","people.view_all","finance.view","reports.view","audit.read","identity.view","community.post"]',90),
('supervisor','Supervisor','Independent oversight and audit',
 '["projects.view_all","people.view_all","finance.view","reports.view","audit.read","identity.view","community.post"]',80),
('ceo','Chief Executive','Runs daily operations and reports to the board',
 '["company.manage","projects.view_all","projects.manage","people.view_all","people.manage","worklogs.approve","tasks.assign","tasks.grade","rewards.manage","leave.approve","finance.view","reports.view","identity.view","community.post"]',75),
('vice_president','Vice President','Runs a major business or function',
 '["projects.view_all","projects.manage","people.view_all","worklogs.approve","tasks.assign","tasks.grade","reports.view","identity.view","community.post"]',65),
('department_manager','Department Manager','Owns a department, people and delivery',
 '["projects.manage","people.view_all","worklogs.approve","tasks.assign","tasks.grade","reports.view","identity.view","community.post"]',55),
('project_manager','Project Manager','Owns project delivery and task assignment',
 '["projects.manage","tasks.assign","tasks.grade","reports.view","identity.view","community.post"]',45),
('team_lead','Team Lead','Leads a delivery team and reviews work',
 '["projects.manage","worklogs.approve","tasks.assign","reports.view","identity.view","community.post"]',35),
('finance','Finance','Manages budgets, costs and financial controls',
 '["projects.view_all","finance.view","finance.manage","reports.view","identity.view","community.post"]',30),
('hr','Human Resources','Manages people records and appointments',
 '["people.view_all","people.manage","reports.view","identity.view","community.post"]',30),
('auditor','Auditor','Read-only operational and financial audit',
 '["projects.view_all","people.view_all","finance.view","reports.view","audit.read","identity.view","community.post"]',30),
('employee','Employee','Executes assigned work and participates in the community',
 '["community.post","identity.view"]',10)
on conflict (key) do update set
  name=excluded.name,
  description=excluded.description,
  permissions=excluded.permissions,
  rank=excluded.rank;

-- ------------------------------------------------------------ enterprises
create table if not exists public.enterprises (
  id                uuid primary key default gen_random_uuid(),
  owner_profile_id  uuid not null unique references public.profiles(id) on delete cascade,
  name              text not null default 'Enterprise',
  quorum_bps        integer not null default 5000 check (quorum_bps between 1 and 10000),
  approval_bps      integer not null default 5001 check (approval_bps between 1 and 10000),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table if not exists public.enterprise_members (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  role_key      text not null default 'employee' references public.enterprise_role_catalog(key),
  department    text not null default '',
  title         text not null default '',
  status        text not null default 'active' check (status in ('active','inactive')),
  appointed_by  uuid references public.profiles(id) on delete set null,
  appointed_at  timestamptz,
  updated_at    timestamptz not null default now(),
  primary key (enterprise_id, profile_id)
);

create table if not exists public.enterprise_shareholders (
  enterprise_id uuid not null,
  profile_id    uuid not null,
  shares        numeric(18,4) not null default 0 check (shares >= 0),
  updated_by    uuid references public.profiles(id) on delete set null,
  updated_at    timestamptz not null default now(),
  primary key (enterprise_id, profile_id),
  foreign key (enterprise_id, profile_id)
    references public.enterprise_members(enterprise_id, profile_id) on delete cascade
);

create table if not exists public.enterprise_role_motions (
  id                  uuid primary key default gen_random_uuid(),
  enterprise_id       uuid not null references public.enterprises(id) on delete cascade,
  kind                text not null check (kind in ('appointment','removal')),
  target_profile_id   uuid not null,
  proposed_role_key   text references public.enterprise_role_catalog(key),
  proposed_department text not null default '',
  proposed_title      text not null default '',
  reason              text not null default '',
  proposer_profile_id uuid not null references public.profiles(id) on delete cascade,
  status              text not null default 'open'
                        check (status in ('open','passed','rejected','cancelled')),
  quorum_bps          integer not null default 5000,
  approval_bps        integer not null default 5001,
  opens_at            timestamptz not null default now(),
  closes_at           timestamptz not null,
  decided_at          timestamptz,
  decision_reason     text not null default '',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  foreign key (enterprise_id, target_profile_id)
    references public.enterprise_members(enterprise_id, profile_id) on delete cascade
);

create unique index if not exists enterprise_one_open_motion_idx
  on public.enterprise_role_motions(enterprise_id, target_profile_id)
  where status = 'open';

create index if not exists enterprise_motion_status_idx
  on public.enterprise_role_motions(enterprise_id, status, closes_at desc);

create table if not exists public.enterprise_role_votes (
  motion_id        uuid not null references public.enterprise_role_motions(id) on delete cascade,
  voter_profile_id uuid not null references public.profiles(id) on delete cascade,
  choice           text not null check (choice in ('yes','no','abstain')),
  shares_at_vote   numeric(18,4) not null check (shares_at_vote >= 0),
  voted_at         timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (motion_id, voter_profile_id)
);

create table if not exists public.enterprise_identity_audit (
  id                bigserial primary key,
  enterprise_id     uuid not null references public.enterprises(id) on delete cascade,
  actor_profile_id  uuid references public.profiles(id) on delete set null,
  action            text not null,
  target_profile_id uuid references public.profiles(id) on delete set null,
  details           jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);

create index if not exists enterprise_audit_idx
  on public.enterprise_identity_audit(enterprise_id, created_at desc);

alter table public.enterprises enable row level security;
alter table public.enterprise_members enable row level security;
alter table public.enterprise_shareholders enable row level security;
alter table public.enterprise_role_motions enable row level security;
alter table public.enterprise_role_votes enable row level security;
alter table public.enterprise_identity_audit enable row level security;
alter table public.enterprise_role_catalog enable row level security;

drop policy if exists "authenticated reads role catalog" on public.enterprise_role_catalog;
create policy "authenticated reads role catalog" on public.enterprise_role_catalog
  for select to authenticated using (true);

-- No direct policies are created for the other governance tables.
-- Clients must use the checked RPCs below.

-- ------------------------------------------------------------ helpers
create or replace function public._identity_owner_for_uid(p_uid uuid)
returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(
    (select boss_id from public.profiles where id=p_uid),
    p_uid
  );
$fn$;

create or replace function public._identity_ensure_enterprise(p_owner uuid)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_id uuid;
  v_name text;
begin
  select id into v_id from public.enterprises where owner_profile_id=p_owner;
  if v_id is not null then return v_id; end if;

  select coalesce(nullif(trim(name),''),'Enterprise')||' Enterprise'
    into v_name from public.profiles where id=p_owner;
  if v_name is null then v_name:='Enterprise'; end if;

  insert into public.enterprises(owner_profile_id,name)
  values(p_owner,v_name)
  on conflict (owner_profile_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.enterprises where owner_profile_id=p_owner;
  end if;
  return v_id;
end;
$fn$;

create or replace function public._identity_bootstrap(p_owner uuid)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_eid uuid:=public._identity_ensure_enterprise(p_owner);
  v_total numeric;
begin
  insert into public.enterprise_members(enterprise_id,profile_id,role_key,title,status,appointed_at)
  select v_eid,p.id,
    case when p.id=p_owner then 'chairperson' else 'employee' end,
    case when p.id=p_owner then 'Founder' else '' end,
    'active',now()
  from public.profiles p
  where p.id=p_owner or p.boss_id=p_owner
  on conflict (enterprise_id,profile_id) do nothing;

  select coalesce(sum(shares),0) into v_total
    from public.enterprise_shareholders
   where enterprise_id=v_eid and shares>0;
  if v_total=0 then
    insert into public.enterprise_shareholders(enterprise_id,profile_id,shares,updated_by)
    values(v_eid,p_owner,100,p_owner)
    on conflict (enterprise_id,profile_id) do update
      set shares=excluded.shares,updated_by=excluded.updated_by,updated_at=now();
  end if;

  return v_eid;
end;
$fn$;

create or replace function public._identity_is_member(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
  );
$fn$;

create or replace function public._identity_shares(p_eid uuid,p_uid uuid)
returns numeric
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce((
    select s.shares from public.enterprise_shareholders s
     where s.enterprise_id=p_eid and s.profile_id=p_uid and s.shares>0
  ),0);
$fn$;

create or replace function public._identity_total_shares(p_eid uuid)
returns numeric
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(sum(s.shares),0)
    from public.enterprise_shareholders s
    join public.enterprise_members m
      on m.enterprise_id=s.enterprise_id and m.profile_id=s.profile_id
   where s.enterprise_id=p_eid and s.shares>0 and m.status='active';
$fn$;

create or replace function public._identity_role_permissions(p_eid uuid,p_uid uuid)
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_permissions jsonb:='[]'::jsonb;
  v_owner uuid;
begin
  select coalesce(r.permissions,'[]'::jsonb) into v_permissions
    from public.enterprise_members m
    join public.enterprise_role_catalog r on r.key=m.role_key
   where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active';
  v_permissions:=coalesce(v_permissions,'[]'::jsonb);

  if public._identity_shares(p_eid,p_uid)>0 then
    v_permissions:=v_permissions||'["identity.propose","identity.vote"]'::jsonb;
  end if;

  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  if v_owner=p_uid then
    v_permissions:=v_permissions||'["identity.manage_shares"]'::jsonb;
  end if;

  return (
    select coalesce(jsonb_agg(distinct value),'[]'::jsonb)
      from jsonb_array_elements_text(v_permissions) value
  );
end;
$fn$;

create or replace function public.identity_owner_id()
returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(
    (select boss_id from public.profiles where id=auth.uid()),
    auth.uid()
  );
$fn$;

create or replace function public.identity_has_permission(p_permission text)
returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_owner uuid;
  v_eid uuid;
  v_role text;
begin
  if v_uid is null then return false; end if;
  select coalesce(boss_id,id),role into v_owner,v_role
    from public.profiles where id=v_uid;
  select id into v_eid from public.enterprises where owner_profile_id=v_owner;
  if v_eid is null then
    return v_role='boss' or p_permission in ('identity.view','community.post');
  end if;
  return public._identity_role_permissions(v_eid,v_uid) ? p_permission;
end;
$fn$;

create or replace function public._identity_finalize_motion(p_motion uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_role_motions%rowtype;
  v_total numeric;
  v_cast numeric;
  v_yes numeric;
  v_no numeric;
  v_turnout_bps integer:=0;
  v_yes_bps integer:=0;
  v_status text;
  v_reason text;
begin
  select * into v_m from public.enterprise_role_motions where id=p_motion for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then return jsonb_build_object('ok',true,'status',v_m.status); end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  select public._identity_total_shares(v_m.enterprise_id) into v_total;
  select coalesce(sum(shares_at_vote),0),
         coalesce(sum(shares_at_vote) filter(where choice='yes'),0),
         coalesce(sum(shares_at_vote) filter(where choice='no'),0)
    into v_cast,v_yes,v_no
    from public.enterprise_role_votes where motion_id=p_motion;

  if v_total>0 then
    v_turnout_bps:=floor(v_cast/v_total*10000)::integer;
  end if;
  if (v_yes+v_no)>0 then
    v_yes_bps:=floor(v_yes/(v_yes+v_no)*10000)::integer;
  end if;

  if v_total<=0 then
    v_status:='rejected';
    v_reason:='No voting shares';
  elsif v_turnout_bps<v_m.quorum_bps then
    v_status:='rejected';
    v_reason:='Quorum not reached';
  elsif v_yes_bps<v_m.approval_bps then
    v_status:='rejected';
    v_reason:='Approval threshold not reached';
  else
    v_status:='passed';
    v_reason:='Approved by weighted shareholder vote';
  end if;

  update public.enterprise_role_motions
     set status=v_status,decided_at=now(),decision_reason=v_reason,updated_at=now()
   where id=p_motion;

  if v_status='passed' then
    if v_m.kind='appointment' then
      update public.enterprise_members
         set role_key=v_m.proposed_role_key,
             department=v_m.proposed_department,
             title=v_m.proposed_title,
             appointed_by=v_m.proposer_profile_id,
             appointed_at=now(),updated_at=now(),status='active'
       where enterprise_id=v_m.enterprise_id and profile_id=v_m.target_profile_id;
    else
      update public.enterprise_members
         set role_key='employee',department='',title='',
             appointed_by=v_m.proposer_profile_id,
             appointed_at=now(),updated_at=now(),status='active'
       where enterprise_id=v_m.enterprise_id and profile_id=v_m.target_profile_id;
    end if;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'motion.'||v_status,v_m.target_profile_id,
    jsonb_build_object(
      'motion_id',v_m.id,'kind',v_m.kind,'role',v_m.proposed_role_key,
      'turnout_bps',v_turnout_bps,'yes_bps',v_yes_bps,'reason',v_reason
    )
  );

  return jsonb_build_object(
    'ok',true,'status',v_status,'turnout_bps',v_turnout_bps,
    'yes_bps',v_yes_bps,'reason',v_reason
  );
end;
$fn$;

-- ------------------------------------------------------------ public RPCs
create or replace function public.get_enterprise_identity_state()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_total numeric;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  v_total:=public._identity_total_shares(v_eid);

  return jsonb_build_object(
    'enterprise',(
      select jsonb_build_object(
        'id',e.id,'name',e.name,'owner_profile_id',e.owner_profile_id,
        'quorum_bps',e.quorum_bps,'approval_bps',e.approval_bps
      ) from public.enterprises e where e.id=v_eid
    ),
    'me',(
      select jsonb_build_object(
        'profile_id',m.profile_id,'name',p.name,'code',p.code,
        'role_key',m.role_key,'role_name',r.name,
        'department',m.department,'title',m.title,
        'is_owner',(e.owner_profile_id=m.profile_id),
        'is_shareholder',(coalesce(s.shares,0)>0),
        'shares',coalesce(s.shares,0),
        'share_percent',case when v_total>0 then round(coalesce(s.shares,0)/v_total*100,2) else 0 end,
        'permissions',public._identity_role_permissions(v_eid,v_uid)
      )
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      join public.enterprise_role_catalog r on r.key=m.role_key
      join public.enterprises e on e.id=m.enterprise_id
      left join public.enterprise_shareholders s
        on s.enterprise_id=m.enterprise_id and s.profile_id=m.profile_id
      where m.enterprise_id=v_eid and m.profile_id=v_uid
    ),
    'roles',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'key',r.key,'name',r.name,'description',r.description,
        'permissions',r.permissions,'rank',r.rank
      ) order by r.rank desc),'[]'::jsonb)
      from public.enterprise_role_catalog r
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'profile_id',m.profile_id,'name',p.name,'code',p.code,
        'role_key',m.role_key,'role_name',r.name,
        'department',m.department,'title',m.title,'status',m.status,
        'is_owner',(e.owner_profile_id=m.profile_id),
        'is_shareholder',(coalesce(s.shares,0)>0),
        'shares',coalesce(s.shares,0),
        'share_percent',case when v_total>0 then round(coalesce(s.shares,0)/v_total*100,2) else 0 end
      ) order by r.rank desc,p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      join public.enterprise_role_catalog r on r.key=m.role_key
      join public.enterprises e on e.id=m.enterprise_id
      left join public.enterprise_shareholders s
        on s.enterprise_id=m.enterprise_id and s.profile_id=m.profile_id
      where m.enterprise_id=v_eid
    ),
    'motions',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',x.id,'kind',x.kind,'status',x.status,
        'target_profile_id',x.target_profile_id,'target_name',tp.name,
        'proposed_role_key',x.proposed_role_key,
        'proposed_role_name',coalesce(rr.name,''),
        'proposed_department',x.proposed_department,
        'proposed_title',x.proposed_title,'reason',x.reason,
        'proposer_profile_id',x.proposer_profile_id,'proposer_name',pp.name,
        'quorum_bps',x.quorum_bps,'approval_bps',x.approval_bps,
        'opens_at',x.opens_at,'closes_at',x.closes_at,
        'eligible_shares',v_total,
        'cast_shares',coalesce(v.cast_shares,0),
        'yes_shares',coalesce(v.yes_shares,0),
        'no_shares',coalesce(v.no_shares,0),
        'abstain_shares',coalesce(v.abstain_shares,0),
        'turnout_percent',case when v_total>0 then round(coalesce(v.cast_shares,0)/v_total*100,2) else 0 end,
        'yes_percent',case when (coalesce(v.yes_shares,0)+coalesce(v.no_shares,0))>0
          then round(coalesce(v.yes_shares,0)/(coalesce(v.yes_shares,0)+coalesce(v.no_shares,0))*100,2)
          else 0 end,
        'my_choice',coalesce((select mv.choice from public.enterprise_role_votes mv
          where mv.motion_id=x.id and mv.voter_profile_id=v_uid),''),
        'can_vote',(
          x.status='open' and public._identity_shares(v_eid,v_uid)>0
          and now()<x.closes_at
        ),
        'decision_reason',x.decision_reason,'decided_at',x.decided_at,
        'created_at',x.created_at
      )),'[]'::jsonb)
      from public.enterprise_role_motions x
      join public.profiles tp on tp.id=x.target_profile_id
      join public.profiles pp on pp.id=x.proposer_profile_id
      left join public.enterprise_role_catalog rr on rr.key=x.proposed_role_key
      left join lateral (
        select
          sum(z.shares_at_vote) as cast_shares,
          sum(z.shares_at_vote) filter(where z.choice='yes') as yes_shares,
          sum(z.shares_at_vote) filter(where z.choice='no') as no_shares,
          sum(z.shares_at_vote) filter(where z.choice='abstain') as abstain_shares
        from public.enterprise_role_votes z where z.motion_id=x.id
      ) v on true
      where x.enterprise_id=v_eid
      order by x.created_at desc
    )
  );
end;
$fn$;

create or replace function public.propose_enterprise_role(
  p_target uuid,
  p_kind text,
  p_role_key text default 'employee',
  p_department text default '',
  p_title text default '',
  p_reason text default '',
  p_days integer default 3
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_target public.enterprise_members%rowtype;
  v_days integer:=least(greatest(coalesce(p_days,3),1),14);
  v_motion uuid;
  v_kind text:=lower(trim(coalesce(p_kind,'')));
  v_role text:=nullif(trim(coalesce(p_role_key,'')),'');
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if public._identity_shares(v_eid,v_uid)<=0 then
    raise exception 'only shareholders may propose role changes';
  end if;
  if v_kind not in ('appointment','removal') then raise exception 'invalid motion kind'; end if;
  select * into v_target from public.enterprise_members
   where enterprise_id=v_eid and profile_id=p_target and status='active';
  if not found then raise exception 'target is not an active enterprise member'; end if;

  if v_kind='appointment' then
    if v_role is null then raise exception 'role is required'; end if;
    if not exists(select 1 from public.enterprise_role_catalog where key=v_role) then
      raise exception 'unknown role';
    end if;
    if v_target.role_key=v_role then raise exception 'target already holds this role'; end if;
  else
    if v_target.role_key='employee' then raise exception 'target already has the base employee role'; end if;
    v_role:=null;
  end if;

  insert into public.enterprise_role_motions(
    enterprise_id,kind,target_profile_id,proposed_role_key,
    proposed_department,proposed_title,reason,proposer_profile_id,
    quorum_bps,approval_bps,closes_at
  )
  select v_eid,v_kind,p_target,v_role,trim(coalesce(p_department,'')),
    trim(coalesce(p_title,'')),trim(coalesce(p_reason,'')),v_uid,
    e.quorum_bps,e.approval_bps,now()+make_interval(days=>v_days)
    from public.enterprises e where e.id=v_eid
  returning id into v_motion;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'motion.created',p_target,
    jsonb_build_object('motion_id',v_motion,'kind',v_kind,'role',v_role)
  );

  return jsonb_build_object('ok',true,'motion_id',v_motion);
exception when unique_violation then
  raise exception 'this member already has an open role motion';
end;
$fn$;

create or replace function public.cast_enterprise_role_vote(
  p_motion uuid,
  p_choice text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_role_motions%rowtype;
  v_choice text:=lower(trim(coalesce(p_choice,'')));
  v_shares numeric;
  v_cast numeric;
  v_total numeric;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_choice not in ('yes','no','abstain') then raise exception 'invalid vote'; end if;
  select * into v_m from public.enterprise_role_motions where id=p_motion for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then raise exception 'motion is closed'; end if;
  if now()>=v_m.closes_at then
    perform public._identity_finalize_motion(p_motion);
    raise exception 'voting period has ended';
  end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  v_shares:=public._identity_shares(v_m.enterprise_id,v_uid);
  if v_shares<=0 then raise exception 'only shareholders may vote'; end if;

  insert into public.enterprise_role_votes(
    motion_id,voter_profile_id,choice,shares_at_vote
  ) values(p_motion,v_uid,v_choice,v_shares)
  on conflict (motion_id,voter_profile_id) do update
    set choice=excluded.choice,shares_at_vote=excluded.shares_at_vote,
        voted_at=now(),updated_at=now();

  select coalesce(sum(shares_at_vote),0) into v_cast
    from public.enterprise_role_votes where motion_id=p_motion;
  v_total:=public._identity_total_shares(v_m.enterprise_id);
  if v_total>0 and v_cast>=v_total then
    v_result:=public._identity_finalize_motion(p_motion);
  end if;

  return jsonb_build_object(
    'ok',true,'choice',v_choice,'shares',v_shares,
    'voted_shares',v_cast,'eligible_shares',v_total,
    'motion_status',coalesce(v_result->>'status','open')
  );
end;
$fn$;

create or replace function public.close_enterprise_role_vote(p_motion uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_role_motions%rowtype;
  v_cast numeric;
  v_total numeric;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_m from public.enterprise_role_motions where id=p_motion;
  if not found then raise exception 'motion not found'; end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select coalesce(sum(shares_at_vote),0) into v_cast
    from public.enterprise_role_votes where motion_id=p_motion;
  v_total:=public._identity_total_shares(v_m.enterprise_id);
  if now()<v_m.closes_at and v_cast<v_total then
    raise exception 'voting is still in progress';
  end if;
  return public._identity_finalize_motion(p_motion);
end;
$fn$;

create or replace function public.cancel_enterprise_role_vote(p_motion uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_role_motions%rowtype;
  v_owner uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_m from public.enterprise_role_motions where id=p_motion for update;
  if not found then raise exception 'motion not found'; end if;
  select owner_profile_id into v_owner from public.enterprises where id=v_m.enterprise_id;
  if v_uid<>v_m.proposer_profile_id and v_uid<>v_owner then
    raise exception 'only the proposer or enterprise owner may cancel';
  end if;
  if v_m.status<>'open' then raise exception 'motion is not open'; end if;
  update public.enterprise_role_motions
     set status='cancelled',decided_at=now(),decision_reason='Cancelled',updated_at=now()
   where id=p_motion;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_m.enterprise_id,v_uid,'motion.cancelled',v_m.target_profile_id,
    jsonb_build_object('motion_id',v_m.id));
  return jsonb_build_object('ok',true,'status','cancelled');
end;
$fn$;

create or replace function public.set_enterprise_shareholder(
  p_profile uuid,
  p_shares numeric
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_owner uuid;
  v_total numeric;
  v_shares numeric:=round(greatest(coalesce(p_shares,0),0),4);
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;
  if v_uid<>v_owner then raise exception 'only the enterprise owner may change shares'; end if;
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'target is not an active enterprise member';
  end if;
  if p_profile=v_owner and v_shares<=0 then
    raise exception 'enterprise owner must retain voting shares';
  end if;
  if exists(
    select 1 from public.enterprise_role_motions
     where enterprise_id=v_eid and status='open'
  ) then
    raise exception 'cannot change shares while a role vote is open';
  end if;

  insert into public.enterprise_shareholders(
    enterprise_id,profile_id,shares,updated_by
  ) values(v_eid,p_profile,v_shares,v_uid)
  on conflict (enterprise_id,profile_id) do update
    set shares=excluded.shares,updated_by=excluded.updated_by,updated_at=now();

  select public._identity_total_shares(v_eid) into v_total;
  if v_total<=0 then raise exception 'enterprise must have positive voting shares'; end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_eid,v_uid,'shares.updated',p_profile,
    jsonb_build_object('shares',v_shares,'total_shares',v_total));

  return jsonb_build_object('ok',true,'shares',v_shares,'total_shares',v_total);
end;
$fn$;

-- ------------------------------------------------------------ manager project writes
-- These two functions are SECURITY DEFINER, so RLS alone is not enough.
-- Resolve the enterprise tenant and require projects.manage.
create or replace function public.save_project(
  p_id uuid, p_version integer, p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_owner uuid;
  v_id uuid:=p_id;
  v_row public.projects%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_owner:=public.identity_owner_id();
  if not public.identity_has_permission('projects.manage') then
    raise exception 'projects.manage permission required';
  end if;
  if v_id is null then
    insert into public.projects(
      boss_id,name,owner,client,status,priority,start_date,due_date,
      budget,cost,progress,note
    ) values (
      v_owner,trim(coalesce(p_data->>'name','')),
      coalesce(p_data->>'owner',''),coalesce(p_data->>'client',''),
      coalesce(p_data->>'status',U&'\8FDB\884C\4E2D'),
      coalesce(p_data->>'priority',U&'\4E2D'),
      nullif(p_data->>'start_date','')::date,
      nullif(p_data->>'due_date','')::date,
      coalesce((p_data->>'budget')::numeric,0),
      coalesce((p_data->>'cost')::numeric,0),
      least(100,greatest(0,coalesce((p_data->>'progress')::integer,0))),
      coalesce(p_data->>'note','')
    ) returning * into v_row;
  else
    update public.projects set
      name=coalesce(p_data->>'name',name),
      owner=coalesce(p_data->>'owner',owner),
      client=coalesce(p_data->>'client',client),
      status=coalesce(p_data->>'status',status),
      priority=coalesce(p_data->>'priority',priority),
      start_date=coalesce(nullif(p_data->>'start_date','')::date,start_date),
      due_date=coalesce(nullif(p_data->>'due_date','')::date,due_date),
      budget=coalesce((p_data->>'budget')::numeric,budget),
      cost=coalesce((p_data->>'cost')::numeric,cost),
      progress=least(100,greatest(0,coalesce((p_data->>'progress')::integer,progress))),
      note=coalesce(p_data->>'note',note),
      version=version+1,updated_at=now()
    where id=v_id and boss_id=v_owner
      and version=coalesce(p_version,version)
    returning * into v_row;
    if not found then raise exception 'version conflict or project not yours'; end if;
  end if;
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.save_project_step(
  p_id uuid, p_project uuid, p_version integer, p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_owner uuid;
  v_id uuid:=p_id;
  v_row public.project_steps%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_owner:=public.identity_owner_id();
  if not public.identity_has_permission('projects.manage') then
    raise exception 'projects.manage permission required';
  end if;
  if not exists(select 1 from public.projects where id=p_project and boss_id=v_owner) then
    raise exception 'project not yours';
  end if;
  if v_id is null then
    insert into public.project_steps(
      boss_id,project_id,seq,name,owner,status,start_date,due_date,progress,note
    ) values (
      v_owner,p_project,coalesce((p_data->>'seq')::integer,0),
      trim(coalesce(p_data->>'name','')),coalesce(p_data->>'owner',''),
      coalesce(p_data->>'status',U&'\672A\5F00\59CB'),
      nullif(p_data->>'start_date','')::date,
      nullif(p_data->>'due_date','')::date,
      least(100,greatest(0,coalesce((p_data->>'progress')::integer,0))),
      coalesce(p_data->>'note','')
    ) returning * into v_row;
  else
    update public.project_steps set
      seq=coalesce((p_data->>'seq')::integer,seq),
      name=coalesce(p_data->>'name',name),
      owner=coalesce(p_data->>'owner',owner),
      status=coalesce(p_data->>'status',status),
      start_date=coalesce(nullif(p_data->>'start_date','')::date,start_date),
      due_date=coalesce(nullif(p_data->>'due_date','')::date,due_date),
      progress=least(100,greatest(0,coalesce((p_data->>'progress')::integer,progress))),
      note=coalesce(p_data->>'note',note),
      version=version+1,updated_at=now()
    where id=v_id and project_id=p_project and boss_id=v_owner
      and version=coalesce(p_version,version)
    returning * into v_row;
    if not found then raise exception 'version conflict or step not yours'; end if;
  end if;
  return to_jsonb(v_row);
end;
$fn$;

-- ------------------------------------------------------------ grants
revoke all on function public._identity_owner_for_uid(uuid) from public;
revoke all on function public._identity_ensure_enterprise(uuid) from public;
revoke all on function public._identity_bootstrap(uuid) from public;
revoke all on function public._identity_is_member(uuid,uuid) from public;
revoke all on function public._identity_shares(uuid,uuid) from public;
revoke all on function public._identity_total_shares(uuid) from public;
revoke all on function public._identity_role_permissions(uuid,uuid) from public;
revoke all on function public._identity_finalize_motion(uuid) from public;
revoke all on function public.identity_owner_id() from public;
revoke all on function public.identity_has_permission(text) from public;

grant execute on function public.identity_owner_id() to authenticated;
grant execute on function public.identity_has_permission(text) to authenticated;
grant execute on function public.get_enterprise_identity_state() to authenticated;
grant execute on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer) to authenticated;
grant execute on function public.cast_enterprise_role_vote(uuid,text) to authenticated;
grant execute on function public.close_enterprise_role_vote(uuid) to authenticated;
grant execute on function public.cancel_enterprise_role_vote(uuid) to authenticated;

-- Initialization is lazy: the first authenticated call provisions the
-- enterprise from the existing boss/employee profile relationship.
-- ------------------------------------------------------------ capability-aware RLS
-- The existing app used boss/employee only. These policies let an
-- appointed manager operate the same tenant data after a successful
-- shareholder vote, while ordinary employees keep self-only access.

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select to authenticated
  using (
    id=auth.uid()
    or boss_id=auth.uid()
    or (
      boss_id=public.identity_owner_id()
      and public.identity_has_permission('people.view_all')
    )
  );

drop policy if exists "boss updates staff" on public.profiles;
drop policy if exists "team reads projects" on public.projects;
create policy "team reads projects" on public.projects for select to authenticated
  using (
    boss_id=public.identity_owner_id()
    and (
      public.identity_has_permission('projects.view_all')
      or public.identity_has_permission('projects.manage')
    )
  );

drop policy if exists "boss writes projects" on public.projects;
create policy "boss writes projects" on public.projects for all to authenticated
  using (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('projects.manage')
  )
  with check (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('projects.manage')
  );

drop policy if exists "team reads project steps" on public.project_steps;
create policy "team reads project steps" on public.project_steps for select to authenticated
  using (
    boss_id=public.identity_owner_id()
    and (
      public.identity_has_permission('projects.view_all')
      or public.identity_has_permission('projects.manage')
    )
  );

drop policy if exists "boss writes project steps" on public.project_steps;
create policy "boss writes project steps" on public.project_steps for all to authenticated
  using (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('projects.manage')
  )
  with check (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('projects.manage')
  );

drop policy if exists "boss manages tasks" on public.tasks;
create policy "boss manages tasks" on public.tasks for all to authenticated
  using (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('tasks.assign')
  )
  with check (
    boss_id=public.identity_owner_id()
    and public.identity_has_permission('tasks.assign')
  );

drop policy if exists "read own logs" on public.task_logs;
create policy "read own logs" on public.task_logs for select to authenticated
  using (
    employee_id=auth.uid()
    or exists (
      select 1 from public.tasks t
       where t.id=task_logs.task_id
         and t.boss_id=public.identity_owner_id()
         and (
           public.identity_has_permission('tasks.grade')
           or public.identity_has_permission('reports.view')
         )
    )
  );

drop policy if exists "read own worklogs" on public.worklogs;
create policy "read own worklogs" on public.worklogs for select to authenticated
  using (
    employee_id=auth.uid()
    or (
      boss_id=public.identity_owner_id()
      and (
        public.identity_has_permission('worklogs.approve')
        or public.identity_has_permission('people.view_all')
        or public.identity_has_permission('reports.view')
        or public.identity_has_permission('finance.view')
      )
    )
  );

drop policy if exists "insert worklogs" on public.worklogs;
create policy "insert worklogs" on public.worklogs for insert to authenticated
  with check (
    employee_id=auth.uid()
    or (
      boss_id=public.identity_owner_id()
      and public.identity_has_permission('worklogs.approve')
    )
  );

drop policy if exists "team reads audit" on public.audit_log;
create policy "team reads audit" on public.audit_log for select to authenticated
  using (
    boss_id=public.identity_owner_id()
    and (
      public.identity_has_permission('audit.read')
      or public.identity_has_permission('reports.view')
    )
  );

-- Revoke default PUBLIC execution on every governance RPC. Only the
-- authenticated role may call them, and each function still checks
-- membership and capabilities.
revoke all on function public.get_enterprise_identity_state() from public;
revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer) from public;
revoke all on function public.cast_enterprise_role_vote(uuid,text) from public;
revoke all on function public.close_enterprise_role_vote(uuid) from public;
revoke all on function public.cancel_enterprise_role_vote(uuid) from public;
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from public;
