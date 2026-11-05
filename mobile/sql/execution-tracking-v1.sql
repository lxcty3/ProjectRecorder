-- ============================================================
-- Project Recorder - Phase 3 execution tracking
--
-- Deployment order:
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   unified-platform.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--   operations-economics-v1.sql
--   execution-tracking-v1.sql
--
-- All business tables are private. Clients read and write through the
-- SECURITY DEFINER RPCs at the end of this file.
-- ============================================================

-- ---------------------------------------------------------- acceptance
create table if not exists public.task_acceptance (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  criteria text not null check (char_length(btrim(criteria)) > 0),
  evidence text not null check (char_length(btrim(evidence)) > 0),
  submitter_id uuid not null references public.profiles(id),
  reviewer_id uuid not null references public.profiles(id),
  status text not null default 'pending'
    check (status in ('pending','accepted','rework','cancelled')),
  review_note text not null default '',
  version integer not null default 1 check (version > 0),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------- dependencies
create table if not exists public.task_dependencies (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  depends_on_task_id uuid not null references public.tasks(id) on delete cascade,
  lag_days integer not null default 0 check (lag_days >= 0),
  required boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key (task_id, depends_on_task_id),
  check (task_id<>depends_on_task_id)
);

-- ---------------------------------------------------------- handoffs
create table if not exists public.task_handoffs (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  from_profile_id uuid not null references public.profiles(id),
  to_profile_id uuid not null references public.profiles(id),
  from_department text not null default '',
  to_department text not null default '',
  artifact text not null check (char_length(btrim(artifact)) > 0),
  note text not null default '',
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected')),
  decision_note text not null default '',
  decided_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  decided_at timestamptz,
  version integer not null default 1 check (version > 0),
  check (from_profile_id <> to_profile_id)
);

-- ---------------------------------------------------------- changes
create table if not exists public.change_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  requester_id uuid not null references public.profiles(id),
  title text not null check (char_length(btrim(title)) > 0),
  scope text not null check (char_length(btrim(scope)) > 0),
  reason text not null check (char_length(btrim(reason)) > 0),
  urgency text not null check (char_length(btrim(urgency)) > 0),
  schedule_impact_days integer not null default 0
    check (schedule_impact_days >= 0),
  cost_impact numeric not null default 0 check (cost_impact >= 0),
  resource_impact text not null
    check (char_length(btrim(resource_impact)) > 0),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  cross_department boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','returned')),
  approver_id uuid references public.profiles(id),
  decision_note text not null default '',
  decision_item_id uuid references public.decision_items(id) on delete set null,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create index if not exists task_dependencies_upstream_idx
  on public.task_dependencies(enterprise_id, depends_on_task_id);
create index if not exists task_handoffs_recipient_idx
  on public.task_handoffs(enterprise_id, to_profile_id, status);
create index if not exists change_requests_project_idx
  on public.change_requests(enterprise_id, project_id, status, created_at desc);

-- ---------------------------------------------------------- immutable audit
create table if not exists public.execution_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  entity_type text not null,
  entity_id text not null,
  action text not null,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists execution_audit_entity_idx
  on public.execution_audit(enterprise_id, entity_type, entity_id, created_at desc);

create table if not exists public.execution_security_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid references public.enterprises(id) on delete set null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  entity_type text not null default '',
  entity_id text not null default '',
  reason text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists execution_security_audit_actor_idx
  on public.execution_security_audit(enterprise_id, actor_profile_id, created_at desc);

-- ---------------------------------------------------------- RLS / least privilege
alter table public.task_acceptance enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.task_handoffs enable row level security;
alter table public.change_requests enable row level security;
alter table public.execution_audit enable row level security;
alter table public.execution_security_audit enable row level security;

revoke all on table public.task_acceptance from public, anon, authenticated;
revoke all on table public.task_dependencies from public, anon, authenticated;
revoke all on table public.task_handoffs from public, anon, authenticated;
revoke all on table public.change_requests from public, anon, authenticated;
revoke all on table public.execution_audit from public, anon, authenticated;
revoke all on table public.execution_security_audit from public, anon, authenticated;
revoke all on sequence public.execution_audit_id_seq from public, anon, authenticated;
revoke all on sequence public.execution_security_audit_id_seq from public, anon, authenticated;

-- Direct writes are denied. SECURITY DEFINER RPCs are the only write path.
create or replace function public._execution_risk(p_risk text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_risk text:=lower(btrim(coalesce(p_risk,'health')));
begin
  if v_risk in ('severe','critical','high','serious')
    return 'severe';
  end if;
  if v_risk in ('risk','medium','warning') then
    return 'risk';
  end if;
  if v_risk in ('attention','low') then
    return 'attention';
  end if;
  return 'healthy';
end;
$fn$;

create or replace function public._execution_change_requires_approval(
  amount numeric,
  schedule_impact_days integer,
  risk text,
  cross_department boolean,
  urgency text
) returns boolean
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return amount >= 50000
    or schedule_impact_days > 3
    or risk in ('severe','risk')`n    or public._execution_risk(risk) in ('severe','risk')
    or coalesce(cross_department,false)
    or lower(coalesce(urgency,'')) in
      ('high','urgent','critical','emergency');
end;
$fn$;

create or replace function public._execution_denied(
  p_eid uuid,
  p_uid uuid,
  p_operation text,
  p_entity_type text,
  p_entity_id text,
  p_reason text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.execution_security_audit(
    enterprise_id,actor_profile_id,operation,entity_type,entity_id,reason,payload
  ) values(
    p_eid,p_uid,btrim(coalesce(p_operation,'')),coalesce(p_entity_type,''),
    coalesce(p_entity_id,''),btrim(coalesce(p_reason,'')),
    coalesce(p_payload,'{}'::jsonb)
  );
  return jsonb_build_object(
    'ok',false,'code','permission_denied',
    'error',coalesce(nullif(btrim(p_operation),''),'operation')
      || ': ' || coalesce(nullif(btrim(p_reason),''),'permission denied')
  );
end;
$fn$;

create or replace function public._execution_success(
  p_eid uuid,
  p_uid uuid,
  p_entity_type text,
  p_entity_id text,
  p_action text,
  p_before jsonb,
  p_after jsonb,
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.execution_audit(
    enterprise_id,actor_profile_id,entity_type,entity_id,action,
    before_data,after_data,metadata
  ) values(
    p_eid,p_uid,coalesce(p_entity_type,''),coalesce(p_entity_id,''),
    coalesce(p_action,''),coalesce(p_before,'{}'::jsonb),
    coalesce(p_after,'{}'::jsonb),coalesce(p_metadata,'{}'::jsonb)
  );
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_eid,p_uid,'execution.'||coalesce(p_action,'changed'),null,
    jsonb_build_object(
      'entity_type',p_entity_type,'entity_id',p_entity_id,
      'before',coalesce(p_before,'{}'::jsonb),
      'after',coalesce(p_after,'{}'::jsonb),
      'metadata',coalesce(p_metadata,'{}'::jsonb)
    )
  );
end;
$fn$;

create or replace function public._execution_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permission text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return public._decision_has_permission(p_eid,p_uid,p_permission);
end;
$fn$;

create or replace function public._execution_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return public._decision_has_management(p_eid,p_uid);
end;
$fn$;

create or replace function public._execution_task_enterprise(p_task uuid)
returns uuid
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_boss uuid;
begin
  select boss_id into v_boss from public.tasks where id=p_task;
  if v_boss is null then return null; end if;
  return public._identity_bootstrap(v_boss);
end;
$fn$;

create or replace function public._execution_dependency_cycle(
  p_eid uuid,
  p_task uuid,
  p_depends_on uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if p_task=p_depends_on then return true; end if;
  return exists(
    with recursive chain(task_id,path) as (
      select d.depends_on_task_id,array[p_depends_on,d.depends_on_task_id]
        from public.task_dependencies d
       where d.enterprise_id=p_eid and d.task_id=p_depends_on
      union all
      select d.depends_on_task_id,chain.path||d.depends_on_task_id
        from chain
        join public.task_dependencies d
          on d.enterprise_id=p_eid and d.task_id=chain.task_id
       where not d.depends_on_task_id=any(chain.path)
    )
    select 1 from chain where task_id=p_task
  );
end;
$fn$;

create or replace function public._execution_downstream(
  p_eid uuid,
  p_task uuid,
  p_delay_days integer
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_delay integer:=greatest(coalesce(p_delay_days,0),0);
begin
  if v_delay<=0 then return '[]'::jsonb; end if;
  return (
    with recursive affected(task_id,delay_days,path) as (
      select d.task_id,v_delay+d.lag_days,array[p_task,d.task_id]
        from public.task_dependencies d
       where d.enterprise_id=p_eid and d.depends_on_task_id=p_task
         and d.required=true
      union all
      select d.task_id,affected.delay_days+d.lag_days,
             affected.path||d.task_id
        from affected
        join public.task_dependencies d
          on d.enterprise_id=p_eid and d.depends_on_task_id=affected.task_id
       where d.required=true
         and not d.task_id=any(affected.path)
    ), best as (
      select task_id,max(delay_days) as delay_days
        from affected group by task_id
    )
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'task_id',b.task_id,
        'title',t.title,
        'employee_id',t.employee_id,
        'employee_name',p.name,
        'project_id',t.project_id,
        'plan_date',t.plan_date,
        'projected_date',t.plan_date+b.delay_days,
        'delay_days',b.delay_days,
        'required',true
      ) order by b.delay_days,b.task_id
    ),'[]'::jsonb)
    from best b
    join public.tasks t on t.id=b.task_id
    left join public.profiles p on p.id=t.employee_id
  );
end;
$fn$;

-- ---------------------------------------------------------- acceptance RPCs
create or replace function public.submit_task_acceptance(
  p_task uuid,
  p_criteria text,
  p_evidence text,
  p_reviewer uuid,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_eid uuid;
  v_old public.task_acceptance%rowtype;
  v_before jsonb:='{}'::jsonb;
  v_criteria text:=btrim(coalesce(p_criteria,''));
  v_evidence text:=btrim(coalesce(p_evidence,''));
  v_note text:=btrim(coalesce(p_note,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null then raise exception 'task enterprise not found'; end if;
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'submit_task_acceptance','task',p_task::text,
      'active enterprise member required');
  end if;
  if v_uid<>v_task.employee_id
     and not public._execution_has_management(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'submit_task_acceptance','task',p_task::text,
      'only the assignee or a manager can submit acceptance');
  end if;
  if v_criteria='' then raise exception 'acceptance criteria required'; end if;
  if v_evidence='' then raise exception 'evidence required'; end if;
  if p_reviewer is null or p_reviewer=v_uid then
    raise exception 'independent reviewer required';
  end if;
  if not public._identity_is_member(v_eid,p_reviewer) then
    raise exception 'reviewer must be an active enterprise member';
  end if;
  select * into v_old from public.task_acceptance
   where task_id=p_task for update;
  if found then
    v_before:=to_jsonb(v_old);
    if v_old.status='accepted' then
      raise exception 'accepted record is final';
    end if;
  end if;
  insert into public.task_acceptance(
    task_id,enterprise_id,criteria,evidence,submitter_id,reviewer_id,
    status,review_note,version,submitted_at,reviewed_at,updated_at
  ) values(
    p_task,v_eid,v_criteria,v_evidence,v_uid,p_reviewer,
    'pending',v_note,1,now(),null,now()
  )
  on conflict(task_id) do update set
    criteria=excluded.criteria,
    evidence=excluded.evidence,
    submitter_id=excluded.submitter_id,
    reviewer_id=excluded.reviewer_id,
    status='pending',
    review_note=excluded.review_note,
    version=public.task_acceptance.version+1,
    submitted_at=now(),
    reviewed_at=null,
    updated_at=now();
  select * into v_old from public.task_acceptance where task_id=p_task;
  perform public._execution_success(
    v_eid,v_uid,'task_acceptance',p_task::text,'acceptance.submitted',
    v_before,to_jsonb(v_old),
    jsonb_build_object('criteria',v_criteria,'reviewer_id',p_reviewer));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'status','pending',
    'reviewer_id',p_reviewer,'evidence',v_evidence);
end;
$fn$;

create or replace function public.review_task_acceptance(
  p_task uuid,
  p_decision text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.task_acceptance%rowtype;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('accepted','rework') then
    raise exception 'decision must be accepted or rework';
  end if;
  select * into v_row from public.task_acceptance
   where task_id=p_task for update;
  if not found then raise exception 'acceptance record not found'; end if;
  if v_uid<>v_row.reviewer_id
     and not public._execution_has_management(v_row.enterprise_id,v_uid) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'review_task_acceptance',
      'task_acceptance',p_task::text,
      'only the designated reviewer or a manager can decide');
  end if;
  if v_row.reviewer_id=v_row.submitter_id then
    raise exception 'independent reviewer required';
  end if;
  if btrim(v_row.criteria)='' then raise exception 'acceptance criteria required'; end if;
  if btrim(v_row.evidence)='' then raise exception 'evidence required'; end if;
  if v_row.status='accepted' then
    if v_decision='accepted' then
      return jsonb_build_object('ok',true,'status','accepted','duplicate',true);
    end if;
    raise exception 'accepted record is final';
  end if;
  if v_row.status<>'pending' then
    raise exception 'task is not pending acceptance';
  end if;
  if v_decision='rework' and v_note='' then
    raise exception 'rework note required';
  end if;
  v_before:=to_jsonb(v_row);
  update public.task_acceptance set
    status=v_decision,
    review_note=v_note,
    reviewed_at=now(),
    version=version+1,
    updated_at=now()
  where task_id=p_task
  returning * into v_row;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'task_acceptance',p_task::text,
    'acceptance.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object('note',v_note,'final_complete',v_decision='accepted'));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'status',v_decision,
    'final_complete',v_decision='accepted','duplicate',false);
end;
$fn$;

-- ---------------------------------------------------------- dependency RPC
create or replace function public.upsert_task_dependency(
  p_task uuid,
  p_depends_on uuid,
  p_lag_days integer default 0,
  p_required boolean default true
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_dep public.tasks%rowtype;
  v_eid uuid;
  v_lag integer:=greatest(coalesce(p_lag_days,0),0);
  v_before jsonb:='{}'::jsonb;
  v_after jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  select * into v_dep from public.tasks where id=p_depends_on for update;
  if not found then raise exception 'dependency task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null or v_eid is distinct from
       public._execution_task_enterprise(p_depends_on) then
    raise exception 'tasks must belong to the same enterprise';
  end if;
  if not public._execution_has_management(v_eid,v_uid)
     and v_uid not in (v_task.boss_id,v_dep.boss_id) then
    return public._execution_denied(
      v_eid,v_uid,'upsert_task_dependency','task',p_task::text,
      'management permission required');
  end if;
  if p_task=p_depends_on then
    raise exception 'dependency cycle detected';
  end if;
  if public._execution_dependency_cycle(v_eid,p_task,p_depends_on) then
    insert into public.execution_security_audit(
      enterprise_id,actor_profile_id,operation,entity_type,entity_id,reason,payload
    ) values(
      v_eid,v_uid,'upsert_task_dependency','task',p_task::text,
      'dependency cycle detected',
      jsonb_build_object('depends_on_task_id',p_depends_on)
    );
    return jsonb_build_object(
      'ok',false,'code','dependency_cycle',
      'error','upsert_task_dependency: dependency cycle detected');
  end if;
  select to_jsonb(d) into v_before from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on;
  insert into public.task_dependencies(
    enterprise_id,task_id,depends_on_task_id,lag_days,required,created_by
  ) values(v_eid,p_task,p_depends_on,v_lag,coalesce(p_required,true),v_uid)
  on conflict(task_id,depends_on_task_id) do update set
    lag_days=excluded.lag_days,
    required=excluded.required;
  select to_jsonb(d) into v_after from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on;
  perform public._execution_success(
    v_eid,v_uid,'task_dependency',p_task::text||':'||p_depends_on::text,
    'dependency.saved',coalesce(v_before,'{}'::jsonb),v_after,
    jsonb_build_object('lag_days',v_lag,'required',coalesce(p_required,true)));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'depends_on_task_id',p_depends_on,
    'lag_days',v_lag,'required',coalesce(p_required,true),
    'downstream_impact',public._execution_downstream(v_eid,p_depends_on,v_lag));
end;
$fn$;

-- ---------------------------------------------------------- handoff RPCs
create or replace function public.create_task_handoff(
  p_task uuid,
  p_to uuid,
  p_artifact text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_eid uuid;
  v_artifact text:=btrim(coalesce(p_artifact,''));
  v_note text:=btrim(coalesce(p_note,''));
  v_from_dept text:='';
  v_to_dept text:='';
  v_row public.task_handoffs%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null then raise exception 'task enterprise not found'; end if;
  if v_uid<>v_task.employee_id and v_uid<>v_task.boss_id
     and not public._execution_has_management(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'create_task_handoff','task',p_task::text,
      'only the task owner or a manager can hand off');
  end if;
  if p_to is null or p_to=v_uid then
    raise exception 'handoff recipient must be another profile';
  end if;
  if not public._identity_is_member(v_eid,p_to) then
    raise exception 'handoff recipient must be an active enterprise member';
  end if;
  if v_artifact='' then raise exception 'handoff artifact required'; end if;
  select coalesce(department,'') into v_from_dept
    from public.enterprise_members
   where enterprise_id=v_eid and profile_id=v_uid and status='active'
   limit 1;
  select coalesce(department,'') into v_to_dept
    from public.enterprise_members
   where enterprise_id=v_eid and profile_id=p_to and status='active'
   limit 1;
  insert into public.task_handoffs(
    enterprise_id,task_id,from_profile_id,to_profile_id,
    from_department,to_department,artifact,note,status
  ) values(
    v_eid,p_task,v_uid,p_to,coalesce(v_from_dept,''),coalesce(v_to_dept,''),
    v_artifact,v_note,'pending'
  ) returning * into v_row;
  perform public._execution_success(
    v_eid,v_uid,'task_handoff',v_row.id::text,'handoff.created',
    '{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('recipient',p_to));
  return jsonb_build_object(
    'ok',true,'handoff_id',v_row.id,'status','pending',
    'to_profile_id',p_to,'artifact',v_artifact);
end;
$fn$;

create or replace function public.accept_task_handoff(
  p_handoff uuid,
  p_decision text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.task_handoffs%rowtype;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('accepted','rejected') then
    raise exception 'decision must be accepted or rejected';
  end if;
  select * into v_row from public.task_handoffs where id=p_handoff for update;
  if not found then raise exception 'handoff not found'; end if;
  if v_row.to_profile_id<>v_uid then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'accept_task_handoff','task_handoff',
      p_handoff::text,'only the handoff recipient can decide');
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_decision then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'handoff already decided';
  end if;
  if v_decision='rejected' and v_note='' then
    raise exception 'rejection note required';
  end if;
  v_before:=to_jsonb(v_row);
  update public.task_handoffs set
    status=v_decision,
    decision_note=v_note,
    decided_by=v_uid,
    accepted_at=case when v_decision='accepted' then now() else accepted_at end,
    decided_at=now(),
    version=version+1
  where id=p_handoff
  returning * into v_row;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'task_handoff',p_handoff::text,
    'handoff.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object('note',v_note));
  return jsonb_build_object(
    'ok',true,'handoff_id',p_handoff,'status',v_decision,
    'duplicate',false);
end;
$fn$;

-- ---------------------------------------------------------- change control
create or replace function public.create_change_request(
  p_project uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_project public.projects%rowtype;
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_scope text:=btrim(coalesce(v_data->>'scope',''));
  v_reason text:=btrim(coalesce(v_data->>'reason',''));
  v_urgency text:=lower(btrim(coalesce(v_data->>'urgency','')));
  v_resource text:=btrim(coalesce(v_data->>'resource_impact',''));
  v_schedule integer;
  v_cost numeric;
  v_risk text:=public._execution_risk(v_data->>'risk');
  v_cross boolean:=coalesce((v_data->>'cross_department')::boolean,false);
  v_high boolean:=false;
  v_row public.change_requests%rowtype;
  v_decision_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_project from public.projects where id=p_project for update;
  if not found then raise exception 'project not found'; end if;
  v_eid:=public._identity_bootstrap(v_project.boss_id);
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'create_change_request','project',p_project::text,
      'active enterprise member required');
  end if;
  if v_title='' then v_title:=left(v_scope,120); end if;
  if v_scope='' or v_reason='' or v_urgency='' or v_resource=''
     or not (v_data ? 'schedule_impact_days')
     or not (v_data ? 'cost_impact') then
    raise exception 'scope, reason, urgency, schedule, cost, and resource impact are required';
  end if;
  v_schedule:=greatest(coalesce((v_data->>'schedule_impact_days')::integer,0),0);
  v_cost:=greatest(coalesce((v_data->>'cost_impact')::numeric,0),0);
  v_high:=public._execution_change_requires_approval(
    v_cost,v_schedule,v_risk,v_cross,v_urgency);
  insert into public.change_requests(
    enterprise_id,project_id,requester_id,title,scope,reason,urgency,
    schedule_impact_days,cost_impact,resource_impact,risk,cross_department,
    status
  ) values(
    v_eid,p_project,v_uid,v_title,v_scope,v_reason,v_urgency,
    v_schedule,v_cost,v_resource,v_risk,v_cross,'pending'
  ) returning * into v_row;
  if v_high then
    insert into public.decision_items(
      enterprise_id,source_type,source_id,title,detail,evidence,risk,
      impact_days,impact_amount,owner_profile_id,status,due_at
    ) values(
      v_eid,'change',v_row.id,v_title,v_reason,
      jsonb_build_array(jsonb_build_object(
        'type','change_request','id',v_row.id,'project_id',p_project,
        'scope',v_scope,'urgency',v_urgency,
        'schedule_impact_days',v_schedule,'cost_impact',v_cost,
        'resource_impact',v_resource,'cross_department',v_cross)),
      v_risk,v_schedule,v_cost,v_project.boss_id,'open',
      now()+case when v_urgency in ('urgent','critical','emergency')
        then interval '1 day' else interval '3 days' end
    )
    on conflict(enterprise_id,source_type,source_id) do update set
      title=excluded.title,detail=excluded.detail,evidence=excluded.evidence,
      risk=excluded.risk,impact_days=excluded.impact_days,
      impact_amount=excluded.impact_amount,owner_profile_id=excluded.owner_profile_id,
      updated_at=now()
    returning id into v_decision_id;
    update public.change_requests set decision_item_id=v_decision_id
      where id=v_row.id returning * into v_row;
  end if;
  perform public._execution_success(
    v_eid,v_uid,'change_request',v_row.id::text,'change.created',
    '{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('high_impact',v_high,'decision_item_id',v_decision_id));
  return jsonb_build_object(
    'ok',true,'change_id',v_row.id,'status','pending',
    'high_impact',v_high,'decision_item_id',v_decision_id,
    'plan_mutated',false);
end;
$fn$;

create or replace function public.decide_change_request(
  p_change uuid,
  p_decision text,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_row public.change_requests%rowtype;
  v_before jsonb;
  v_high boolean;
  v_event_action text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('approved','rejected','returned') then
    raise exception 'decision must be approved, rejected, or returned';
  end if;
  select * into v_row from public.change_requests
   where id=p_change for update;
  if not found then raise exception 'change request not found'; end if;
  if not public._execution_has_management(v_row.enterprise_id,v_uid) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'decide_change_request',
      'change_request',p_change::text,'management permission required');
  end if;
  v_high:=public._execution_change_requires_approval(
    v_row.cost_impact,v_row.schedule_impact_days,v_row.risk,
    v_row.cross_department,v_row.urgency);
  if v_high and not public._decision_is_executive(v_row.enterprise_id,v_uid) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'decide_change_request',
      'change_request',p_change::text,
      'executive approval required for high impact change');
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_decision then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true,
        'plan_mutated',false);
    end if;
    raise exception 'change request already decided';
  end if;
  if v_decision in ('rejected','returned') and v_note='' then
    raise exception 'decision note required';
  end if;
  v_before:=to_jsonb(v_row);
  update public.change_requests set
    status=v_decision,
    approver_id=v_uid,
    decision_note=v_note,
    decided_at=now(),
    version=version+1
  where id=p_change
  returning * into v_row;
  if v_row.decision_item_id is not null then
    v_event_action:=case v_decision
      when 'approved' then 'resolved'
      when 'rejected' then 'dismissed'
      else 'deferred' end;
    update public.decision_items set
      status=v_event_action,
      resolution=v_note,
      owner_profile_id=coalesce(owner_profile_id,v_uid),
      version=version+1,
      updated_at=now()
    where id=v_row.decision_item_id and status in
      ('open','acknowledged','assigned','deferred');
    insert into public.decision_events(
      decision_id,actor_profile_id,action,note,idempotency_key
    ) values(
      v_row.decision_item_id,v_uid,v_event_action,v_note,
      coalesce(nullif(v_key,''),'change:'||p_change::text||':'||v_row.version::text)
    );
  end if;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'change_request',p_change::text,
    'change.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object(
      'note',v_note,'high_impact',v_high,
      'decision_item_id',v_row.decision_item_id,'plan_mutated',false));
  return jsonb_build_object(
    'ok',true,'change_id',p_change,'status',v_decision,
    'high_impact',v_high,'duplicate',false,'plan_mutated',false);
end;
$fn$;

-- ---------------------------------------------------------- board query
create or replace function public.get_execution_board(
  p_enterprise uuid default null
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=p_enterprise;
  v_management boolean;
  v_can_accept boolean;
  v_acceptance jsonb:='[]'::jsonb;
  v_dependencies jsonb:='[]'::jsonb;
  v_handoffs jsonb:='[]'::jsonb;
  v_changes jsonb:='[]'::jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    select e.id into v_eid
      from public.enterprises e
     where e.owner_profile_id=v_uid
     order by e.created_at
     limit 1;
    if v_eid is null then
      select m.enterprise_id into v_eid
        from public.enterprise_members m
       where m.profile_id=v_uid and m.status='active'
       order by m.created_at
       limit 1;
    end if;
  end if;
  if v_eid is null then
    return public._execution_denied(
      null,v_uid,'get_execution_board','enterprise','',
      'active enterprise membership required');
  end if;
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'get_execution_board','enterprise',v_eid::text,
      'active enterprise membership required');
  end if;
  v_management:=public._execution_has_management(v_eid,v_uid);
  v_can_accept:=v_management
    or public._execution_has_permission(v_eid,v_uid,'tasks.grade');

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',a.task_id,
    'title',t.title,
    'project_id',t.project_id,
    'plan_date',t.plan_date,
    'criteria',a.criteria,
    'evidence',a.evidence,
    'submitter_id',a.submitter_id,
    'submitter_name',sp.name,
    'reviewer_id',a.reviewer_id,
    'reviewer_name',rp.name,
    'status',a.status,
    'review_note',a.review_note,
    'version',a.version,
    'submitted_at',a.submitted_at,
    'reviewed_at',a.reviewed_at,
    'actions',jsonb_build_object(
      'accept',a.status='pending'
        and (a.reviewer_id=v_uid or v_can_accept),
      'rework',a.status='pending'
        and (a.reviewer_id=v_uid or v_can_accept))
  ) order by a.submitted_at desc),'[]'::jsonb)
  into v_acceptance
  from public.task_acceptance a
  join public.tasks t on t.id=a.task_id
  left join public.profiles sp on sp.id=a.submitter_id
  left join public.profiles rp on rp.id=a.reviewer_id
  where a.enterprise_id=v_eid
    and (v_management or a.reviewer_id=v_uid or a.submitter_id=v_uid
         or t.boss_id=v_uid or t.employee_id=v_uid)
  order by a.submitted_at desc
  limit 100;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',h.id,
    'task_id',h.task_id,
    'title',t.title,
    'artifact',h.artifact,
    'note',h.note,
    'from_profile_id',h.from_profile_id,
    'from_name',fp.name,
    'to_profile_id',h.to_profile_id,
    'to_name',tp.name,
    'from_department',h.from_department,
    'to_department',h.to_department,
    'status',h.status,
    'decision_note',h.decision_note,
    'created_at',h.created_at,
    'accepted_at',h.accepted_at,
    'decided_at',h.decided_at,
    'version',h.version,
    'actions',jsonb_build_object(
      'accept',h.status='pending' and h.to_profile_id=v_uid,
      'reject',h.status='pending' and h.to_profile_id=v_uid)
  ) order by h.created_at desc),'[]'::jsonb)
  into v_handoffs
  from public.task_handoffs h
  join public.tasks t on t.id=h.task_id
  left join public.profiles fp on fp.id=h.from_profile_id
  left join public.profiles tp on tp.id=h.to_profile_id
  where h.enterprise_id=v_eid
    and (v_management or h.from_profile_id=v_uid or h.to_profile_id=v_uid)
  order by h.created_at desc
  limit 100;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,
    'project_id',c.project_id,
    'project_name',pr.name,
    'requester_id',c.requester_id,
    'requester_name',rp.name,
    'title',c.title,
    'scope',c.scope,
    'reason',c.reason,
    'urgency',c.urgency,
    'schedule_impact_days',c.schedule_impact_days,
    'cost_impact',c.cost_impact,
    'resource_impact',c.resource_impact,
    'risk',c.risk,
    'cross_department',c.cross_department,
    'status',c.status,
    'approver_id',c.approver_id,
    'decision_note',c.decision_note,
    'decision_item_id',c.decision_item_id,
    'version',c.version,
    'created_at',c.created_at,
    'decided_at',c.decided_at,
    'high_impact',public._execution_change_requires_approval(
      c.cost_impact,c.schedule_impact_days,c.risk,
      c.cross_department,c.urgency),
    'plan_mutated',false,
    'actions',jsonb_build_object(
      'approve',c.status='pending' and v_management,
      'reject',c.status='pending' and v_management,
      'return',c.status='pending' and v_management)
  ) order by c.created_at desc),'[]'::jsonb)
  into v_changes
  from public.change_requests c
  join public.projects pr on pr.id=c.project_id
  left join public.profiles rp on rp.id=c.requester_id
  where c.enterprise_id=v_eid
    and (v_management or c.requester_id=v_uid)
  order by c.created_at desc
  limit 100;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',d.task_id,
    'depends_on_task_id',d.depends_on_task_id,
    'title',t.title,
    'depends_on_title',u.title,
    'employee_id',t.employee_id,
    'employee_name',ep.name,
    'upstream_employee_id',u.employee_id,
    'upstream_employee_name',up.name,
    'project_id',t.project_id,
    'lag_days',d.lag_days,
    'required',d.required,
    'upstream_status',coalesce(a.status,'not_submitted'),
    'upstream_due_date',u.plan_date,
    'delayed_days',x.delayed_days,
    'blocked',x.delayed_days>0,
    'affected_tasks',public._execution_downstream(
      v_eid,d.depends_on_task_id,x.delayed_days)
  ) order by x.delayed_days desc,d.task_id),'[]'::jsonb)
  into v_dependencies
  from public.task_dependencies d
  join public.tasks t on t.id=d.task_id
  join public.tasks u on u.id=d.depends_on_task_id
  left join public.task_acceptance a on a.task_id=d.depends_on_task_id
  left join public.profiles ep on ep.id=t.employee_id
  left join public.profiles up on up.id=u.employee_id
  cross join lateral (
    select case
      when coalesce(a.status,'not_submitted')<>'accepted'
       and u.plan_date<current_date
      then current_date-u.plan_date else 0 end as delayed_days
  ) x
  where d.enterprise_id=v_eid
    and (v_management or t.boss_id=v_uid or t.employee_id=v_uid)
  order by x.delayed_days desc,d.task_id
  limit 200;

  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'acceptance',v_acceptance,
    'dependencies',v_dependencies,
    'handoffs',v_handoffs,
    'changes',v_changes,
    'access',jsonb_build_object(
      'management',v_management,
      'can_review_acceptance',v_can_accept,
      'can_manage_dependencies',v_management,
      'can_create_handoff',v_management,
      'can_manage_changes',v_management),
    'generated_at',now());
end;
$fn$;

-- ---------------------------------------------------------- least privilege
revoke all on function public._execution_risk(text) from public, anon, authenticated;
revoke all on function public._execution_change_requires_approval(numeric,integer,text,boolean,text)
  from public, anon, authenticated;
revoke all on function public._execution_denied(uuid,uuid,text,text,text,text,jsonb)
  from public, anon, authenticated;
revoke all on function public._execution_success(
  uuid,uuid,text,text,text,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public._execution_has_permission(uuid,uuid,text)
  from public, anon, authenticated;
revoke all on function public._execution_has_management(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_task_enterprise(uuid)
  from public, anon, authenticated;
revoke all on function public._execution_dependency_cycle(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_downstream(uuid,uuid,integer)
  from public, anon, authenticated;

revoke all on function public.get_execution_board(uuid)
  from public, anon, authenticated;
grant execute on function public.get_execution_board(uuid) to authenticated;

revoke all on function public.submit_task_acceptance(uuid,text,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.submit_task_acceptance(uuid,text,text,uuid,text)
  to authenticated;

revoke all on function public.review_task_acceptance(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.review_task_acceptance(uuid,text,text)
  to authenticated;

revoke all on function public.upsert_task_dependency(uuid,uuid,integer,boolean)
  from public, anon, authenticated;
grant execute on function public.upsert_task_dependency(uuid,uuid,integer,boolean)
  to authenticated;

revoke all on function public.create_task_handoff(uuid,uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.create_task_handoff(uuid,uuid,text,text)
  to authenticated;

revoke all on function public.accept_task_handoff(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.accept_task_handoff(uuid,text,text)
  to authenticated;

revoke all on function public.create_change_request(uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.create_change_request(uuid,jsonb)
  to authenticated;

revoke all on function public.decide_change_request(uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.decide_change_request(uuid,text,text,text)
  to authenticated;
