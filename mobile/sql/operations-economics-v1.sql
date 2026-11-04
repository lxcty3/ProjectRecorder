-- ============================================================
-- Project Recorder - Phase 2B operations economics
--
-- Deployment order:
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   unified-platform.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
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
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

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

-- ------------------------------------------------------------ RLS / least privilege
alter table public.project_economics enable row level security;
alter table public.profile_skills enable row level security;
alter table public.capacity_demands enable row level security;
alter table public.performance_evidence enable row level security;
alter table public.worklog_dimensions enable row level security;

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
  p_collaboration numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select round(least(greatest(
    least(greatest(coalesce(p_on_time,0),0),1)*35
    +least(greatest(coalesce(p_first_pass,0),0),1)*30
    +(1-least(greatest(coalesce(p_rework,0),0),1))*20
    +least(greatest(coalesce(p_collaboration,0),0),5)/5*15,
    0),100),1);
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

revoke all on function public._operations_number(jsonb,text,numeric)
  from public;
revoke all on function public._operations_number(jsonb,text,numeric)
  from anon;
revoke all on function public._operations_number(jsonb,text,numeric)
  from authenticated;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from public;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from anon;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from authenticated;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from public;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from anon;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from authenticated;
revoke all on function public._operations_has_management(uuid,uuid)
  from public;
revoke all on function public._operations_has_management(uuid,uuid)
  from anon;
revoke all on function public._operations_has_management(uuid,uuid)
  from authenticated;
revoke all on function public._operations_project_enterprise(uuid)
  from public;
revoke all on function public._operations_project_enterprise(uuid)
  from anon;
revoke all on function public._operations_project_enterprise(uuid)
  from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from authenticated;
revoke all on function public._operations_validate_project_economics()
  from public;
revoke all on function public._operations_validate_project_economics()
  from anon;
revoke all on function public._operations_validate_project_economics()
  from authenticated;
revoke all on function public._operations_worklog_defaults()
  from public;
revoke all on function public._operations_worklog_defaults()
  from anon;
