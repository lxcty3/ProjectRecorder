-- ============================================================
-- Project Recorder - Phase 2B operations economics
--
-- Deployment order:
--   unified-platform.sql
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--   execution-tracking-v1.sql
--   operations-economics-v1.sql
--
-- This migration is additive and ASCII-only. Business tables stay
-- private. Clients use the SECURITY DEFINER RPCs at the end.
-- ============================================================

-- ------------------------------------------------------------ economics
create table if not exists public.project_economics (
  project_id uuid primary key references public.projects(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  contract_amount numeric(18,2) not null default 0 check (contract_amount >= 0),
  invoiced_amount numeric(18,2) not null default 0 check (invoiced_amount >= 0),
  collected_amount numeric(18,2) not null default 0 check (collected_amount >= 0),
  outsourced_committed numeric(18,2) not null default 0
    check (outsourced_committed >= 0),
  outsourced_paid numeric(18,2) not null default 0
    check (outsourced_paid >= 0),
  labor_cost numeric(18,2) not null default 0 check (labor_cost >= 0),
  estimated_completion_cost numeric(18,2) not null default 0
    check (estimated_completion_cost >= 0),
  other_cost numeric(18,2) not null default 0 check (other_cost >= 0),
  invoice_due_date date,
  payment_terms text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.project_economics
  add column if not exists invoice_due_date date,
  add column if not exists payment_terms text not null default '';

create index if not exists project_economics_enterprise_idx
  on public.project_economics(enterprise_id, updated_at desc);

-- ------------------------------------------------------------ skills
create table if not exists public.profile_skills (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  skill text not null,
  level integer not null default 1 check (level between 1 and 5),
  certified boolean not null default false,
  certification text not null default '',
  available_hours numeric(8,2) not null default 0
    check (available_hours >= 0),
  valid_until date,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (enterprise_id, profile_id, skill)
);

create index if not exists profile_skills_enterprise_skill_idx
  on public.profile_skills(enterprise_id, skill, valid_until);

-- Explicit demand makes the future capacity gap auditable instead of
-- inferring a skill requirement the existing task model does not store.
create table if not exists public.capacity_demands (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  skill text not null,
  required_hours numeric(10,2) not null check (required_hours > 0),
  needed_from date not null default current_date,
  needed_until date not null default (current_date + 28),
  project_id uuid references public.projects(id) on delete set null,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  note text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (needed_until >= needed_from)
);

create index if not exists capacity_demands_window_idx
  on public.capacity_demands(enterprise_id, needed_from, needed_until, skill);

-- ------------------------------------------------------------ performance
create table if not exists public.performance_evidence (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  period text not null,
  on_time_rate numeric(6,4) not null default 0
    check (on_time_rate between 0 and 1),
  first_pass_rate numeric(6,4) not null default 0
    check (first_pass_rate between 0 and 1),
  rework_rate numeric(6,4) not null default 0
    check (rework_rate between 0 and 1),
  collaboration_score numeric(6,2) not null default 0
    check (collaboration_score between 0 and 5),
  complexity_score numeric(6,2) not null default 0
    check (complexity_score between 0 and 5),
  business_contribution numeric(6,2) not null default 0
    check (business_contribution between 0 and 5),
  customer_evaluation jsonb not null default '{}'::jsonb
    check (jsonb_typeof(customer_evaluation)='object'),
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  employee_statement text not null default '',
  status text not null default 'draft'
    check (status in ('draft','submitted','reviewed')),
  score numeric(5,1) not null default 0 check (score between 0 and 100),
  reviewer_note text not null default '',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, profile_id, period)
);

alter table public.performance_evidence
  add column if not exists customer_evaluation jsonb not null default '{}'::jsonb
    check (jsonb_typeof(customer_evaluation)='object');

create index if not exists performance_evidence_enterprise_idx
  on public.performance_evidence(enterprise_id, period, profile_id);

-- ------------------------------------------------------------ timesheet dimensions
create table if not exists public.worklog_dimensions (
  worklog_id uuid primary key references public.worklogs(id) on delete cascade,
  billable boolean not null default true,
  overtime boolean not null default false,
  work_kind text not null default 'project'
    check (work_kind in ('project','presales','internal')),
  rework boolean not null default false,
  waiting boolean not null default false,
  travel boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Existing history receives the same defaults as new worklogs.
insert into public.worklog_dimensions(worklog_id)
select id from public.worklogs
on conflict (worklog_id) do nothing;

-- Unauthorized attempts are stored separately so a denied RPC can return
-- a payload after the audit row is committed. Business audit rows live in
-- enterprise_identity_audit and may roll back with the rejected operation.
create table if not exists public.operations_security_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid references public.enterprises(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  target_id text not null default '',
  reason text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists operations_security_audit_enterprise_idx
  on public.operations_security_audit(enterprise_id, created_at desc);

-- ------------------------------------------------------------ RLS / least privilege
alter table public.project_economics enable row level security;
alter table public.profile_skills enable row level security;
alter table public.capacity_demands enable row level security;
alter table public.performance_evidence enable row level security;
alter table public.worklog_dimensions enable row level security;
alter table public.operations_security_audit enable row level security;

revoke all on table public.project_economics from public;
revoke all on table public.project_economics from anon;
revoke all on table public.project_economics from authenticated;
revoke all on table public.profile_skills from public;
revoke all on table public.profile_skills from anon;
revoke all on table public.profile_skills from authenticated;
revoke all on table public.capacity_demands from public;
revoke all on table public.capacity_demands from anon;
revoke all on table public.capacity_demands from authenticated;
revoke all on table public.performance_evidence from public;
revoke all on table public.performance_evidence from anon;
revoke all on table public.performance_evidence from authenticated;
revoke all on table public.worklog_dimensions from public;
revoke all on table public.worklog_dimensions from anon;
revoke all on table public.worklog_dimensions from authenticated;
revoke all on table public.operations_security_audit from public;
revoke all on table public.operations_security_audit from anon;
revoke all on table public.operations_security_audit from authenticated;

-- ------------------------------------------------------------ helpers
create or replace function public._operations_number(
  p_data jsonb,
  p_key text,
  p_default numeric default 0
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select greatest(
    coalesce(nullif(btrim(coalesce(p_data->>p_key,'')),'')::numeric,p_default),
    0
  );
$fn$;

create or replace function public._operations_assert_nonnegative(
  p_data jsonb,
  p_keys text[]
) returns void
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_key text;
begin
  foreach v_key in array p_keys loop
    if p_data ? v_key
       and btrim(coalesce(p_data->>v_key,'')) <> ''
       and (p_data->>v_key)::numeric < 0 then
      raise exception 'negative value not allowed: %', v_key;
    end if;
  end loop;
end;
$fn$;

create or replace function public._operations_is_owner(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(
    select 1 from public.enterprises e
     where e.id=p_eid and e.owner_profile_id=p_uid
  );
$fn$;

create or replace function public._operations_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[]
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
  return coalesce(v_permissions ?| p_permissions,false);
end;
$fn$;

create or replace function public._operations_has_company_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if (v_grant->>'permission_key')=any(p_permissions)
       and (v_grant->>'scope')='company' then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_has_scoped_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[],
  p_scopes text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if (v_grant->>'permission_key')=any(p_permissions)
       and coalesce(v_grant->>'scope','self')=any(p_scopes) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_can_access_project(
  p_eid uuid,
  p_uid uuid,
  p_project uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_project_ids jsonb;
  v_scope text;
  v_actor public.profiles%rowtype;
  v_actor_department text;
begin
  if p_uid is null or p_project is null
     or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  select * into v_actor from public.profiles where id=p_uid;
  select em.department into v_actor_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_uid and em.status='active';
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_scope:=coalesce(v_grant->>'scope','self');
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    if v_scope='company' then return true; end if;
    v_project_ids:=case when jsonb_typeof(v_conditions->'project_ids')='array'
      then v_conditions->'project_ids' else '[]'::jsonb end;
    if v_project_ids ? p_project::text
       or coalesce(v_conditions->>'project_id','')=p_project::text then
      return true;
    end if;
    if exists(
      select 1 from public.projects p
       where p.id=p_project
         and lower(btrim(coalesce(p.owner,''))) in (
           lower(btrim(coalesce(v_actor.name,''))),
           lower(btrim(coalesce(v_actor.code,'')))
         )
    ) then
      return true;
    end if;
    if v_scope='self' and exists(
      select 1 from public.tasks t
       where t.project_id=p_project and t.employee_id=p_uid
      union all
      select 1 from public.worklogs w
       where w.project_id=p_project and w.employee_id=p_uid
    ) then
      return true;
    end if;
    if v_scope in ('team','department') and exists(
      select 1
        from public.tasks t
        join public.enterprise_members em
          on em.enterprise_id=p_eid and em.profile_id=t.employee_id
         and em.status='active'
       where t.project_id=p_project
         and em.department=coalesce(v_actor_department,'')
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_can_access_profile(
  p_eid uuid,
  p_uid uuid,
  p_profile uuid,
  p_permissions text[],
  p_allow_self boolean default true
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_profile_ids jsonb;
  v_scope text;
  v_actor_department text;
  v_target_department text;
begin
  if p_uid is null or p_profile is null
     or not public._identity_is_member(p_eid,p_profile) then
    return false;
  end if;
  if p_allow_self and p_uid=p_profile then return true; end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  select em.department into v_actor_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_uid and em.status='active';
  select em.department into v_target_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_profile and em.status='active';
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_scope:=coalesce(v_grant->>'scope','self');
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    if v_scope='company' then return true; end if;
    v_profile_ids:=case when jsonb_typeof(v_conditions->'profile_ids')='array'
      then v_conditions->'profile_ids' else '[]'::jsonb end;
    if v_profile_ids ? p_profile::text
       or coalesce(v_conditions->>'profile_id','')=p_profile::text then
      return true;
    end if;
    if v_scope in ('team','department')
       and coalesce(v_conditions->>'department','')=coalesce(v_target_department,'')
       and v_target_department is not null then
      return true;
    end if;
    if v_scope in ('team','department')
       and not (v_conditions ? 'department')
       and v_actor_department is not null
       and v_actor_department=v_target_department then
      return true;
    end if;
    if v_scope='self' and p_uid=p_profile then return true; end if;
    if v_scope='project' and exists(
      select 1 from public.tasks t
       where t.employee_id=p_profile
         and public._operations_can_access_project(
           p_eid,p_uid,t.project_id,
           array['projects.manage','projects.view_all']::text[]
         )
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_amount_allowed(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[],
  p_amount numeric
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_limit numeric;
  v_found boolean:=false;
begin
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_found:=true;
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    v_limit:=coalesce(
      nullif(v_conditions->>'amount_limit','')::numeric,
      nullif(v_conditions->>'max_amount','')::numeric
    );
    if v_limit is null or coalesce(p_amount,0)<=v_limit then
      return true;
    end if;
  end loop;
  return v_found and false;
end;
$fn$;

create or replace function public._operations_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._operations_has_permission(
    p_eid,p_uid,array[
      'company.manage','projects.view_all','projects.manage',
      'people.view_all','people.manage','worklogs.approve',
      'tasks.assign','tasks.grade','finance.view','finance.manage',
      'reports.view','audit.read','rewards.manage','leave.approve',
      'identity.manage_templates','identity.manage_shares',
      'governance.manage','governance.vote'
    ]::text[]
  );
$fn$;

create or replace function public._operations_project_enterprise(
  p_project uuid
) returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select e.id
    from public.projects p
    join public.enterprises e on e.owner_profile_id=p.boss_id
   where p.id=p_project;
$fn$;

create or replace function public._operations_performance_score(
  p_on_time numeric,
  p_first_pass numeric,
  p_rework numeric,
  p_collaboration numeric,
  p_complexity numeric,
  p_business_contribution numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select round(least(greatest(
    least(greatest(coalesce(p_on_time,0),0),1)*30
    +least(greatest(coalesce(p_first_pass,0),0),1)*25
    +(1-least(greatest(coalesce(p_rework,0),0),1))*15
    +least(greatest(coalesce(p_collaboration,0),0),5)/5*10
    +least(greatest(coalesce(p_complexity,0),0),5)/5*12
    +least(greatest(coalesce(p_business_contribution,0),0),5)/5*8,
    0),100),1);
$fn$;

create or replace function public._operations_performance_score(
  p_on_time numeric,
  p_first_pass numeric,
  p_rework numeric,
  p_collaboration numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._operations_performance_score(
    p_on_time,p_first_pass,p_rework,p_collaboration,0,0
  );
$fn$;

create or replace function public._operations_evidence_items(
  p_evidence jsonb
) returns jsonb
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select case
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='array'
      then coalesce(p_evidence,'[]'::jsonb)
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='object'
      and jsonb_typeof(p_evidence->'items')='array'
      then p_evidence->'items'
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='object'
      then jsonb_build_array(p_evidence)
    else '[]'::jsonb end;
$fn$;

create or replace function public._operations_validate_evidence(
  p_eid uuid,
  p_profile uuid,
  p_evidence jsonb
) returns void
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_item jsonb;
  v_type text;
  v_id_text text;
  v_id uuid;
begin
  if jsonb_typeof(p_evidence) not in ('array','object') then
    raise exception 'evidence must be an array or object';
  end if;
  for v_item in
    select value from jsonb_array_elements(
      public._operations_evidence_items(p_evidence)
    )
  loop
    if jsonb_typeof(v_item)<>'object' then
      raise exception 'evidence entries must be objects';
    end if;
    v_type:=lower(btrim(coalesce(v_item->>'type',v_item->>'source_type','')));
    v_id_text:=coalesce(nullif(v_item->>'id',''),nullif(v_item->>'source_id',''));
    if v_type not in ('task','worklog','approval') then
      raise exception 'unsupported evidence type: %', v_type;
    end if;
    if v_id_text is null then
      raise exception 'evidence source id required';
    end if;
    v_id:=v_id_text::uuid;
    if v_type='task' and not exists(
      select 1 from public.tasks t
       join public.enterprises e on e.owner_profile_id=t.boss_id
       where t.id=v_id and t.employee_id=p_profile and e.id=p_eid
    ) then
      raise exception 'evidence task must belong to the employee';
    end if;
    if v_type='worklog' and not exists(
      select 1 from public.worklogs w
       join public.enterprises e on e.owner_profile_id=w.boss_id
       where w.id=v_id and w.employee_id=p_profile and e.id=p_eid
    ) then
      raise exception 'evidence worklog must belong to the employee';
    end if;
    if v_type='approval' and not exists(
      select 1 from public.approval_requests a
       where a.id=v_id and a.requester_profile_id=p_profile
         and a.enterprise_id=p_eid
    ) then
      raise exception 'evidence approval must belong to the employee';
    end if;
  end loop;
end;
$fn$;

create or replace function public._operations_evidence_details(
  p_eid uuid,
  p_evidence jsonb
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_item jsonb;
  v_type text;
  v_id_text text;
  v_id uuid;
  v_label text;
  v_status text;
  v_result jsonb:='[]'::jsonb;
begin
  for v_item in
    select value from jsonb_array_elements(
      public._operations_evidence_items(p_evidence)
    )
  loop
    v_type:=lower(coalesce(v_item->>'type',v_item->>'source_type',''));
    v_id_text:=coalesce(nullif(v_item->>'id',''),nullif(v_item->>'source_id',''));
    v_label:='';v_status:='';
    if v_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then
      v_id:=v_id_text::uuid;
      if v_type='task' then
        select t.title,coalesce(t.accept_status,'') into v_label,v_status
          from public.tasks t where t.id=v_id;
      elsif v_type='worklog' then
        select w.content,coalesce(w.approval_status,'') into v_label,v_status
          from public.worklogs w where w.id=v_id;
      elsif v_type='approval' then
        select a.title,a.status into v_label,v_status
          from public.approval_requests a where a.id=v_id;
      end if;
    end if;
    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'type',v_type,'source_id',v_id_text,'id',v_id_text,
      'label',coalesce(nullif(v_label,''),'Source not found'),
      'status',v_status,'href',v_type||':'||coalesce(v_id_text,'')
    ));
  end loop;
  return v_result;
end;
$fn$;

create or replace function public._operations_denied(
  p_eid uuid,
  p_uid uuid,
  p_operation text,
  p_target text,
  p_reason text,
  p_details jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.operations_security_audit(
    enterprise_id,actor_profile_id,operation,target_id,reason,details
  ) values(
    p_eid,p_uid,btrim(coalesce(p_operation,'')),coalesce(p_target,''),
    btrim(coalesce(p_reason,'permission denied')),coalesce(p_details,'{}'::jsonb)
  );
  return jsonb_build_object(
    'ok',false,'code','permission_denied',
    'error',btrim(coalesce(p_reason,'permission denied'))
  );
end;
$fn$;

create or replace function public._operations_validate_project_economics()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if not exists(
    select 1
      from public.projects p
      join public.enterprises e on e.owner_profile_id=p.boss_id
     where p.id=NEW.project_id and e.id=NEW.enterprise_id
  ) then
    raise exception 'project and enterprise do not match';
  end if;
  return NEW;
end;
$fn$;

drop trigger if exists trg_operations_project_economics_validate
  on public.project_economics;
create trigger trg_operations_project_economics_validate
before insert or update on public.project_economics
for each row execute function public._operations_validate_project_economics();

create or replace function public._operations_worklog_defaults()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_eid uuid;
begin
  insert into public.worklog_dimensions(worklog_id)
  values(NEW.id)
  on conflict (worklog_id) do nothing;

  v_eid:=public._identity_bootstrap(NEW.boss_id);
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,auth.uid(),'operations.worklog.defaults',NEW.employee_id,
    jsonb_build_object('worklog_id',NEW.id)
  );
  return NEW;
end;
$fn$;

drop trigger if exists trg_operations_worklog_defaults on public.worklogs;
create trigger trg_operations_worklog_defaults
after insert on public.worklogs
for each row execute function public._operations_worklog_defaults();

revoke all on function public._operations_number(jsonb,text,numeric) from public;
revoke all on function public._operations_number(jsonb,text,numeric) from anon;
revoke all on function public._operations_number(jsonb,text,numeric) from authenticated;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from public;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from anon;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from authenticated;
revoke all on function public._operations_is_owner(uuid,uuid) from public;
revoke all on function public._operations_is_owner(uuid,uuid) from anon;
revoke all on function public._operations_is_owner(uuid,uuid) from authenticated;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from public;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from anon;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from public;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from anon;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from public;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from anon;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from authenticated;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from public;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from anon;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from public;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from anon;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from authenticated;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from public;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from anon;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from authenticated;
revoke all on function public._operations_has_management(uuid,uuid) from public;
revoke all on function public._operations_has_management(uuid,uuid) from anon;
revoke all on function public._operations_has_management(uuid,uuid) from authenticated;
revoke all on function public._operations_project_enterprise(uuid) from public;
revoke all on function public._operations_project_enterprise(uuid) from anon;
revoke all on function public._operations_project_enterprise(uuid) from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from authenticated;
revoke all on function public._operations_evidence_items(jsonb) from public;
revoke all on function public._operations_evidence_items(jsonb) from anon;
revoke all on function public._operations_evidence_items(jsonb) from authenticated;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from public;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from anon;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from authenticated;
revoke all on function public._operations_evidence_details(uuid,jsonb) from public;
revoke all on function public._operations_evidence_details(uuid,jsonb) from anon;
revoke all on function public._operations_evidence_details(uuid,jsonb) from authenticated;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from public;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from anon;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from authenticated;
revoke all on function public._operations_validate_project_economics() from public;
revoke all on function public._operations_validate_project_economics() from anon;
revoke all on function public._operations_validate_project_economics() from authenticated;
revoke all on function public._operations_worklog_defaults() from public;
revoke all on function public._operations_worklog_defaults() from anon;
revoke all on function public._operations_worklog_defaults() from authenticated;
-- ------------------------------------------------------------ project economics RPC
create or replace function public.upsert_project_economics(
  p_project uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_project_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_row public.project_economics%rowtype;
  v_projected numeric;
  v_contract numeric;
  v_amount numeric;
  v_amount_key text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  v_project_eid:=public._operations_project_enterprise(p_project);
  if v_project_eid is null then raise exception 'project not found'; end if;
  if v_project_eid<>v_eid then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'cross-enterprise project access denied',
      jsonb_build_object(
        'project_id',p_project,'project_enterprise_id',v_project_eid,
        'actor_enterprise_id',v_eid
      )
    );
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'finance or project management permission required',
      jsonb_build_object('project_id',p_project)
    );
  end if;
  if not public._operations_can_access_project(
    v_eid,v_uid,p_project,
    array['finance.manage','projects.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'project scope does not allow this operation',
      jsonb_build_object('project_id',p_project)
    );
  end if;

  v_contract:=case when v_data ? 'contract_amount'
    then public._operations_number(v_data,'contract_amount')
    else coalesce((
      select pe.contract_amount from public.project_economics pe
       where pe.project_id=p_project
    ),0) end;
  if not public._operations_amount_allowed(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[],v_contract
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'project amount exceeds permission condition',
      jsonb_build_object('project_id',p_project,'contract_amount',v_contract)
    );
  end if;

  perform public._operations_assert_nonnegative(
    v_data,
    array[
      'contract_amount','invoiced_amount','collected_amount',
      'outsourced_committed','outsourced_paid','labor_cost',
      'estimated_completion_cost','other_cost'
    ]::text[]
  );

  foreach v_amount_key in array array[
    'contract_amount','invoiced_amount','collected_amount',
    'outsourced_committed','outsourced_paid','labor_cost',
    'estimated_completion_cost','other_cost'
  ]::text[]
  loop
    if v_data ? v_amount_key then
      v_amount:=public._operations_number(v_data,v_amount_key);
      if not public._operations_amount_allowed(
        v_eid,v_uid,
        array['finance.manage','projects.manage']::text[],v_amount
      ) then
        return public._operations_denied(
          v_eid,v_uid,'upsert_project_economics',p_project::text,
          'monetary field exceeds permission condition',
          jsonb_build_object(
            'project_id',p_project,'field',v_amount_key,
            'amount',v_amount
          )
        );
      end if;
    end if;
  end loop;

  insert into public.project_economics as pe(
    project_id,enterprise_id,contract_amount,invoiced_amount,collected_amount,
    outsourced_committed,outsourced_paid,labor_cost,
    estimated_completion_cost,other_cost,invoice_due_date,payment_terms,
    updated_by,updated_at
  ) values(
    p_project,v_eid,
    public._operations_number(v_data,'contract_amount'),
    public._operations_number(v_data,'invoiced_amount'),
    public._operations_number(v_data,'collected_amount'),
    public._operations_number(v_data,'outsourced_committed'),
    public._operations_number(v_data,'outsourced_paid'),
    public._operations_number(v_data,'labor_cost'),
    public._operations_number(v_data,'estimated_completion_cost'),
    public._operations_number(v_data,'other_cost'),
    nullif(v_data->>'invoice_due_date','')::date,
    coalesce(v_data->>'payment_terms',''),
    v_uid,now()
  )
  on conflict (project_id) do update set
    contract_amount=case when v_data ? 'contract_amount'
      then public._operations_number(v_data,'contract_amount')
      else pe.contract_amount end,
    invoiced_amount=case when v_data ? 'invoiced_amount'
      then public._operations_number(v_data,'invoiced_amount')
      else pe.invoiced_amount end,
    collected_amount=case when v_data ? 'collected_amount'
      then public._operations_number(v_data,'collected_amount')
      else pe.collected_amount end,
    outsourced_committed=case when v_data ? 'outsourced_committed'
      then public._operations_number(v_data,'outsourced_committed')
      else pe.outsourced_committed end,
    outsourced_paid=case when v_data ? 'outsourced_paid'
      then public._operations_number(v_data,'outsourced_paid')
      else pe.outsourced_paid end,
    labor_cost=case when v_data ? 'labor_cost'
      then public._operations_number(v_data,'labor_cost')
      else pe.labor_cost end,
    estimated_completion_cost=case when v_data ? 'estimated_completion_cost'
      then public._operations_number(v_data,'estimated_completion_cost')
      else pe.estimated_completion_cost end,
    other_cost=case when v_data ? 'other_cost'
      then public._operations_number(v_data,'other_cost')
      else pe.other_cost end,
    invoice_due_date=case when v_data ? 'invoice_due_date'
      then nullif(v_data->>'invoice_due_date','')::date
      else pe.invoice_due_date end,
    payment_terms=case when v_data ? 'payment_terms'
      then coalesce(v_data->>'payment_terms','')
      else pe.payment_terms end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  v_projected:=case when v_row.estimated_completion_cost>0
    then v_row.estimated_completion_cost
    else v_row.labor_cost+v_row.outsourced_committed+v_row.other_cost end;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.economics.updated',null,
    jsonb_build_object(
      'project_id',p_project,'contract_amount',v_row.contract_amount,
      'invoiced_amount',v_row.invoiced_amount,
      'collected_amount',v_row.collected_amount,
      'outsourced_committed',v_row.outsourced_committed,
      'outsourced_paid',v_row.outsourced_paid,
      'other_cost',v_row.other_cost,
      'labor_cost',v_row.labor_cost,
      'estimated_completion_cost',v_row.estimated_completion_cost,
      'invoice_due_date',v_row.invoice_due_date,
      'payment_terms',v_row.payment_terms
    )
  );

  return to_jsonb(v_row)||jsonb_build_object(
    'projected_completion_cost',v_projected,
    'projected_margin',v_row.contract_amount-v_projected,
    'projected_margin_percent',case when v_row.contract_amount>0
      then round((v_row.contract_amount-v_projected)/v_row.contract_amount*100,2)
      else 0 end,
    'collection_gap',greatest(v_row.contract_amount-v_row.collected_amount,0),
    'unpaid_invoice',greatest(v_row.invoiced_amount-v_row.collected_amount,0),
    'committed_amount',v_row.outsourced_committed
  );
end;
$fn$;

-- ------------------------------------------------------------ skill RPC
create or replace function public.upsert_profile_skill(
  p_profile uuid,
  p_skill text,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_skill text:=btrim(coalesce(p_skill,''));
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_level integer:=coalesce((v_data->>'level')::integer,1);
  v_available numeric;
  v_valid_until date;
  v_row public.profile_skills%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'profile must be an active enterprise member';
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['people.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_profile_skill',p_profile::text,
      'people.manage permission required',
      jsonb_build_object('profile_id',p_profile,'skill',v_skill)
    );
  end if;
  if not public._operations_can_access_profile(
    v_eid,v_uid,p_profile,array['people.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_profile_skill',p_profile::text,
      'people scope does not allow this profile',
      jsonb_build_object('profile_id',p_profile,'skill',v_skill)
    );
  end if;
  if v_skill='' then raise exception 'skill required'; end if;
  if v_level<1 or v_level>5 then raise exception 'level must be between 1 and 5'; end if;
  v_available:=public._operations_number(v_data,'available_hours');
  v_valid_until:=nullif(v_data->>'valid_until','')::date;

  insert into public.profile_skills as ps(
    enterprise_id,profile_id,skill,level,certified,certification,
    available_hours,valid_until,updated_by,updated_at
  ) values(
    v_eid,p_profile,v_skill,v_level,
    coalesce((v_data->>'certified')::boolean,false),
    coalesce(v_data->>'certification',''),v_available,v_valid_until,
    v_uid,now()
  )
  on conflict (enterprise_id,profile_id,skill) do update set
    level=case when v_data ? 'level' then v_level
      else ps.level end,
    certified=case when v_data ? 'certified'
      then coalesce((v_data->>'certified')::boolean,false)
      else ps.certified end,
    certification=case when v_data ? 'certification'
      then coalesce(v_data->>'certification','')
      else ps.certification end,
    available_hours=case when v_data ? 'available_hours' then v_available
      else ps.available_hours end,
    valid_until=case when v_data ? 'valid_until' then v_valid_until
      else ps.valid_until end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.skill.updated',p_profile,
    jsonb_build_object(
      'profile_id',p_profile,'skill',v_row.skill,'level',v_row.level,
      'certified',v_row.certified,'available_hours',v_row.available_hours,
      'valid_until',v_row.valid_until
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

-- ------------------------------------------------------------ capacity demand RPC
create or replace function public.upsert_capacity_demand(
  p_demand uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_existing public.capacity_demands%rowtype;
  v_id uuid:=p_demand;
  v_skill text:=nullif(btrim(coalesce(v_data->>'skill','')),'');
  v_required numeric:=case when v_data ? 'required_hours'
    then public._operations_number(v_data,'required_hours') else null end;
  v_from date:=case when v_data ? 'needed_from'
    then nullif(v_data->>'needed_from','')::date else null end;
  v_until date:=case when v_data ? 'needed_until'
    then nullif(v_data->>'needed_until','')::date else null end;
  v_project uuid:=case when v_data ? 'project_id'
    then nullif(v_data->>'project_id','')::uuid else null end;
  v_owner uuid:=case when v_data ? 'owner_profile_id'
    then nullif(v_data->>'owner_profile_id','')::uuid else null end;
  v_scope_project uuid;
  v_row public.capacity_demands%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_permission(
    v_eid,v_uid,array['projects.manage','people.manage','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
      'project or people management permission required',
      jsonb_build_object('demand_id',p_demand)
    );
  end if;

  if v_id is not null then
    select * into v_existing from public.capacity_demands
     where id=v_id and enterprise_id=v_eid for update;
    if not found then raise exception 'capacity demand not found'; end if;
    v_scope_project:=case when v_data ? 'project_id'
      then v_project else v_existing.project_id end;
  else
    v_scope_project:=v_project;
  end if;
  if v_scope_project is not null then
    if not public._operations_can_access_project(
      v_eid,v_uid,v_scope_project,
      array['projects.manage','people.manage','company.manage']::text[]
    ) then
      return public._operations_denied(
        v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
        'project scope does not allow this capacity demand',
        jsonb_build_object('demand_id',p_demand,'project_id',v_scope_project)
      );
    end if;
  elsif not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
      'company-wide people management permission required for unassigned demand',
      jsonb_build_object('demand_id',p_demand)
    );
  end if;

  if v_id is not null then
    v_skill:=coalesce(v_skill,v_existing.skill);
    v_required:=coalesce(v_required,v_existing.required_hours);
    v_from:=coalesce(v_from,v_existing.needed_from);
    v_until:=coalesce(v_until,v_existing.needed_until);
    v_project:=case when v_data ? 'project_id'
      then v_project else v_existing.project_id end;
    v_owner:=case when v_data ? 'owner_profile_id'
      then v_owner else v_existing.owner_profile_id end;
  else
    v_from:=coalesce(v_from,current_date);
    v_until:=coalesce(v_until,current_date+28);
  end if;

  if v_skill is null or v_skill='' then raise exception 'skill required'; end if;
  if v_required is null or v_required<=0 then
    raise exception 'required_hours must be positive';
  end if;
  if v_until<v_from then raise exception 'needed_until must not precede needed_from'; end if;
  if v_project is not null and public._operations_project_enterprise(v_project)<>v_eid then
    raise exception 'project not in enterprise';
  end if;
  if v_owner is not null and not public._identity_is_member(v_eid,v_owner) then
    raise exception 'owner must be an active enterprise member';
  end if;

  if v_id is null then
    insert into public.capacity_demands(
      enterprise_id,skill,required_hours,needed_from,needed_until,
      project_id,owner_profile_id,note,created_by,updated_by
    ) values(
      v_eid,v_skill,v_required,v_from,v_until,v_project,v_owner,
      coalesce(v_data->>'note',''),v_uid,v_uid
    ) returning * into v_row;
  else
    update public.capacity_demands set
      skill=case when v_data ? 'skill' then v_skill else skill end,
      required_hours=case when v_data ? 'required_hours' then v_required
        else required_hours end,
      needed_from=case when v_data ? 'needed_from' then v_from
        else needed_from end,
      needed_until=case when v_data ? 'needed_until' then v_until
        else needed_until end,
      project_id=case when v_data ? 'project_id' then v_project
        else project_id end,
      owner_profile_id=case when v_data ? 'owner_profile_id' then v_owner
        else owner_profile_id end,
      note=case when v_data ? 'note' then coalesce(v_data->>'note','')
        else note end,
      updated_by=v_uid,updated_at=now()
    where id=v_id and enterprise_id=v_eid
    returning * into v_row;
    if not found then raise exception 'capacity demand not found'; end if;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.capacity.updated',v_row.owner_profile_id,
    jsonb_build_object(
      'demand_id',v_row.id,'skill',v_row.skill,
      'required_hours',v_row.required_hours,'project_id',v_row.project_id,
      'needed_from',v_row.needed_from,'needed_until',v_row.needed_until
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

-- ------------------------------------------------------------ worklog dimensions RPC
create or replace function public.upsert_worklog_dimensions(
  p_worklog uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_worklog public.worklogs%rowtype;
  v_eid uuid;
  v_kind text:=coalesce(v_data->>'work_kind','project');
  v_row public.worklog_dimensions%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_worklog from public.worklogs where id=p_worklog for update;
  if not found then raise exception 'worklog not found'; end if;
  v_eid:=public._identity_bootstrap(v_worklog.boss_id);
  if v_uid<>v_worklog.employee_id and not public._operations_can_access_profile(
    v_eid,v_uid,v_worklog.employee_id,
    array['worklogs.approve','people.manage','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_worklog_dimensions',p_worklog::text,
      'worklog permission required',
      jsonb_build_object('worklog_id',p_worklog,
                         'employee_id',v_worklog.employee_id)
    );
  end if;
  if v_kind not in ('project','presales','internal') then
    raise exception 'invalid work_kind';
  end if;

  insert into public.worklog_dimensions as wd(
    worklog_id,billable,overtime,work_kind,rework,waiting,travel,
    updated_by,updated_at
  ) values(
    p_worklog,
    coalesce((v_data->>'billable')::boolean,true),
    coalesce((v_data->>'overtime')::boolean,false),
    v_kind,
    coalesce((v_data->>'rework')::boolean,false),
    coalesce((v_data->>'waiting')::boolean,false),
    coalesce((v_data->>'travel')::boolean,false),
    v_uid,now()
  )
  on conflict (worklog_id) do update set
    billable=case when v_data ? 'billable'
      then coalesce((v_data->>'billable')::boolean,true)
      else wd.billable end,
    overtime=case when v_data ? 'overtime'
      then coalesce((v_data->>'overtime')::boolean,false)
      else wd.overtime end,
    work_kind=case when v_data ? 'work_kind'
      then v_kind else wd.work_kind end,
    rework=case when v_data ? 'rework'
      then coalesce((v_data->>'rework')::boolean,false)
      else wd.rework end,
    waiting=case when v_data ? 'waiting'
      then coalesce((v_data->>'waiting')::boolean,false)
      else wd.waiting end,
    travel=case when v_data ? 'travel'
      then coalesce((v_data->>'travel')::boolean,false)
      else wd.travel end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.worklog.dimensions.updated',v_worklog.employee_id,
    jsonb_build_object(
      'worklog_id',p_worklog,'billable',v_row.billable,
      'overtime',v_row.overtime,'work_kind',v_row.work_kind,
      'rework',v_row.rework,'waiting',v_row.waiting,'travel',v_row.travel
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.get_worklog_dimensions(
  p_worklog uuid
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_worklog public.worklogs%rowtype;
  v_eid uuid;
  v_row public.worklog_dimensions%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_worklog from public.worklogs where id=p_worklog;
  if not found then raise exception 'worklog not found'; end if;
  v_eid:=public._identity_bootstrap(v_worklog.boss_id);
  if v_uid<>v_worklog.employee_id and not public._operations_can_access_profile(
    v_eid,v_uid,v_worklog.employee_id,
    array['worklogs.approve','people.manage','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'get_worklog_dimensions',p_worklog::text,
      'worklog permission required',
      jsonb_build_object('worklog_id',p_worklog)
    );
  end if;
  select * into v_row from public.worklog_dimensions where worklog_id=p_worklog;
  if not found then
    return jsonb_build_object(
      'worklog_id',p_worklog,'billable',true,'overtime',false,
      'work_kind','project','rework',false,'waiting',false,'travel',false
    );
  end if;
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.worklog_dimensions(
  p_worklog uuid,
  p_data jsonb
) returns jsonb
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  select public.upsert_worklog_dimensions(p_worklog,p_data);
$fn$;
-- ------------------------------------------------------------ performance evidence RPCs
create or replace function public.upsert_performance_evidence(
  p_profile uuid,
  p_period text,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_period text:=btrim(coalesce(p_period,''));
  v_on_time numeric:=coalesce((v_data->>'on_time_rate')::numeric,0);
  v_first_pass numeric:=coalesce((v_data->>'first_pass_rate')::numeric,0);
  v_rework numeric:=coalesce((v_data->>'rework_rate')::numeric,0);
  v_collaboration numeric:=coalesce((v_data->>'collaboration_score')::numeric,0);
  v_complexity numeric:=coalesce((v_data->>'complexity_score')::numeric,0);
  v_contribution numeric:=coalesce((v_data->>'business_contribution')::numeric,0);
  v_customer jsonb:=coalesce(v_data->'customer_evaluation','{}'::jsonb);
  v_customer_score numeric;
  v_evidence jsonb:=coalesce(v_data->'evidence','[]'::jsonb);
  v_row public.performance_evidence%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'profile must be an active enterprise member';
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','tasks.grade','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_performance_evidence',p_profile::text,
      'performance review permission required',
      jsonb_build_object('profile_id',p_profile,'period',v_period)
    );
  end if;
  if not public._operations_can_access_profile(
    v_eid,v_uid,p_profile,
    array['people.manage','tasks.grade','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_performance_evidence',p_profile::text,
      'people scope does not allow this performance evidence',
      jsonb_build_object('profile_id',p_profile,'period',v_period)
    );
  end if;
  if v_period='' then raise exception 'period required'; end if;
  if v_on_time<0 or v_on_time>1 or v_first_pass<0 or v_first_pass>1
     or v_rework<0 or v_rework>1 then
    raise exception 'performance rates must be between 0 and 1';
  end if;
  if v_collaboration<0 or v_collaboration>5
     or v_complexity<0 or v_complexity>5
     or v_contribution<0 or v_contribution>5 then
    raise exception 'performance scores must be between 0 and 5';
  end if;
  if jsonb_typeof(v_customer)<>'object' then
    raise exception 'customer evaluation must be an object';
  end if;
  if v_customer ? 'score' then
    v_customer_score:=(v_customer->>'score')::numeric;
    if v_customer_score<0 or v_customer_score>5 then
      raise exception 'customer evaluation score must be between 0 and 5';
    end if;
  end if;
  perform public._operations_validate_evidence(v_eid,p_profile,v_evidence);
  if exists(
    select 1 from public.performance_evidence
     where enterprise_id=v_eid and profile_id=p_profile
       and period=v_period and status='reviewed'
  ) then
    raise exception 'reviewed performance evidence is immutable';
  end if;

  insert into public.performance_evidence as pe(
    enterprise_id,profile_id,period,on_time_rate,first_pass_rate,
    rework_rate,collaboration_score,complexity_score,business_contribution,
    customer_evaluation,evidence,status,score,created_at,updated_at
  ) values(
    v_eid,p_profile,v_period,v_on_time,v_first_pass,v_rework,
    v_collaboration,v_complexity,v_contribution,v_customer,v_evidence,
    'draft',0,now(),now()
  )
  on conflict (enterprise_id,profile_id,period) do update set
    on_time_rate=excluded.on_time_rate,
    first_pass_rate=excluded.first_pass_rate,
    rework_rate=excluded.rework_rate,
    collaboration_score=excluded.collaboration_score,
    complexity_score=excluded.complexity_score,
    business_contribution=excluded.business_contribution,
    customer_evaluation=excluded.customer_evaluation,
    evidence=excluded.evidence,
    status=case when pe.status='submitted'
      then 'submitted' else 'draft' end,
    score=0,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.performance.updated',p_profile,
    jsonb_build_object(
      'performance_id',v_row.id,'period',v_period,
      'status',v_row.status,'evidence',v_row.evidence,
      'customer_evaluation',v_row.customer_evaluation,
      'complexity_score',v_row.complexity_score,
      'business_contribution',v_row.business_contribution
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.get_my_performance_evidence()
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
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  return jsonb_build_object(
    'enterprise_id',v_eid,
    'items',(
      select coalesce(jsonb_agg(
        to_jsonb(e)||jsonb_build_object(
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,
              e.rework_rate,e.collaboration_score,
              e.complexity_score,e.business_contribution)
          end,
          'evidence_details',public._operations_evidence_details(
            v_eid,e.evidence
          )
        ) order by e.period desc,e.updated_at desc
      ),'[]'::jsonb)
      from public.performance_evidence e
      where e.enterprise_id=v_eid and e.profile_id=v_uid
    )
  );
end;
$fn$;

create or replace function public.submit_performance_statement(
  p_evidence uuid,
  p_statement text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_statement text:=btrim(coalesce(p_statement,''));
  v_row public.performance_evidence%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.performance_evidence
   where id=p_evidence for update;
  if not found then raise exception 'performance evidence not found'; end if;
  if v_row.profile_id<>v_uid then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'submit_performance_statement',p_evidence::text,
      'performance evidence belongs to another member',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_row.status='reviewed' then
    raise exception 'reviewed performance evidence is immutable';
  end if;
  if v_statement='' then raise exception 'statement required'; end if;

  update public.performance_evidence set
    employee_statement=v_statement,status='submitted',updated_at=now()
  where id=p_evidence
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'operations.performance.statement',v_uid,
    jsonb_build_object('performance_id',p_evidence)
  );
  return to_jsonb(v_row)||jsonb_build_object(
    'score',public._operations_performance_score(
      v_row.on_time_rate,v_row.first_pass_rate,
      v_row.rework_rate,v_row.collaboration_score,
      v_row.complexity_score,v_row.business_contribution),
    'evidence_details',public._operations_evidence_details(
      v_row.enterprise_id,v_row.evidence)
  );
end;
$fn$;

create or replace function public.review_performance_evidence(
  p_evidence uuid,
  p_note text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.performance_evidence%rowtype;
  v_score numeric;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.performance_evidence
   where id=p_evidence for update;
  if not found then raise exception 'performance evidence not found'; end if;
  if not public._operations_has_permission(
    v_row.enterprise_id,v_uid,
    array['people.manage','tasks.grade','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'performance review permission required',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if not public._operations_can_access_profile(
    v_row.enterprise_id,v_uid,v_row.profile_id,
    array['people.manage','tasks.grade','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'people scope does not allow this performance review',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_row.profile_id=v_uid then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'self-review is not allowed',jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_note='' then raise exception 'review note required'; end if;
  if v_row.status='reviewed' then
    return to_jsonb(v_row)||jsonb_build_object(
      'duplicate',true,
      'evidence_details',public._operations_evidence_details(
        v_row.enterprise_id,v_row.evidence)
    );
  end if;

  v_score:=public._operations_performance_score(
    v_row.on_time_rate,v_row.first_pass_rate,
    v_row.rework_rate,v_row.collaboration_score,
    v_row.complexity_score,v_row.business_contribution
  );
  update public.performance_evidence set
    score=v_score,status='reviewed',reviewer_note=v_note,
    reviewed_by=v_uid,reviewed_at=now(),updated_at=now()
  where id=p_evidence
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'operations.performance.reviewed',
    v_row.profile_id,
    jsonb_build_object(
      'performance_id',p_evidence,'period',v_row.period,
      'score',v_score,'note',v_note,
      'complexity_score',v_row.complexity_score,
      'business_contribution',v_row.business_contribution
    )
  );
  return to_jsonb(v_row)||jsonb_build_object(
    'duplicate',false,
    'evidence_details',public._operations_evidence_details(
      v_row.enterprise_id,v_row.evidence)
  );
end;
$fn$;
-- ------------------------------------------------------------ management dashboard
create or replace function public.get_operations_dashboard(
  p_weeks integer default 4
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_owner uuid;
  v_weeks integer:=least(greatest(coalesce(p_weeks,4),2),4);
  v_start date:=current_date;
  v_end date:=current_date+(least(greatest(coalesce(p_weeks,4),2),4)*7)-1;
  v_can_finance boolean:=false;
  v_can_people boolean:=false;
  v_can_projects boolean:=false;
  v_can_capacity boolean:=false;
  v_can_performance boolean:=false;
  v_can_worklogs boolean:=false;
  v_can_audit boolean:=false;
  v_capacity_blocked boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_management(v_eid,v_uid) then
    return public._operations_denied(
      v_eid,v_uid,'get_operations_dashboard','',
      'management permission required',jsonb_build_object('weeks',v_weeks)
    );
  end if;
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;

  v_can_finance:=public._operations_has_company_permission(
    v_eid,v_uid,array['finance.view','finance.manage']::text[]
  );
  v_can_people:=public._operations_has_scoped_permission(
    v_eid,v_uid,array['people.view_all','people.manage']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_projects:=public._operations_has_scoped_permission(
    v_eid,v_uid,array['projects.view_all','projects.manage']::text[],
    array['company','team','department','project','self']::text[]
  ) or v_can_finance;
  -- Gap math needs both demand and availability. A project-only manager
  -- cannot see people availability, so returning demand as shortage would
  -- manufacture a false capacity result.
  v_can_capacity:=v_can_people;
  v_capacity_blocked:=v_can_projects and not v_can_people;
  v_can_performance:=public._operations_has_scoped_permission(
    v_eid,v_uid,
    array['people.view_all','people.manage','tasks.grade']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_worklogs:=public._operations_has_scoped_permission(
    v_eid,v_uid,
    array['worklogs.approve','people.view_all','people.manage',
          'reports.view','finance.view','finance.manage']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_audit:=public._operations_has_company_permission(
    v_eid,v_uid,array['audit.read']::text[]
  );

  -- Resolve finance items that are no longer overdue.
  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then 'Collection is no longer overdue'
                         else d.resolution end,
         version=d.version+1,updated_at=now()
   where d.enterprise_id=v_eid and d.source_type='finance'
     and d.status in ('open','acknowledged','assigned','deferred')
     and not exists(
       select 1 from public.project_economics pe
        where pe.project_id=d.source_id
          and pe.invoice_due_date<current_date
          and pe.invoiced_amount>pe.collected_amount
     );

  -- Phase 2A owns the queue; Phase 2B feeds collection risks into it.
  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    v_eid,'finance',pe.project_id,
    'Overdue collection: '||p.name,
    'Invoice due '||pe.invoice_due_date::text||
      case when pe.payment_terms<>'' then ' ('||pe.payment_terms||')' else '' end,
    jsonb_build_array(jsonb_build_object(
      'type','finance','project_id',pe.project_id,
      'invoice_due_date',pe.invoice_due_date,
      'payment_terms',pe.payment_terms,
      'invoiced_amount',pe.invoiced_amount,
      'collected_amount',pe.collected_amount,
      'unpaid_invoice',greatest(pe.invoiced_amount-pe.collected_amount,0))),
    case when current_date-pe.invoice_due_date>=30 then 'severe'
         when current_date-pe.invoice_due_date>=7 then 'risk'
         else 'attention' end,
    greatest(current_date-pe.invoice_due_date,0),
    greatest(pe.invoiced_amount-pe.collected_amount,0),
    pe.invoice_due_date::timestamptz,
    v_owner,'open','',
    current_date::timestamptz+interval '1 day',now(),now()
  from public.project_economics pe
  join public.projects p on p.id=pe.project_id
  where v_can_finance
    and pe.enterprise_id=v_eid and p.boss_id=v_owner
    and pe.invoice_due_date<current_date
    and pe.invoiced_amount>pe.collected_amount
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,detail=excluded.detail,evidence=excluded.evidence,
    risk=excluded.risk,impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,owner_profile_id=excluded.owner_profile_id,
    status='open',resolution='',due_at=excluded.due_at,updated_at=now();

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'management_only',true,
    'window_weeks',v_weeks,
    'period_start',v_start,
    'period_end',v_end,
    'access',jsonb_build_object(
      'can_projects',v_can_projects,
      'can_finance',v_can_finance,
      'can_people',v_can_people,
      'can_capacity',v_can_capacity,
      'capacity_requires_people_scope',v_capacity_blocked,
      'capacity_permission_message',case when v_capacity_blocked
        then 'Capacity gaps require people visibility scope; demand is hidden without it.'
        else '' end,
      'can_performance',v_can_performance,
      'can_worklogs',v_can_worklogs,
      'can_audit',v_can_audit,
      'can_manage_economics',public._operations_has_permission(
        v_eid,v_uid,array['finance.manage','projects.manage']::text[]),
      'can_manage_skills',public._operations_has_permission(
        v_eid,v_uid,array['people.manage']::text[]),
      'can_manage_capacity',v_can_capacity,
      'can_manage_performance',v_can_performance
    ),
    'projects',(
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'project_id',x.project_id,'name',x.name,'owner',x.owner,
          'status',x.status,
          'can_edit',public._operations_can_access_project(
            v_eid,v_uid,x.project_id,
            array['finance.manage','projects.manage']::text[])
        )
        ||case when v_can_finance then jsonb_build_object(
          'contract_amount',x.contract_amount,
          'invoiced_amount',x.invoiced_amount,
          'collected_amount',x.collected_amount,
          'outsourced_committed',x.outsourced_committed,
          'committed_amount',x.outsourced_committed,
          'outsourced_paid',x.outsourced_paid,
          'labor_cost',x.labor_cost,
          'other_cost',x.other_cost,
          'projected_completion_cost',x.projected_cost,
          'projected_cost',x.projected_cost,
          'projected_margin',x.projected_margin,
          'projected_margin_percent',case when x.contract_amount>0
            then round(x.projected_margin/x.contract_amount*100,2) else 0 end,
          'collection_gap',greatest(x.contract_amount-x.collected_amount,0),
          'invoice_gap',greatest(x.contract_amount-x.invoiced_amount,0),
          'unpaid_invoice',greatest(x.invoiced_amount-x.collected_amount,0),
          'invoice_due_date',x.invoice_due_date,
          'payment_terms',x.payment_terms,
          'overdue_days',case when x.invoice_due_date<current_date
            and x.invoiced_amount>x.collected_amount
            then current_date-x.invoice_due_date else 0 end,
          'overdue_amount',case when x.invoice_due_date<current_date
            and x.invoiced_amount>x.collected_amount
            then x.invoiced_amount-x.collected_amount else 0 end
        ) else '{}'::jsonb end
        order by x.name),'[]'::jsonb)
      from (
        select p.id project_id,p.name,p.owner,p.status,
          coalesce(pe.contract_amount,0) contract_amount,
          coalesce(pe.invoiced_amount,0) invoiced_amount,
          coalesce(pe.collected_amount,0) collected_amount,
          coalesce(pe.outsourced_committed,0) outsourced_committed,
          coalesce(pe.outsourced_paid,0) outsourced_paid,
          coalesce(pe.labor_cost,0) labor_cost,
          coalesce(pe.other_cost,0) other_cost,
          pe.invoice_due_date,coalesce(pe.payment_terms,'') payment_terms,
          case when coalesce(pe.estimated_completion_cost,0)>0
            then pe.estimated_completion_cost
            else coalesce(pe.labor_cost,0)
              +coalesce(pe.outsourced_committed,0)
              +coalesce(pe.other_cost,0) end projected_cost,
          coalesce(pe.contract_amount,0)
            -case when coalesce(pe.estimated_completion_cost,0)>0
              then pe.estimated_completion_cost
              else coalesce(pe.labor_cost,0)
                +coalesce(pe.outsourced_committed,0)
                +coalesce(pe.other_cost,0) end projected_margin
        from public.projects p
        left join public.project_economics pe on pe.project_id=p.id
        where p.boss_id=v_owner
          and public._operations_can_access_project(
            v_eid,v_uid,p.id,
            array['projects.view_all','projects.manage',
                  'finance.view','finance.manage']::text[])
      ) x
    ),
    'collection_alerts',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_id',p.id,'name',p.name,
        'invoice_due_date',pe.invoice_due_date,
        'payment_terms',pe.payment_terms,
        'overdue_days',current_date-pe.invoice_due_date,
        'overdue_amount',greatest(pe.invoiced_amount-pe.collected_amount,0),
        'risk',case when current_date-pe.invoice_due_date>=30 then 'severe'
          when current_date-pe.invoice_due_date>=7 then 'risk'
          else 'attention' end
      ) order by current_date-pe.invoice_due_date desc),'[]'::jsonb)
      from public.project_economics pe
      join public.projects p on p.id=pe.project_id
      where v_can_finance and pe.enterprise_id=v_eid
        and pe.invoice_due_date<current_date
        and pe.invoiced_amount>pe.collected_amount
    ),
    'skills',(
      select coalesce(jsonb_agg(to_jsonb(ps)||jsonb_build_object(
        'name',p.name,'source_id',ps.profile_id
      ) order by p.name,ps.skill),'[]'::jsonb)
      from public.profile_skills ps
      join public.profiles p on p.id=ps.profile_id
      where v_can_people and ps.enterprise_id=v_eid
        and public._operations_can_access_profile(
          v_eid,v_uid,ps.profile_id,
          array['people.view_all','people.manage']::text[],false)
    ),
    'capacity_demands',(
      select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object(
        'source_id',d.id,'project_name',coalesce(p.name,'')
      ) order by d.needed_from,d.skill),'[]'::jsonb)
      from public.capacity_demands d
      left join public.projects p on p.id=d.project_id
      where v_can_capacity and d.enterprise_id=v_eid
        and (
          (d.project_id is null and v_can_people)
          or (d.project_id is not null and public._operations_can_access_project(
            v_eid,v_uid,d.project_id,
            array['projects.view_all','projects.manage',
                  'people.view_all','people.manage']::text[]))
        )
    ),
    'capacity_gaps',(
      with demand as (
        select d.skill,sum(d.required_hours) required_hours
        from public.capacity_demands d
        where v_can_capacity and d.enterprise_id=v_eid
          and d.needed_from<=v_end and d.needed_until>=v_start
          and (
            (d.project_id is null and v_can_people)
            or (d.project_id is not null and public._operations_can_access_project(
              v_eid,v_uid,d.project_id,
              array['projects.view_all','projects.manage',
                    'people.view_all','people.manage']::text[]))
          )
        group by d.skill
      ), availability as (
        select ps.skill,
          sum(
            coalesce(ps.available_hours,0)
            * greatest(0,
                least(v_end,coalesce(ps.valid_until,v_end))
                -greatest(v_start,current_date)+1
              )/7.0
          ) available_hours
        from public.profile_skills ps
        join public.enterprise_members m
          on m.enterprise_id=ps.enterprise_id
         and m.profile_id=ps.profile_id and m.status='active'
        where v_can_people and ps.enterprise_id=v_eid
          and (ps.valid_until is null or ps.valid_until>=v_start)
          and public._operations_can_access_profile(
            v_eid,v_uid,ps.profile_id,
            array['people.view_all','people.manage']::text[],false)
        group by ps.skill
      ), skills as (
        select skill from demand union select skill from availability
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'skill',s.skill,
        'required_hours',coalesce(d.required_hours,0),
        'available_hours',round(coalesce(a.available_hours,0),2),
        'gap_hours',greatest(
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0),
        'period_start',v_start,'period_end',v_end,
        'status',case when
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0)>0
          then 'shortage' else 'covered' end
      ) order by greatest(
        coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0
      ) desc,s.skill),'[]'::jsonb)
      from skills s
      left join demand d on d.skill=s.skill
      left join availability a on a.skill=s.skill
    ),
    'performance',(
      with acceptance_stats as (
        select
          t.employee_id profile_id,
          to_char(coalesce(max(a.reviewed_at),now()),'YYYY-MM') period,
          count(*) filter(where a.status='accepted') accepted_count,
          count(*) filter(where a.status='rework') rework_count,
          case when count(*) filter(where a.status='accepted')>0 then
            count(*) filter(
              where a.status='accepted' and a.submitted_at::date<=t.plan_date
            )::numeric/count(*) filter(where a.status='accepted')
          else 0 end on_time_rate,
          case when count(*)>0 then
            count(*) filter(where a.status='accepted')::numeric/count(*)
          else 0 end first_pass_rate,
          case when count(*)>0 then
            count(*) filter(where a.status='rework')::numeric/count(*)
          else 0 end rework_rate,
          jsonb_agg(jsonb_build_object(
            'type','task_acceptance','id',a.task_id,'status',a.status,
            'reviewed_at',a.reviewed_at)) evidence
        from public.task_acceptance a
        join public.tasks t on t.id=a.task_id
        where v_can_performance and a.enterprise_id=v_eid
          and a.status in ('accepted','rework')
          and public._operations_can_access_profile(
            v_eid,v_uid,t.employee_id,
            array['people.view_all','people.manage','tasks.grade']::text[],false)
        group by t.employee_id,to_char(coalesce(a.reviewed_at,a.updated_at),'YYYY-MM')
      ), performance_items as (
        select jsonb_build_object(
          'id',e.id,
          'enterprise_id',e.enterprise_id,
          'profile_id',e.profile_id,
          'period',e.period,
          'on_time_rate',e.on_time_rate,
          'first_pass_rate',e.first_pass_rate,
          'rework_rate',e.rework_rate,
          'collaboration_score',e.collaboration_score,
          'complexity_score',e.complexity_score,
          'business_contribution',e.business_contribution,
          'customer_evaluation',e.customer_evaluation,
          'evidence',e.evidence,
          'employee_statement',e.employee_statement,
          'status',e.status,
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,e.rework_rate,
              e.collaboration_score,e.complexity_score,
              e.business_contribution) end,
          'reviewer_note',e.reviewer_note,
          'reviewed_by',e.reviewed_by,
          'reviewed_at',e.reviewed_at,
          'source','manual',
          'source_id',e.id,
          'evidence_details',public._operations_evidence_details(
            v_eid,e.evidence),
          'can_review',public._operations_can_access_profile(
            v_eid,v_uid,e.profile_id,
            array['people.manage','tasks.grade','company.manage']::text[],false)
        ) item,
        p.name sort_name,
        e.period sort_period
        from public.performance_evidence e
        join public.profiles p on p.id=e.profile_id
        where v_can_performance and e.enterprise_id=v_eid
          and public._operations_can_access_profile(
            v_eid,v_uid,e.profile_id,
            array['people.view_all','people.manage','tasks.grade']::text[],false)
        union all
        select jsonb_build_object(
          'id',null,
          'enterprise_id',v_eid,
          'profile_id',s.profile_id,
          'period',s.period,
          'on_time_rate',s.on_time_rate,
          'first_pass_rate',s.first_pass_rate,
          'rework_rate',s.rework_rate,
          'collaboration_score',0,
          'complexity_score',0,
          'business_contribution',0,
          'customer_evaluation','{}'::jsonb,
          'evidence',s.evidence,
          'employee_statement','',
          'status','submitted',
          'score',public._operations_performance_score(
            s.on_time_rate,s.first_pass_rate,s.rework_rate,0,0,0),
          'reviewer_note','Derived from task acceptance records',
          'reviewed_by',null,
          'reviewed_at',null,
          'source','task_acceptance',
          'source_id',null,
          'accepted_count',s.accepted_count,
          'rework_count',s.rework_count,
          'evidence_details',s.evidence,
          'can_review',false
        ) item,
        p.name sort_name,
        s.period sort_period
        from acceptance_stats s
        join public.profiles p on p.id=s.profile_id
      )
      select coalesce(jsonb_agg(
        item order by sort_name,sort_period desc
      ),'[]'::jsonb)
      from performance_items
    ),
    'worklog_summary',(
      with entries as (
        select coalesce(d.work_kind,'project') work_kind,
          coalesce(d.billable,true) billable,
          coalesce(d.overtime,false) overtime,
          coalesce(d.rework,false) rework,
          coalesce(d.waiting,false) waiting,
          coalesce(d.travel,false) travel,
          w.hours
        from public.worklogs w
        left join public.worklog_dimensions d on d.worklog_id=w.id
        where v_can_worklogs and w.boss_id=v_owner
          and w.approval_status='approved'
          and w.work_date between v_start and v_end
          and (
            (w.project_id is null and public._operations_has_company_permission(
              v_eid,v_uid,array['worklogs.approve','people.view_all',
                'people.manage','reports.view','finance.view',
                'finance.manage']::text[]))
            or (w.project_id is not null and public._operations_can_access_project(
              v_eid,v_uid,w.project_id,
              array['worklogs.approve','people.view_all','people.manage',
                    'reports.view','finance.view','finance.manage']::text[]))
          )
      )
      select jsonb_build_object(
        'total_hours',coalesce(sum(hours),0),
        'billable_hours',coalesce(sum(hours) filter(where billable),0),
        'overtime_hours',coalesce(sum(hours) filter(where overtime),0),
        'rework_hours',coalesce(sum(hours) filter(where rework),0),
        'waiting_hours',coalesce(sum(hours) filter(where waiting),0),
        'travel_hours',coalesce(sum(hours) filter(where travel),0),
        'by_kind',coalesce((
          select jsonb_object_agg(k.work_kind,k.hours)
          from (
            select work_kind,sum(hours) hours from entries group by work_kind
          ) k
        ),'{}'::jsonb)
      )
      from entries
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'profile_id',m.profile_id,'name',p.name,
        'department',m.department,'title',m.title
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where (v_can_people or v_can_performance)
        and m.enterprise_id=v_eid and m.status='active'
        and public._operations_can_access_profile(
          v_eid,v_uid,m.profile_id,
          array['people.view_all','people.manage','tasks.grade']::text[],true)
    ),
    'security_audit',(
      select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb)
      from (
        select * from public.operations_security_audit
         where v_can_audit and enterprise_id=v_eid
         order by created_at desc limit 50
      ) a
    )
  );
end;
$fn$;

-- ------------------------------------------------------------ privileges
revoke all on function public.upsert_project_economics(uuid,jsonb) from public;
revoke all on function public.upsert_project_economics(uuid,jsonb) from anon;
revoke all on function public.upsert_project_economics(uuid,jsonb) from authenticated;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from public;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from anon;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from authenticated;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from public;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from anon;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from authenticated;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from public;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from anon;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from authenticated;
revoke all on function public.get_worklog_dimensions(uuid) from public;
revoke all on function public.get_worklog_dimensions(uuid) from anon;
revoke all on function public.get_worklog_dimensions(uuid) from authenticated;
revoke all on function public.worklog_dimensions(uuid,jsonb) from public;
revoke all on function public.worklog_dimensions(uuid,jsonb) from anon;
revoke all on function public.worklog_dimensions(uuid,jsonb) from authenticated;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from public;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from anon;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from authenticated;
revoke all on function public.get_my_performance_evidence() from public;
revoke all on function public.get_my_performance_evidence() from anon;
revoke all on function public.get_my_performance_evidence() from authenticated;
revoke all on function public.submit_performance_statement(uuid,text) from public;
revoke all on function public.submit_performance_statement(uuid,text) from anon;
revoke all on function public.submit_performance_statement(uuid,text) from authenticated;
revoke all on function public.review_performance_evidence(uuid,text) from public;
revoke all on function public.review_performance_evidence(uuid,text) from anon;
revoke all on function public.review_performance_evidence(uuid,text) from authenticated;
revoke all on function public.get_operations_dashboard(integer) from public;
revoke all on function public.get_operations_dashboard(integer) from anon;
revoke all on function public.get_operations_dashboard(integer) from authenticated;

grant execute on function public.upsert_project_economics(uuid,jsonb) to authenticated;
grant execute on function public.upsert_profile_skill(uuid,text,jsonb) to authenticated;
grant execute on function public.upsert_capacity_demand(uuid,jsonb) to authenticated;
grant execute on function public.upsert_worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.get_worklog_dimensions(uuid) to authenticated;
grant execute on function public.worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.upsert_performance_evidence(uuid,text,jsonb) to authenticated;
grant execute on function public.get_my_performance_evidence() to authenticated;
grant execute on function public.submit_performance_statement(uuid,text) to authenticated;
grant execute on function public.review_performance_evidence(uuid,text) to authenticated;
grant execute on function public.get_operations_dashboard(integer) to authenticated;