revoke all on function public._operations_worklog_defaults()
  from authenticated;
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  v_project_eid:=public._operations_project_enterprise(p_project);
  if v_project_eid is null then raise exception 'project not found'; end if;
  if v_project_eid<>v_eid then raise exception 'project not in enterprise'; end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[]
  ) then
    raise exception 'finance or project management permission required';
  end if;

  perform public._operations_assert_nonnegative(
    v_data,
    array[
      'contract_amount','invoiced_amount','collected_amount',
      'outsourced_committed','outsourced_paid','labor_cost',
      'estimated_completion_cost','other_cost'
    ]::text[]
  );

  insert into public.project_economics as pe(
    project_id,enterprise_id,contract_amount,invoiced_amount,collected_amount,
    outsourced_committed,outsourced_paid,labor_cost,
    estimated_completion_cost,other_cost,updated_by,updated_at
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
      'labor_cost',v_row.labor_cost,
      'estimated_completion_cost',v_row.estimated_completion_cost
    )
  );

  return to_jsonb(v_row)||jsonb_build_object(
    'projected_completion_cost',v_projected,
    'projected_margin',v_row.contract_amount-v_projected,
    'projected_margin_percent',case when v_row.contract_amount>0
      then round((v_row.contract_amount-v_projected)/v_row.contract_amount*100,2)
      else 0 end,
    'collection_gap',greatest(v_row.contract_amount-v_row.collected_amount,0),
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
  if v_uid<>p_profile and not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','company.manage']::text[]
  ) then
    raise exception 'people management permission required';
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
      'skill',v_row.skill,'level',v_row.level,
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
  v_id uuid:=p_demand;
  v_skill text:=btrim(coalesce(v_data->>'skill',''));
  v_required numeric:=public._operations_number(v_data,'required_hours');
  v_from date:=coalesce(nullif(v_data->>'needed_from','')::date,current_date);
  v_until date:=coalesce(nullif(v_data->>'needed_until','')::date,current_date+28);
  v_project uuid:=nullif(v_data->>'project_id','')::uuid;
  v_owner uuid:=nullif(v_data->>'owner_profile_id','')::uuid;
  v_row public.capacity_demands%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_permission(
    v_eid,v_uid,array['projects.manage','people.manage','company.manage']::text[]
  ) then
    raise exception 'project or people management permission required';
  end if;
  if v_skill='' then raise exception 'skill required'; end if;
  if v_required<=0 then raise exception 'required_hours must be positive'; end if;
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
      'required_hours',v_row.required_hours,
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
  if v_uid<>v_worklog.employee_id and v_uid<>v_worklog.boss_id
     and not public._operations_has_permission(
       v_eid,v_uid,array['worklogs.approve','people.manage']::text[]
     ) then
    raise exception 'worklog permission required';
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
    raise exception 'performance review permission required';
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
  if jsonb_typeof(v_evidence) not in ('array','object') then
    raise exception 'evidence must be an array or object';
  end if;
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
    evidence,status,score,created_at,updated_at
  ) values(
    v_eid,p_profile,v_period,v_on_time,v_first_pass,v_rework,
    v_collaboration,v_complexity,v_contribution,v_evidence,'draft',0,now(),now()
  )
  on conflict (enterprise_id,profile_id,period) do update set
    on_time_rate=excluded.on_time_rate,
    first_pass_rate=excluded.first_pass_rate,
    rework_rate=excluded.rework_rate,
    collaboration_score=excluded.collaboration_score,
    complexity_score=excluded.complexity_score,
    business_contribution=excluded.business_contribution,
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
      'status',v_row.status,'evidence',v_row.evidence
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
              e.rework_rate,e.collaboration_score)
          end
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
    raise exception 'performance evidence belongs to another member';
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
      v_row.rework_rate,v_row.collaboration_score)
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
    raise exception 'performance review permission required';
  end if;
  if v_row.profile_id=v_uid then
    raise exception 'self-review is not allowed';
  end if;
  if v_note='' then raise exception 'review note required'; end if;
  if v_row.status='reviewed' then
    return to_jsonb(v_row)||jsonb_build_object('duplicate',true);
  end if;

  v_score:=public._operations_performance_score(
    v_row.on_time_rate,v_row.first_pass_rate,
    v_row.rework_rate,v_row.collaboration_score
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
      'score',v_score,'note',v_note
    )
  );
  return to_jsonb(v_row)||jsonb_build_object('duplicate',false);
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_management(v_eid,v_uid) then
    raise exception 'management permission required';
  end if;
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'management_only',true,
    'window_weeks',v_weeks,
    'period_start',v_start,
    'period_end',v_end,
    'projects',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_id',x.project_id,
        'name',x.name,
        'owner',x.owner,
        'status',x.status,
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
        'unpaid_invoice',greatest(x.invoiced_amount-x.collected_amount,0)
      ) order by x.name),'[]'::jsonb)
      from (
        select p.id project_id,p.name,p.owner,p.status,
          coalesce(pe.contract_amount,0) contract_amount,
          coalesce(pe.invoiced_amount,0) invoiced_amount,
          coalesce(pe.collected_amount,0) collected_amount,
          coalesce(pe.outsourced_committed,0) outsourced_committed,
          coalesce(pe.outsourced_paid,0) outsourced_paid,
          coalesce(pe.labor_cost,0) labor_cost,
          coalesce(pe.other_cost,0) other_cost,
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
      ) x
    ),
    'capacity_gaps',(
      with demand as (
        select d.skill,sum(d.required_hours) required_hours
        from public.capacity_demands d
        where d.enterprise_id=v_eid
          and d.needed_from<=v_end and d.needed_until>=v_start
        group by d.skill
      ),
      availability as (
        select ps.skill,
          sum(
            coalesce(ps.available_hours,0)
            * greatest(
                0,
                least(v_end,coalesce(ps.valid_until,v_end))
                -greatest(v_start,current_date)+1
              )/7.0
          ) available_hours
        from public.profile_skills ps
        join public.enterprise_members m
          on m.enterprise_id=ps.enterprise_id
         and m.profile_id=ps.profile_id
         and m.status='active'
        where ps.enterprise_id=v_eid
          and (ps.valid_until is null or ps.valid_until>=v_start)
        group by ps.skill
      ),
      skills as (
        select skill from demand
        union
        select skill from availability
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'skill',s.skill,
        'required_hours',coalesce(d.required_hours,0),
        'available_hours',round(coalesce(a.available_hours,0),2),
        'gap_hours',greatest(
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0
        ),
        'period_start',v_start,
        'period_end',v_end,
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
      select coalesce(jsonb_agg(
        to_jsonb(e)||jsonb_build_object(
          'name',p.name,
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,
              e.rework_rate,e.collaboration_score) end
        ) order by p.name,e.period desc
      ),'[]'::jsonb)
      from public.performance_evidence e
      join public.profiles p on p.id=e.profile_id
      where e.enterprise_id=v_eid
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
        where w.boss_id=v_owner
          and w.work_date between v_start and v_end
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
            select work_kind,sum(hours) hours
            from entries
            group by work_kind
          ) k
        ),'{}'::jsonb)
      )
      from entries
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
grant execute on function public.worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.upsert_performance_evidence(uuid,text,jsonb) to authenticated;
grant execute on function public.get_my_performance_evidence() to authenticated;
grant execute on function public.submit_performance_statement(uuid,text) to authenticated;
grant execute on function public.review_performance_evidence(uuid,text) to authenticated;
grant execute on function public.get_operations_dashboard(integer) to authenticated;
