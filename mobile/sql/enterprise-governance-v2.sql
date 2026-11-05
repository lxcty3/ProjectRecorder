-- ============================================================
-- Project Recorder - Enterprise governance v2
--
-- Run this file after enterprise-identity.sql and community.sql.
-- This migration adds versioned role templates and multi-role
-- assignments. Template writes remain unavailable through direct
-- REST access; clients use SECURITY DEFINER RPCs.
--
-- Later phase-one tasks extend the same file with:
--   enterprise_role_motions.motion_class and share_snapshot,
--   enterprise_board_motions and board voting,
--   enterprise_point_pools and enterprise_point_ledger,
--   unlock_knowledge_content(), and points_are_permanent.
-- ============================================================

-- ------------------------------------------------------------ member mode
alter table public.enterprise_members
  add column if not exists preferred_mode text not null default 'simple';

do $do$
begin
  if not exists (
    select 1
      from pg_constraint c
     where c.conrelid='public.enterprise_members'::regclass
       and c.contype='c'
       and pg_get_constraintdef(c.oid) like '%preferred_mode%'
  ) then
    alter table public.enterprise_members
      add constraint enterprise_members_preferred_mode_check
      check (preferred_mode in ('simple','advanced'));
  end if;
end;
$do$;

-- ------------------------------------------------------------ identity administration
-- This system catalog role makes the dedicated template-management
-- capability reachable without granting any high-risk write permission.
insert into public.enterprise_role_catalog(key,name,description,permissions,rank)
values
('identity_admin','Identity Administrator','Manages enterprise role templates within granted limits','["identity.manage_templates","identity.view","people.view_all"]',60)
on conflict (key) do update set
  name=excluded.name,
  description=excluded.description,
  permissions=excluded.permissions,
  rank=excluded.rank;

-- The legacy enterprise_members.role_key path must enforce the same
-- identity-admin singleton invariant as role assignments.
create unique index if not exists enterprise_single_identity_admin_member_idx
  on public.enterprise_members(enterprise_id)
  where role_key='identity_admin' and status='active';

-- ------------------------------------------------------------ role templates
create table if not exists public.enterprise_role_templates (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  key text not null,
  name text not null,
  office_key text not null default '',
  is_system boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (enterprise_id, key)
);

create table if not exists public.enterprise_role_template_versions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.enterprise_role_templates(id) on delete cascade,
  version integer not null check (version > 0),
  status text not null default 'active' check (status in ('active','retired')),
  created_by uuid references public.profiles(id) on delete set null,
  effective_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (template_id, version)
);

create unique index if not exists enterprise_active_template_version_idx
  on public.enterprise_role_template_versions(template_id)
  where status='active';

create table if not exists public.enterprise_role_template_permissions (
  template_version_id uuid not null
    references public.enterprise_role_template_versions(id) on delete cascade,
  permission_key text not null,
  resource text not null,
  action text not null,
  scope text not null default 'self'
    check (scope in ('self','team','department','company','project')),
  conditions jsonb not null default '{}'::jsonb,
  high_risk boolean not null default false,
  primary key (template_version_id, permission_key)
);

create table if not exists public.enterprise_role_assignments (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  template_version_id uuid not null
    references public.enterprise_role_template_versions(id) on delete restrict,
  office_key text not null default '',
  is_primary boolean not null default false,
  status text not null default 'active'
    check (status in ('active','expired','revoked')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  appointed_by uuid references public.profiles(id) on delete set null,
  source_motion_id uuid,
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);

do $do$
begin
  if not exists (
    select 1
      from pg_constraint
     where conrelid='public.enterprise_role_assignments'::regclass
       and conname='enterprise_assignment_primary_or_ends_check'
  ) then
    alter table public.enterprise_role_assignments
      add constraint enterprise_assignment_primary_or_ends_check
      check (
        is_primary or ends_at is not null
      );
  end if;
end;
$do$;

create or replace function public._enterprise_role_assignment_same_tenant()
returns trigger
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_enterprise_id uuid;
begin
  select t.enterprise_id into v_enterprise_id
    from public.enterprise_role_template_versions v
    join public.enterprise_role_templates t on t.id=v.template_id
   where v.id=new.template_version_id;

  if v_enterprise_id is null then
    raise exception 'role template version not found';
  end if;
  if v_enterprise_id<>new.enterprise_id then
    raise exception 'role assignment template must belong to the same enterprise';
  end if;
  return new;
end;
$fn$;

drop trigger if exists enterprise_role_assignment_same_tenant
  on public.enterprise_role_assignments;
create trigger enterprise_role_assignment_same_tenant
before insert or update of enterprise_id, template_version_id
on public.enterprise_role_assignments
for each row execute function public._enterprise_role_assignment_same_tenant();

create unique index if not exists enterprise_primary_role_idx
  on public.enterprise_role_assignments(enterprise_id, profile_id)
  where status='active' and is_primary;

create unique index if not exists enterprise_single_office_idx
  on public.enterprise_role_assignments(enterprise_id, office_key)
  where status='active' and office_key in ('chairperson','identity_admin');

create index if not exists enterprise_role_assignment_profile_idx
  on public.enterprise_role_assignments(enterprise_id, profile_id, status);

alter table public.enterprise_role_templates enable row level security;
alter table public.enterprise_role_template_versions enable row level security;
alter table public.enterprise_role_template_permissions enable row level security;
alter table public.enterprise_role_assignments enable row level security;

-- Direct table access is denied. SECURITY DEFINER RPCs are the only
-- supported read/write path for governance data.
revoke all on table public.enterprise_role_templates from anon, authenticated;
revoke all on table public.enterprise_role_template_versions from anon, authenticated;
revoke all on table public.enterprise_role_template_permissions from anon, authenticated;
revoke all on table public.enterprise_role_assignments from anon, authenticated;

-- ------------------------------------------------------------ provisioning
create or replace function public.provision_default_role_templates(p_enterprise uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_role record;
  v_template_id uuid;
  v_version_id uuid;
  v_created_templates integer:=0;
  v_created_permissions integer:=0;
  v_batch_permissions integer:=0;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if not exists (
    select 1 from public.enterprises e where e.id=p_enterprise
  ) then
    raise exception 'enterprise not found';
  end if;
  if not public._identity_is_member(p_enterprise,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  for v_role in
    select c.key,c.name,c.permissions,c.rank
      from public.enterprise_role_catalog c
     order by c.rank desc,c.key
  loop
    insert into public.enterprise_role_templates(
      enterprise_id,key,name,office_key,is_system
    ) values(
      p_enterprise,
      v_role.key,
      v_role.name,
      case
        when v_role.key in (
          'chairperson','director','supervisor','ceo','finance','identity_admin'
        ) then v_role.key
        else ''
      end,
      true
    )
    on conflict (enterprise_id,key) do nothing;

    select t.id into v_template_id
      from public.enterprise_role_templates t
     where t.enterprise_id=p_enterprise and t.key=v_role.key;

    select v.id into v_version_id
      from public.enterprise_role_template_versions v
     where v.template_id=v_template_id and v.version=1;

    if v_version_id is null then
      insert into public.enterprise_role_template_versions(
        template_id,version,status,created_by,effective_at
      ) values(
        v_template_id,1,'active',null,now()
      )
      on conflict (template_id,version) do nothing
      returning id into v_version_id;

      if v_version_id is not null then
        v_created_templates:=v_created_templates+1;
        insert into public.enterprise_role_template_permissions(
          template_version_id,
          permission_key,
          resource,
          action,
          scope,
          conditions,
          high_risk
        )
        select
          v_version_id,
          btrim(p.value),
          split_part(btrim(p.value),'.',1),
          case
            when strpos(btrim(p.value),'.')>0
              then substr(btrim(p.value),strpos(btrim(p.value),'.')+1)
            else btrim(p.value)
          end,
          case
            when right(btrim(p.value),4)='_all' then 'company'
            when split_part(btrim(p.value),'.',1) in (
              'company','finance','reports','audit','identity'
            ) then 'company'
            when split_part(btrim(p.value),'.',1) in ('projects','tasks')
              then 'project'
            when split_part(btrim(p.value),'.',1) in (
              'people','worklogs','leave','rewards'
            ) then 'department'
            else 'self'
          end,
          '{}'::jsonb,
          btrim(p.value) in (
            'identity.manage_templates',
            'identity.manage_shares',
            'governance.vote',
            'governance.manage',
            'finance.manage',
            'finance.approve_company',
            'data.export_all',
            'data.delete_all',
            'company.delete'
          )
        from jsonb_array_elements_text(
          case
            when jsonb_typeof(v_role.permissions)='array' then v_role.permissions
            else '[]'::jsonb
          end
        ) as p(value)
        where btrim(p.value)<>''
        on conflict (template_version_id,permission_key) do nothing;

        get diagnostics v_batch_permissions=row_count;
        v_created_permissions:=v_created_permissions+v_batch_permissions;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok',true,
    'enterprise_id',p_enterprise,
    'created_templates',v_created_templates,
    'created_permissions',v_created_permissions
  );
end;
$fn$;

create or replace function public.get_enterprise_role_templates()
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_enterprise_id uuid;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  v_enterprise_id:=public._identity_bootstrap(
    public._identity_owner_for_uid(v_uid)
  );
  if not public._identity_is_member(v_enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  if coalesce((
    select count(*)
      from public.enterprise_role_templates t
     where t.enterprise_id=v_enterprise_id
       and t.is_system
       and t.archived_at is null
  ),0) < (
    select count(*) from public.enterprise_role_catalog
  ) then
    perform public.provision_default_role_templates(v_enterprise_id);
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',t.id,
        'enterprise_id',t.enterprise_id,
        'key',t.key,
        'name',t.name,
        'office_key',t.office_key,
        'is_system',t.is_system,
        'archived_at',t.archived_at,
        'created_at',t.created_at,
        'current_version',v.version,
        'version_id',v.id,
        'version_status',v.status,
        'effective_at',v.effective_at,
        'permissions',coalesce((
          select jsonb_agg(p.permission_key order by p.permission_key)
            from public.enterprise_role_template_permissions p
           where p.template_version_id=v.id
        ),'[]'::jsonb),
        'permission_details',coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'permission_key',p.permission_key,
              'resource',p.resource,
              'action',p.action,
              'scope',p.scope,
              'conditions',p.conditions,
              'high_risk',p.high_risk
            ) order by p.permission_key
          )
            from public.enterprise_role_template_permissions p
           where p.template_version_id=v.id
        ),'[]'::jsonb)
      )
      order by t.is_system desc,t.name,t.key
    ),
    '[]'::jsonb
  ) into v_result
  from public.enterprise_role_templates t
  left join lateral (
    select tv.id,tv.version,tv.status,tv.effective_at
      from public.enterprise_role_template_versions tv
     where tv.template_id=t.id and tv.status='active'
     order by tv.version desc
     limit 1
  ) v on true
  where t.enterprise_id=v_enterprise_id
    and t.archived_at is null;

  return v_result;
end;
$fn$;

revoke all on function public.provision_default_role_templates(uuid) from public;
revoke all on function public.provision_default_role_templates(uuid) from anon;
revoke all on function public.provision_default_role_templates(uuid) from authenticated;
revoke all on function public._enterprise_role_assignment_same_tenant() from public;
revoke all on function public._enterprise_role_assignment_same_tenant() from anon;
revoke all on function public._enterprise_role_assignment_same_tenant() from authenticated;

revoke all on function public.get_enterprise_role_templates() from public;
revoke all on function public.get_enterprise_role_templates() from anon;
grant execute on function public.get_enterprise_role_templates() to authenticated;

-- ------------------------------------------------------------ assignment-aware permissions
-- Effective permission grants retain all dimensions required by the
-- permission ceiling. Assignments are ignored unless the profile is still
-- an active enterprise member and the grant is time-valid.
create or replace function public._identity_role_permission_grants(
  p_eid uuid,
  p_uid uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grants jsonb:='[]'::jsonb;
  v_owner uuid;
begin
  if not exists (
    select 1
      from public.enterprise_members em
     where em.enterprise_id=p_eid
       and em.profile_id=p_uid
       and em.status='active'
  ) then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(distinct jsonb_build_object(
    'permission_key',btrim(permission.value),
    'resource',split_part(btrim(permission.value),'.',1),
    'action',case
      when strpos(btrim(permission.value),'.')>0
        then substr(btrim(permission.value),strpos(btrim(permission.value),'.')+1)
      else btrim(permission.value)
    end,
    'scope',case
      when right(btrim(permission.value),4)='_all' then 'company'
      when split_part(btrim(permission.value),'.',1) in (
        'company','finance','reports','audit','identity'
      ) then 'company'
      when split_part(btrim(permission.value),'.',1) in ('projects','tasks')
        then 'project'
      when split_part(btrim(permission.value),'.',1) in (
        'people','worklogs','leave','rewards'
      ) then 'department'
      else 'self'
    end,
    'conditions','{}'::jsonb,
    'high_risk',btrim(permission.value) in (
      'identity.manage_templates',
      'identity.manage_shares',
      'governance.vote',
      'governance.manage',
      'finance.manage',
      'finance.approve_company',
      'data.export_all',
      'data.delete_all',
      'company.delete'
    )
  )),'[]'::jsonb)
  into v_grants
  from public.enterprise_members em
  join public.enterprise_role_catalog r on r.key=em.role_key
  cross join lateral jsonb_array_elements_text(
    case
      when jsonb_typeof(r.permissions)='array' then r.permissions
      else '[]'::jsonb
    end
  ) permission(value)
  where em.enterprise_id=p_eid
    and em.profile_id=p_uid
    and em.status='active'
    and btrim(permission.value)<>'';

  v_grants:=v_grants||coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'permission_key',p.permission_key,
      'resource',p.resource,
      'action',p.action,
      'scope',p.scope,
      'conditions',p.conditions,
      'high_risk',p.high_risk
    ))
      from public.enterprise_role_assignments a
      join public.enterprise_members em
        on em.enterprise_id=a.enterprise_id
       and em.profile_id=a.profile_id
       and em.status='active'
      join public.enterprise_role_template_versions av
        on av.id=a.template_version_id
      join public.enterprise_role_templates t
        on t.id=av.template_id
      join public.enterprise_role_template_versions tv
        on tv.template_id=t.id and tv.status='active'
      join public.enterprise_role_template_permissions p
        on p.template_version_id=tv.id
     where a.enterprise_id=p_eid
       and a.profile_id=p_uid
       and a.status='active'
       and a.starts_at <= now()
       and (a.ends_at is null or a.ends_at > now())
       and t.enterprise_id=p_eid
       and t.archived_at is null
  ),'[]'::jsonb);

  if public._identity_shares(p_eid,p_uid)>0 then
    v_grants:=v_grants||jsonb_build_array(
      jsonb_build_object(
        'permission_key','identity.propose',
        'resource','identity',
        'action','propose',
        'scope','company',
        'conditions','{}'::jsonb,
        'high_risk',false
      ),
      jsonb_build_object(
        'permission_key','identity.vote',
        'resource','identity',
        'action','vote',
        'scope','company',
        'conditions','{}'::jsonb,
        'high_risk',false
      )
    );
  end if;

  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  if v_owner=p_uid then
    v_grants:=v_grants||jsonb_build_array(jsonb_build_object(
      'permission_key','identity.manage_shares',
      'resource','identity',
      'action','manage_shares',
      'scope','company',
      'conditions','{}'::jsonb,
      'high_risk',true
    ));
  end if;

  return (
    select coalesce(jsonb_agg(distinct value),'[]'::jsonb)
      from jsonb_array_elements(v_grants) value
  );
end;
$fn$;

create or replace function public._identity_role_permissions(p_eid uuid,p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(jsonb_agg(distinct value->>'permission_key'),'[]'::jsonb)
    from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    ) value;
$fn$;

create or replace function public._identity_permissions_are_grantable(
  p_eid uuid,
  p_uid uuid,
  p_requested jsonb
)
returns boolean
language plpgsql
stable
security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if jsonb_typeof(p_requested) is distinct from 'array' then
    return false;
  end if;

  return not exists (
    select 1
      from jsonb_array_elements(p_requested) requested(value)
     where not exists (
       select 1
         from jsonb_array_elements(
           public._identity_role_permission_grants(p_eid,p_uid)
         ) held(value)
        where held.value->>'permission_key'=requested.value->>'permission_key'
          and held.value->>'resource'=requested.value->>'resource'
          and held.value->>'action'=requested.value->>'action'
          and held.value->>'scope'=requested.value->>'scope'
          and coalesce(held.value->'conditions','{}'::jsonb)=coalesce(requested.value->'conditions','{}'::jsonb)
          and coalesce((held.value->>'high_risk')::boolean,false)=coalesce((requested.value->>'high_risk')::boolean,false)
     )
  );
end;
$fn$;
-- ------------------------------------------------------------ template writes
drop function if exists public.clone_role_template(uuid,text,text);

create or replace function public.clone_role_template(
  p_source_template uuid,
  p_name text,
  p_key text,
  p_reason text default '',
  p_days integer default 5,
  p_conflict_disclosed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_source public.enterprise_role_templates%rowtype;
  v_source_version_id uuid;
  v_template_id uuid;
  v_version_id uuid;
  v_name text:=btrim(coalesce(p_name,''));
  v_key text:=btrim(coalesce(p_key,''));
  v_permissions jsonb:='[]'::jsonb;
  v_reason text:=btrim(coalesce(p_reason,''));
  v_motion uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;

  if v_name='' then raise exception 'template name required'; end if;
  if v_key='' then raise exception 'template key required'; end if;
  if v_reason='' then raise exception 'template change reason is required'; end if;

  select t.* into v_source
    from public.enterprise_role_templates t
   where t.id=p_source_template
     and t.enterprise_id=v_eid
     and t.archived_at is null
   for update;
  if not found then raise exception 'source template not found'; end if;

  select v.id into v_source_version_id
    from public.enterprise_role_template_versions v
   where v.template_id=v_source.id and v.status='active'
   order by v.version desc
   limit 1;
  if v_source_version_id is null then
    raise exception 'source template has no active version';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'permission_key',p.permission_key,
    'resource',p.resource,
    'action',p.action,
    'scope',p.scope,
    'conditions',p.conditions,
    'high_risk',p.high_risk
  ) order by p.permission_key),'[]'::jsonb)
  into v_permissions
  from public.enterprise_role_template_permissions p
  where p.template_version_id=v_source_version_id;

  if not public._identity_permissions_are_grantable(v_eid,v_uid,v_permissions) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_permissions) requested(value)
     where coalesce((requested.value->>'high_risk')::boolean,false)
  ) then
    v_motion:=public._identity_create_shareholder_motion(
      v_eid,v_uid,'template_change',null,null,'','',
      v_reason,
      jsonb_build_object(
        'operation','clone',
        'source_template_id',p_source_template,
        'template_key',v_key,
        'name',v_name,
        'permissions',v_permissions,
        'reason',v_reason
      ),
      'major',coalesce(p_days,5),coalesce(p_conflict_disclosed,false)
    );
    return jsonb_build_object(
      'ok',true,'motion_required',true,'motion_id',v_motion,
      'motion_class','major','required_bps',6667,'status','open'
    );
  end if;

  if exists (
    select 1
      from public.enterprise_role_templates t
     where t.enterprise_id=v_eid and t.key=v_key
  ) then
    raise exception 'template key already exists';
  end if;

  insert into public.enterprise_role_templates(
    enterprise_id,key,name,office_key,is_system
  ) values(
    v_eid,v_key,v_name,'',false
  )
  returning id into v_template_id;

  insert into public.enterprise_role_template_versions(
    template_id,version,status,created_by,effective_at
  ) values(
    v_template_id,1,'active',v_uid,now()
  )
  returning id into v_version_id;

  insert into public.enterprise_role_template_permissions(
    template_version_id,
    permission_key,
    resource,
    action,
    scope,
    conditions,
    high_risk
  )
  select
    v_version_id,
    p.permission_key,
    p.resource,
    p.action,
    p.scope,
    p.conditions,
    p.high_risk
  from public.enterprise_role_template_permissions p
  where p.template_version_id=v_source_version_id;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'role_template.cloned',null,
    jsonb_build_object(
      'source_template_id',p_source_template,
      'source_version_id',v_source_version_id,
      'template_id',v_template_id,
      'key',v_key,
      'name',v_name,
      'version',1,
      'reason',v_reason,
      'conflict_disclosed',coalesce(p_conflict_disclosed,false),
      'permission_count',jsonb_array_length(v_permissions)
    )
  );

  return jsonb_build_object(
    'ok',true,
    'template_id',v_template_id,
    'key',v_key,
    'name',v_name,
    'version_id',v_version_id,
    'version',1
  );
end;
$fn$;

drop function if exists public.update_role_template(uuid,text,jsonb);

create or replace function public.update_role_template(
  p_template uuid,
  p_name text,
  p_permissions jsonb,
  p_reason text default '',
  p_days integer default 5,
  p_conflict_disclosed boolean default false
) returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_template public.enterprise_role_templates%rowtype;
  v_current_version public.enterprise_role_template_versions%rowtype;
  v_new_version_id uuid;
  v_new_version integer;
  v_name text:=btrim(coalesce(p_name,''));
  v_item jsonb;
  v_key text;
  v_resource text;
  v_action text;
  v_scope text;
  v_conditions jsonb;
  v_permission_high_risk boolean;
  v_permissions jsonb:='[]'::jsonb;
  v_high_risk boolean:=false;
  v_reason text:=btrim(coalesce(p_reason,''));
  v_motion uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_reason='' then raise exception 'template change reason is required'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;

  select t.* into v_template
    from public.enterprise_role_templates t
   where t.id=p_template
     and t.enterprise_id=v_eid
     and t.archived_at is null
   for update;
  if not found then raise exception 'role template not found'; end if;

  select v.* into v_current_version
    from public.enterprise_role_template_versions v
   where v.template_id=p_template and v.status='active'
   order by v.version desc
   limit 1
   for update;
  if not found then raise exception 'role template has no active version'; end if;

  if exists (
    select 1
      from public.enterprise_role_template_permissions p
     where p.template_version_id=v_current_version.id
       and p.high_risk
  ) then
    v_high_risk:=true;
  end if;

  if exists (
    select 1
      from public.enterprise_role_assignments a
      join public.enterprise_role_template_versions v
        on v.id=a.template_version_id
     where a.profile_id=auth.uid()
       and a.status='active'
       and v.template_id=p_template
  ) then
    raise exception 'cannot edit your own role';
  end if;

  if exists (
    select 1
      from public.enterprise_members m
     where m.enterprise_id=v_eid
       and m.profile_id=v_uid
       and m.status='active'
       and m.role_key=v_template.key
  ) then
    raise exception 'cannot edit your own role';
  end if;

  if v_name='' then raise exception 'template name required'; end if;
  if p_permissions is null or jsonb_typeof(p_permissions)<>'array' then
    raise exception 'permissions must be an array';
  end if;

  for v_item in select value from jsonb_array_elements(p_permissions) loop
    if jsonb_typeof(v_item)='string' then
      v_key:=btrim(v_item#>>'{}');
      v_resource:=split_part(v_key,'.',1);
      v_action:=case
        when strpos(v_key,'.')>0 then substr(v_key,strpos(v_key,'.')+1)
        else v_key
      end;
      v_conditions:='{}'::jsonb;
      v_scope:=case
        when right(v_key,4)='_all' then 'company'
        when split_part(v_key,'.',1) in (
          'company','finance','reports','audit','identity'
        ) then 'company'
        when split_part(v_key,'.',1) in ('projects','tasks') then 'project'
        when split_part(v_key,'.',1) in (
          'people','worklogs','leave','rewards'
        ) then 'department'
        else 'self'
      end;
      v_permission_high_risk:=v_key in (
        'identity.manage_templates',
        'identity.manage_shares',
        'governance.vote',
        'governance.manage',
        'finance.manage',
        'finance.approve_company',
        'data.export_all',
        'data.delete_all',
        'company.delete'
      );
    elsif jsonb_typeof(v_item)='object' then
      v_key:=btrim(coalesce(v_item->>'permission_key',v_item->>'key',''));
      v_resource:=btrim(coalesce(v_item->>'resource',''));
      v_action:=btrim(coalesce(v_item->>'action',''));
      if v_resource='' then
        v_resource:=split_part(v_key,'.',1);
      end if;
      if v_action='' then
        v_action:=case
          when strpos(v_key,'.')>0 then substr(v_key,strpos(v_key,'.')+1)
          else v_key
        end;
      end if;
      v_scope:=btrim(coalesce(v_item->>'scope',''));
      if v_scope='' then
        v_scope:=case
          when right(v_key,4)='_all' then 'company'
          when split_part(v_key,'.',1) in (
            'company','finance','reports','audit','identity'
          ) then 'company'
          when split_part(v_key,'.',1) in ('projects','tasks') then 'project'
          when split_part(v_key,'.',1) in (
            'people','worklogs','leave','rewards'
          ) then 'department'
          else 'self'
        end;
      end if;
      if v_item ? 'conditions'
         and jsonb_typeof(v_item->'conditions')<>'object' then
        raise exception 'permission conditions must be an object';
      end if;
      v_conditions:=coalesce(v_item->'conditions','{}'::jsonb);
      v_permission_high_risk:=coalesce((v_item->>'high_risk')::boolean,false)
        or v_key in (
          'identity.manage_templates',
          'identity.manage_shares',
          'governance.vote',
          'governance.manage',
          'finance.manage',
          'finance.approve_company',
          'data.export_all',
          'data.delete_all',
          'company.delete'
        );
    else
      raise exception 'permission entries must be strings or objects';
    end if;

    if v_key='' then raise exception 'permission key required'; end if;
    if v_scope not in ('self','team','department','company','project') then
      raise exception 'invalid permission scope';
    end if;

    v_high_risk:=v_high_risk or v_permission_high_risk;
    v_permissions:=v_permissions||jsonb_build_array(jsonb_build_object(
      'permission_key',v_key,
      'resource',v_resource,
      'action',v_action,
      'scope',v_scope,
      'conditions',v_conditions,
      'high_risk',v_permission_high_risk
    ));
  end loop;

  if not public._identity_permissions_are_grantable(v_eid,v_uid,v_permissions) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  if v_high_risk then
    v_motion:=public._identity_create_shareholder_motion(
      v_eid,v_uid,'template_change',null,null,'','',
      v_reason,
      jsonb_build_object(
        'operation','update',
        'template_id',v_template.id,
        'template_key',v_template.key,
        'name',v_name,
        'permissions',v_permissions,
        'reason',v_reason
      ),
      'major',coalesce(p_days,5),coalesce(p_conflict_disclosed,false)
    );
    return jsonb_build_object(
      'ok',true,'motion_required',true,'motion_id',v_motion,
      'motion_class','major','required_bps',6667,'status','open'
    );
  end if;

  update public.enterprise_role_template_versions
     set status='retired'
   where id=v_current_version.id;

  v_new_version:=v_current_version.version+1;
  insert into public.enterprise_role_template_versions(
    template_id,version,status,created_by,effective_at
  ) values(
    p_template,v_new_version,'active',v_uid,now()
  )
  returning id into v_new_version_id;

  insert into public.enterprise_role_template_permissions(
    template_version_id,
    permission_key,
    resource,
    action,
    scope,
    conditions,
    high_risk
  )
  select
    v_new_version_id,
    requested.value->>'permission_key',
    requested.value->>'resource',
    requested.value->>'action',
    requested.value->>'scope',
    coalesce(requested.value->'conditions','{}'::jsonb),
    coalesce((requested.value->>'high_risk')::boolean,false)
  from jsonb_array_elements(v_permissions) requested(value)
  on conflict (template_version_id,permission_key) do update set
    resource=excluded.resource,
    action=excluded.action,
    scope=excluded.scope,
    conditions=excluded.conditions,
    high_risk=excluded.high_risk;

  update public.enterprise_role_templates
     set name=v_name
   where id=p_template;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'role_template.updated',null,
    jsonb_build_object(
      'template_id',p_template,
      'previous_version',v_current_version.version,
      'version',v_new_version,
      'version_id',v_new_version_id,
      'name',v_name,
      'permission_count',jsonb_array_length(v_permissions)
    )
  );

  return jsonb_build_object(
    'ok',true,
    'template_id',p_template,
    'name',v_name,
    'version_id',v_new_version_id,
    'version',v_new_version
  );
end;
$fn$;

-- ------------------------------------------------------------ secondary assignments
drop function if exists public.set_member_role_assignment(uuid,uuid,timestamptz);

create or replace function public.set_member_role_assignment(
  p_profile uuid,
  p_template uuid,
  p_ends_at timestamptz,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_template_id uuid;
  v_template_version_id uuid;
  v_office_key text;
  v_assignment_id uuid;
  v_template_permissions jsonb:='[]'::jsonb;
  v_high_risk boolean:=false;
  v_governance_sensitive boolean:=false;
  v_reason text:=btrim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));

  perform 1
    from public.enterprises
   where id=v_eid
   for update;

  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;

  if p_profile=auth.uid() then
    raise exception 'cannot assign a role to yourself';
  end if;
  if p_ends_at is null then
    raise exception 'secondary assignments must expire';
  end if;
  if p_ends_at<=now() then
    raise exception 'assignment end must be in the future';
  end if;

  if not exists (
    select 1
      from public.enterprise_members m
     where m.enterprise_id=v_eid
       and m.profile_id=p_profile
       and m.status='active'
  ) then
    raise exception 'profile is not an active enterprise member';
  end if;

  select t.id,t.office_key
    into v_template_id,v_office_key
    from public.enterprise_role_templates t
   where t.id=p_template
     and t.enterprise_id=v_eid
     and t.archived_at is null
   for update;
  if not found then
    raise exception 'role template not found';
  end if;

  select v.id into v_template_version_id
    from public.enterprise_role_template_versions v
   where v.template_id=v_template_id and v.status='active'
   order by v.version desc
   limit 1
   for share;
  if v_template_version_id is null then
    raise exception 'role template has no active version';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'permission_key',p.permission_key,
    'resource',p.resource,
    'action',p.action,
    'scope',p.scope,
    'conditions',p.conditions,
    'high_risk',p.high_risk
  ) order by p.permission_key),'[]'::jsonb)
  into v_template_permissions
  from public.enterprise_role_template_permissions p
  where p.template_version_id=v_template_version_id;

  select exists (
    select 1
      from public.enterprise_role_template_permissions p
     where p.template_version_id=v_template_version_id
       and p.high_risk
  ) into v_high_risk;

  v_governance_sensitive:=v_office_key<>'' or v_high_risk;

  -- Ordinary, non-governance assignments remain available while votes are open.
  -- Only an assigned office or high-risk permission set freezes composition.
  if v_governance_sensitive and (
    exists (
      select 1
        from public.enterprise_role_motions
       where enterprise_id=v_eid
         and status='open'
    )
    or exists (
      select 1
        from public.enterprise_board_motions
       where enterprise_id=v_eid
         and status='open'
    )
  ) then
    raise exception 'cannot change voting-sensitive composition while a motion is open';
  end if;

  if v_high_risk then
    raise exception 'template contains high-risk permissions';
  end if;

  if not public._identity_permissions_are_grantable(
    v_eid,v_uid,v_template_permissions
  ) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  select a.id into v_assignment_id
    from public.enterprise_role_assignments a
    join public.enterprise_role_template_versions av
      on av.id=a.template_version_id
   where a.enterprise_id=v_eid
     and a.profile_id=p_profile
     and av.template_id=v_template_id
     and a.status='active'
     and a.is_primary=false
   order by a.created_at desc
   limit 1
   for update of a;

  if v_assignment_id is null then
    insert into public.enterprise_role_assignments(
      enterprise_id,
      profile_id,
      template_version_id,
      office_key,
      is_primary,
      status,
      starts_at,
      ends_at,
      appointed_by
    ) values(
      v_eid,
      p_profile,
      v_template_version_id,
      v_office_key,
      false,
      'active',
      now(),
      p_ends_at,
      v_uid
    )
    returning id into v_assignment_id;
  else
    update public.enterprise_role_assignments
       set template_version_id=v_template_version_id,
           office_key=v_office_key,
           is_primary=false,
           status='active',
           starts_at=now(),
           ends_at=p_ends_at,
           appointed_by=v_uid
     where id=v_assignment_id;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'role_assignment.set',p_profile,
    jsonb_build_object(
      'assignment_id',v_assignment_id,
      'template_id',v_template_id,
      'template_version_id',v_template_version_id,
      'office_key',v_office_key,
      'starts_at',now(),
      'ends_at',p_ends_at,
      'reason',v_reason
    )
  );

  return jsonb_build_object(
    'ok',true,
    'assignment_id',v_assignment_id,
    'enterprise_id',v_eid,
    'profile_id',p_profile,
    'template_id',v_template_id,
    'template_version_id',v_template_version_id,
    'office_key',v_office_key,
    'ends_at',p_ends_at,
    'reason',v_reason
  );
end;
$fn$;

create or replace function public.expire_role_assignments()
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_expired integer:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;

  update public.enterprise_role_assignments
     set status='expired'
   where enterprise_id=v_eid
     and status='active'
     and ends_at is not null
     and ends_at <= now();

  get diagnostics v_expired=row_count;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'role_assignments.expired',null,
    jsonb_build_object('expired_count',v_expired)
  );

  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'expired_count',v_expired
  );
end;
$fn$;

-- ------------------------------------------------------------ template RPC grants
revoke all on function public._identity_role_permission_grants(uuid,uuid) from public;
revoke all on function public._identity_role_permission_grants(uuid,uuid) from anon;
revoke all on function public._identity_role_permission_grants(uuid,uuid) from authenticated;

revoke all on function public._identity_permissions_are_grantable(uuid,uuid,jsonb) from public;
revoke all on function public._identity_permissions_are_grantable(uuid,uuid,jsonb) from anon;
revoke all on function public._identity_permissions_are_grantable(uuid,uuid,jsonb) from authenticated;

revoke all on function public._identity_role_permissions(uuid,uuid) from public;
revoke all on function public._identity_role_permissions(uuid,uuid) from anon;
revoke all on function public._identity_role_permissions(uuid,uuid) from authenticated;

revoke all on function public.clone_role_template(uuid,text,text,text,integer,boolean) from public;
revoke all on function public.clone_role_template(uuid,text,text,text,integer,boolean) from anon;
revoke all on function public.clone_role_template(uuid,text,text,text,integer,boolean) from authenticated;
grant execute on function public.clone_role_template(uuid,text,text,text,integer,boolean) to authenticated;

revoke all on function public.update_role_template(uuid,text,jsonb,text,integer,boolean) from public;
revoke all on function public.update_role_template(uuid,text,jsonb,text,integer,boolean) from anon;
revoke all on function public.update_role_template(uuid,text,jsonb,text,integer,boolean) from authenticated;
grant execute on function public.update_role_template(uuid,text,jsonb,text,integer,boolean) to authenticated;

revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from public;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from anon;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from authenticated;
grant execute on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) to authenticated;

revoke all on function public.expire_role_assignments() from public;
revoke all on function public.expire_role_assignments() from anon;
revoke all on function public.expire_role_assignments() from authenticated;
grant execute on function public.expire_role_assignments() to authenticated;

-- ------------------------------------------------------------ shareholder motion snapshots
alter table public.enterprise_role_motions
  add column if not exists motion_class text not null default 'ordinary'
    check (motion_class in ('ordinary','major')),
  add column if not exists share_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists required_bps integer not null default 5001
    check (required_bps between 1 and 10000),
  add column if not exists conflict_disclosed boolean not null default false;

-- ------------------------------------------------------------ board motions
create table if not exists public.enterprise_board_motions (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  title text not null,
  kind text not null check (kind in ('point_pool','governance','operations')),
  payload jsonb not null default '{}'::jsonb,
  conflict_disclosed boolean not null default false,
  proposer_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'open'
    check (status in ('open','passed','rejected','cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

alter table public.enterprise_board_motions
  add column if not exists conflict_disclosed boolean not null default false;

create table if not exists public.enterprise_board_votes (
  motion_id uuid not null
    references public.enterprise_board_motions(id) on delete cascade,
  director_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  voted_at timestamptz not null default now(),
  primary key (motion_id,director_profile_id)
);

create index if not exists board_vote_idx
  on public.enterprise_board_votes(motion_id,choice);

alter table public.enterprise_board_motions enable row level security;
alter table public.enterprise_board_votes enable row level security;

revoke all on table public.enterprise_board_motions from public;
revoke all on table public.enterprise_board_motions from anon;
revoke all on table public.enterprise_board_motions from authenticated;
revoke all on table public.enterprise_board_votes from public;
revoke all on table public.enterprise_board_votes from anon;
revoke all on table public.enterprise_board_votes from authenticated;

-- ------------------------------------------------------------ point pools and ledger
-- A passed point_pool board motion supplies quarter, total_amount,
-- single_award_limit, and optional carry_from. Pools never refill.
create table if not exists public.enterprise_point_pools (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  quarter text not null,
  total_amount integer not null check(total_amount>0),
  remaining_amount integer not null check(remaining_amount>=0),
  single_award_limit integer not null check(single_award_limit>0),
  status text not null default 'active' check(status in ('active','closed')),
  board_motion_id uuid references public.enterprise_board_motions(id) on delete set null,
  approved_at timestamptz not null default now(),
  carries_to uuid references public.enterprise_point_pools(id) on delete set null,
  unique (enterprise_id,quarter),
  check(remaining_amount<=total_amount),
  check(single_award_limit<=total_amount)
);

create unique index if not exists enterprise_point_pool_motion_idx
  on public.enterprise_point_pools(board_motion_id)
  where board_motion_id is not null;

-- The ledger is append-only through RPCs; no client table grants exist.
create table if not exists public.enterprise_point_ledger (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check(amount<>0),
  entry_type text not null check(entry_type in ('award','unlock','correction')),
  pool_id uuid references public.enterprise_point_pools(id) on delete set null,
  evidence_type text not null default '',
  evidence_id uuid,
  reason text not null default '',
  actor_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check(
    (entry_type='award' and amount>0)
    or (entry_type='unlock' and amount<0)
    or entry_type='correction'
  )
);

create index if not exists enterprise_point_ledger_profile_idx
  on public.enterprise_point_ledger(enterprise_id,profile_id,created_at desc);

create unique index if not exists enterprise_point_award_evidence_idx
  on public.enterprise_point_ledger(
    enterprise_id,profile_id,evidence_type,evidence_id
  )
  where entry_type='award' and evidence_id is not null;

create table if not exists public.enterprise_knowledge_unlocks (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.community_posts(id) on delete cascade,
  cost integer not null check(cost>=0),
  ledger_id uuid not null unique references public.enterprise_point_ledger(id),
  unlocked_at timestamptz not null default now(),
  primary key (profile_id,post_id)
);

alter table public.community_posts
  add column if not exists unlock_cost integer not null default 0 check(unlock_cost>=0),
  add column if not exists is_required boolean not null default false;

-- Stale non-current pools from an earlier deployment remain inactive. The
-- current-quarter pool is never changed by this repair.
update public.enterprise_point_pools
   set status='closed'
 where status='active'
   and quarter<>to_char(now() at time zone 'UTC','YYYY')
     ||'-Q'||to_char(now() at time zone 'UTC','Q');

alter table public.enterprise_point_pools enable row level security;
alter table public.enterprise_point_ledger enable row level security;
alter table public.enterprise_knowledge_unlocks enable row level security;

revoke all on table public.enterprise_point_pools from public;
revoke all on table public.enterprise_point_pools from anon;
revoke all on table public.enterprise_point_pools from authenticated;
revoke all on table public.enterprise_point_ledger from public;
revoke all on table public.enterprise_point_ledger from anon;
revoke all on table public.enterprise_point_ledger from authenticated;
revoke all on table public.enterprise_knowledge_unlocks from public;
revoke all on table public.enterprise_knowledge_unlocks from anon;
revoke all on table public.enterprise_knowledge_unlocks from authenticated;

create or replace function public._identity_can_read_community_post(
  p_post uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select p_uid is not null
    and not (p_uid is distinct from auth.uid())
    and exists(
    select 1
      from public.community_posts p
     where p.id=p_post
       and (
         p.is_required
         or p.unlock_cost=0
         or p.author_id=p_uid
         or exists(
           select 1
             from public.enterprise_knowledge_unlocks u
            where u.profile_id=p_uid
              and u.post_id=p.id
         )
       )
  );
$fn$;

drop policy if exists "community posts readable by members"
  on public.community_posts;
create policy "community posts readable by members"
  on public.community_posts for select to authenticated
  using (public._identity_can_read_community_post(id,auth.uid()));
revoke all on function public._identity_can_read_community_post(uuid,uuid) from public;
revoke all on function public._identity_can_read_community_post(uuid,uuid) from anon;
revoke all on function public._identity_can_read_community_post(uuid,uuid) from authenticated;
grant execute on function public._identity_can_read_community_post(uuid,uuid) to authenticated;

-- ------------------------------------------------------------ board helpers
create or replace function public._identity_is_board_director(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(
    select 1
      from public.enterprise_members m
     where m.enterprise_id=p_eid
       and m.profile_id=p_uid
       and m.status='active'
       and (
         m.role_key in ('chairperson','director')
         or exists(
           select 1
             from public.enterprise_role_assignments a
            where a.enterprise_id=m.enterprise_id
              and a.profile_id=m.profile_id
              and a.status='active'
              and a.starts_at<=now()
              and (a.ends_at is null or a.ends_at>now())
              and a.office_key in ('chairperson','director')
         )
       )
  );
$fn$;

create or replace function public._identity_board_director_count(p_eid uuid)
returns integer
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select count(distinct m.profile_id)::integer
    from public.enterprise_members m
   where m.enterprise_id=p_eid
     and m.status='active'
     and (
       m.role_key in ('chairperson','director')
       or exists(
         select 1
           from public.enterprise_role_assignments a
          where a.enterprise_id=m.enterprise_id
            and a.profile_id=m.profile_id
            and a.status='active'
            and a.starts_at<=now()
            and (a.ends_at is null or a.ends_at>now())
            and a.office_key in ('chairperson','director')
       )
     );
$fn$;

-- ------------------------------------------------------------ board RPCs
drop function if exists public.create_board_motion(text,text,jsonb);

create or replace function public.create_board_motion(
  p_title text,
  p_kind text,
  p_payload jsonb default '{}'::jsonb,
  p_conflict_disclosed boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_kind text:=lower(trim(coalesce(p_kind,'')));
  v_title text:=trim(coalesce(p_title,''));
  v_payload jsonb:=coalesce(p_payload,'{}'::jsonb);
  v_conflict_disclosed boolean:=coalesce(p_conflict_disclosed,false);
  v_motion uuid;
  v_total integer;
  v_limit integer;
  v_current_quarter text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));

  perform 1
    from public.enterprises
   where id=v_eid
   for update;

  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not public._identity_is_board_director(v_eid,v_uid) then
    raise exception 'only board directors may propose board motions';
  end if;
  if v_title='' then raise exception 'motion title is required'; end if;
  if v_kind not in ('point_pool','governance','operations') then
    raise exception 'invalid board motion kind';
  end if;
  if jsonb_typeof(v_payload) is distinct from 'object' then
    raise exception 'board motion payload must be an object';
  end if;
  if v_kind='point_pool' then
    if trim(coalesce(v_payload->>'quarter','')) !~ '^[0-9]{4}-Q[1-4]$' then
      raise exception 'point pool quarter is invalid';
    end if;
    v_current_quarter:=to_char(now() at time zone 'UTC','YYYY')
      ||'-Q'||to_char(now() at time zone 'UTC','Q');
    if v_payload->>'quarter'<>v_current_quarter then
      raise exception 'point pool quarter must be the current quarter';
    end if;
    begin
      v_total:=(v_payload->>'total_amount')::integer;
    exception when others then
      raise exception 'point pool total must be positive';
    end;
    if v_total is null or v_total<=0 then
      raise exception 'point pool total must be positive';
    end if;
    begin
      v_limit:=(v_payload->>'single_award_limit')::integer;
    exception when others then
      raise exception 'point pool single award limit is invalid';
    end;
    if v_limit is null or v_limit<=0 or v_limit>v_total then
      raise exception 'point pool single award limit is invalid';
    end if;
  end if;

  insert into public.enterprise_board_motions(
    enterprise_id,title,kind,payload,conflict_disclosed,proposer_profile_id
  ) values(
    v_eid,v_title,v_kind,v_payload,v_conflict_disclosed,v_uid
  )
  returning id into v_motion;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'board_motion.created',null,
    jsonb_build_object(
      'board_motion_id',v_motion,'title',v_title,'kind',v_kind,
      'conflict_disclosed',v_conflict_disclosed
    )
  );

  return jsonb_build_object(
    'ok',true,'board_motion_id',v_motion,'status','open',
    'conflict_disclosed',v_conflict_disclosed
  );
end;
$fn$;

create or replace function public.cast_board_vote(
  p_motion uuid,
  p_choice text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_board_motions%rowtype;
  v_choice text:=lower(trim(coalesce(p_choice,'')));
  v_director_count integer;
  v_cast_count integer;
  v_status text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_choice not in ('yes','no','abstain') then raise exception 'invalid vote'; end if;

  select * into v_m
    from public.enterprise_board_motions
   where id=p_motion
   for update;
  if not found then raise exception 'board motion not found'; end if;
  if v_m.status<>'open' then raise exception 'board motion is closed'; end if;
  if not public._identity_is_board_director(v_m.enterprise_id,v_uid) then
    raise exception 'only board directors may vote';
  end if;

  insert into public.enterprise_board_votes(
    motion_id,director_profile_id,choice
  ) values(p_motion,v_uid,v_choice)
  on conflict (motion_id,director_profile_id) do update
    set choice=excluded.choice,voted_at=now();

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'board_motion.vote_cast',null,
    jsonb_build_object(
      'board_motion_id',p_motion,'choice',v_choice
    )
  );

  select count(*)::integer into v_cast_count
    from public.enterprise_board_votes
   where motion_id=p_motion;
  v_director_count:=public._identity_board_director_count(v_m.enterprise_id);

  if v_director_count>0 and v_cast_count>=v_director_count then
    perform public.finalize_board_motion(p_motion);
  end if;

  select status into v_status
    from public.enterprise_board_motions
   where id=p_motion;

  return jsonb_build_object(
    'ok',true,'choice',v_choice,'cast_count',v_cast_count,
    'director_count',v_director_count,'motion_status',v_status
  );
end;
$fn$;

create or replace function public.finalize_board_motion(p_motion uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_board_motions%rowtype;
  v_director_count integer;
  v_cast_count integer;
  v_yes_count integer;
  v_status text;
  v_reason text;
  v_current_quarter text;
  v_pool_quarter text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  select * into v_m
    from public.enterprise_board_motions
   where id=p_motion
   for update;
  if not found then raise exception 'board motion not found'; end if;
  if v_m.status<>'open' then
    return jsonb_build_object('ok',true,'status',v_m.status);
  end if;
  if not public._identity_is_board_director(v_m.enterprise_id,v_uid) then
    raise exception 'only board directors may finalize board motions';
  end if;

  v_director_count:=public._identity_board_director_count(v_m.enterprise_id);
  select
    count(*)::integer,
    count(*) filter(where choice='yes')::integer
  into v_cast_count,v_yes_count
  from public.enterprise_board_votes
  where motion_id=p_motion;

  v_current_quarter:=to_char(now() at time zone 'UTC','YYYY')
    ||'-Q'||to_char(now() at time zone 'UTC','Q');
  if v_m.kind='point_pool' then
    v_pool_quarter:=trim(coalesce(v_m.payload->>'quarter',''));
  end if;

  if v_m.kind='point_pool' and v_pool_quarter<>v_current_quarter then
    v_status:='rejected';
    v_reason:='Point pool quarter is no longer current';
  else
    if not (v_cast_count*2>v_director_count) then
      raise exception 'board quorum not reached';
    end if;

    if v_yes_count*2>v_cast_count then
      v_status:='passed';
      v_reason:='Approved by a majority of directors present';
    else
      v_status:='rejected';
      v_reason:='Majority yes vote not reached';
    end if;
  end if;

  update public.enterprise_board_motions
     set status=v_status,decided_at=now()
   where id=p_motion;

  if v_status='passed' and v_m.kind='point_pool' then
    perform public._identity_apply_point_pool_motion(p_motion);
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'board_motion.'||v_status,null,
    jsonb_build_object(
      'board_motion_id',p_motion,
      'director_count',v_director_count,
      'cast_count',v_cast_count,
      'yes_count',v_yes_count,
      'pool_quarter',v_pool_quarter,
      'current_quarter',v_current_quarter,
      'reason',v_reason
    )
  );

  return jsonb_build_object(
    'ok',true,'status',v_status,'director_count',v_director_count,
    'cast_count',v_cast_count,'yes_count',v_yes_count,'reason',v_reason
  );
end;
$fn$;

create or replace function public._identity_apply_point_pool_motion(
  p_motion uuid
) returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.enterprise_board_motions%rowtype;
  v_quarter text;
  v_current_quarter text;
  v_total integer;
  v_limit integer;
  v_carry uuid;
  v_carry_pool public.enterprise_point_pools%rowtype;
  v_carry_remaining integer:=0;
  v_total_with_carry integer;
  v_pool uuid;
  v_existing uuid;
begin
  select * into v_m
    from public.enterprise_board_motions
   where id=p_motion
   for update;
  if not found then raise exception 'board motion not found'; end if;
  if v_m.kind<>'point_pool' then
    raise exception 'board motion is not a point pool';
  end if;
  if v_m.status<>'passed' then
    raise exception 'point pool motion is not approved';
  end if;

  select id into v_existing
    from public.enterprise_point_pools
   where board_motion_id=p_motion;
  if v_existing is not null then return v_existing; end if;

  v_quarter:=trim(coalesce(v_m.payload->>'quarter',''));
  if v_quarter !~ '^[0-9]{4}-Q[1-4]$' then
    raise exception 'point pool quarter is invalid';
  end if;
  v_current_quarter:=to_char(now() at time zone 'UTC','YYYY')
    ||'-Q'||to_char(now() at time zone 'UTC','Q');
  if v_quarter<>v_current_quarter then
    raise exception 'point pool quarter must be the current quarter';
  end if;
  begin
    v_total:=(v_m.payload->>'total_amount')::integer;
  exception when others then
    raise exception 'point pool total is invalid';
  end;
  begin
    v_limit:=(v_m.payload->>'single_award_limit')::integer;
  exception when others then
    raise exception 'point pool single award limit is invalid';
  end;
  if v_total is null or v_total<=0 then
    raise exception 'point pool total must be positive';
  end if;
  if v_limit is null or v_limit<=0 or v_limit>v_total then
    raise exception 'point pool single award limit is invalid';
  end if;
  if exists(
    select 1
      from public.enterprise_point_pools
     where enterprise_id=v_m.enterprise_id
       and quarter=v_quarter
  ) then
    raise exception 'point pool already approved for quarter';
  end if;

  if nullif(trim(coalesce(v_m.payload->>'carry_from','')),'') is not null then
    begin
      v_carry:=(v_m.payload->>'carry_from')::uuid;
    exception when others then
      raise exception 'carry_from pool is invalid';
    end;
    select * into v_carry_pool
      from public.enterprise_point_pools
     where id=v_carry
       and enterprise_id=v_m.enterprise_id
     for update;
    if not found then raise exception 'carry_from pool not found'; end if;
    if v_carry_pool.quarter>=v_quarter then
      raise exception 'carry_from pool must be from an earlier quarter';
    end if;
    v_carry_remaining:=v_carry_pool.remaining_amount;
  end if;

  v_total_with_carry:=v_total+v_carry_remaining;
  insert into public.enterprise_point_pools(
    enterprise_id,quarter,total_amount,remaining_amount,single_award_limit,
    status,board_motion_id,approved_at
  ) values(
    v_m.enterprise_id,v_quarter,v_total_with_carry,v_total_with_carry,v_limit,
    'active',p_motion,now()
  ) returning id into v_pool;

  update public.enterprise_point_pools
     set status='closed'
   where enterprise_id=v_m.enterprise_id
     and id<>v_pool
     and status='active';

  if v_carry is not null then
    update public.enterprise_point_pools
       set remaining_amount=0,carries_to=v_pool
     where id=v_carry;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'point_pool.approved',null,
    jsonb_build_object(
      'point_pool_id',v_pool,'board_motion_id',p_motion,
      'quarter',v_quarter,'base_total',v_total,
      'carried_remaining',v_carry_remaining,
      'total_amount',v_total_with_carry,
      'single_award_limit',v_limit,'carry_from',v_carry
    )
  );

  return v_pool;
end;
$fn$;

-- ------------------------------------------------------------ shareholder RPC replacements
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
  select * into v_m
    from public.enterprise_role_motions
   where id=p_motion
   for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then
    return jsonb_build_object('ok',true,'status',v_m.status);
  end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  select coalesce(sum(value::numeric),0)
    into v_total
    from jsonb_each_text(v_m.share_snapshot);

  select
    coalesce(sum(coalesce(
      (v_m.share_snapshot->>rv.voter_profile_id::text)::numeric,0
    )),0),
    coalesce(sum(coalesce(
      (v_m.share_snapshot->>rv.voter_profile_id::text)::numeric,0
    )) filter(where rv.choice='yes'),0),
    coalesce(sum(coalesce(
      (v_m.share_snapshot->>rv.voter_profile_id::text)::numeric,0
    )) filter(where rv.choice='no'),0)
  into v_cast,v_yes,v_no
  from public.enterprise_role_votes rv
  where rv.motion_id=p_motion;

  if v_total>0 then
    v_turnout_bps:=floor(v_cast/v_total*10000)::integer;
    if v_m.motion_class='major' then
      v_yes_bps:=floor(v_yes/v_total*10000)::integer;
    elsif (v_yes+v_no)>0 then
      v_yes_bps:=floor(v_yes/(v_yes+v_no)*10000)::integer;
    end if;
  end if;

  if v_total<=0 then
    v_status:='rejected';
    v_reason:='No voting shares in proposal snapshot';
  elsif v_m.motion_class='major' then
    if v_yes_bps<v_m.required_bps then
      v_status:='rejected';
      v_reason:='Major approval threshold not reached';
    else
      v_status:='passed';
      v_reason:='Approved by major shareholder vote';
    end if;
  else
    if v_turnout_bps<5000 then
      v_status:='rejected';
      v_reason:='Quorum not reached';
    elsif v_yes*10000<=(v_yes+v_no)*5000 then
      v_status:='rejected';
      v_reason:='Approval threshold not reached';
    else
      v_status:='passed';
      v_reason:='Approved by weighted shareholder vote';
    end if;
  end if;

  update public.enterprise_role_motions
     set status=v_status,decided_at=now(),decision_reason=v_reason,
         updated_at=now()
   where id=p_motion;

  if v_status='passed' then
    if v_m.kind='appointment' then
      update public.enterprise_members
         set role_key=v_m.proposed_role_key,
             department=v_m.proposed_department,
             title=v_m.proposed_title,
             appointed_by=v_m.proposer_profile_id,
             appointed_at=now(),updated_at=now(),status='active'
       where enterprise_id=v_m.enterprise_id
         and profile_id=v_m.target_profile_id;
    elsif v_m.kind='removal' then
      update public.enterprise_members
         set role_key='employee',department='',title='',
             appointed_by=v_m.proposer_profile_id,
             appointed_at=now(),updated_at=now(),status='active'
       where enterprise_id=v_m.enterprise_id
         and profile_id=v_m.target_profile_id;
    elsif v_m.kind='share_change' then
      if not public._identity_is_member(
        v_m.enterprise_id,v_m.target_profile_id
      ) then
        raise exception 'share target is not an active enterprise member';
      end if;
      if (v_m.payload->>'shares') is null then
        raise exception 'share change payload is invalid';
      end if;
      update public.enterprise_shareholders
         set shares=(v_m.payload->>'shares')::numeric,
             updated_by=v_m.proposer_profile_id,
             updated_at=now()
       where enterprise_id=v_m.enterprise_id
         and profile_id=v_m.target_profile_id;
      if not found then
        insert into public.enterprise_shareholders(
          enterprise_id,profile_id,shares,updated_by
        ) values(
          v_m.enterprise_id,v_m.target_profile_id,
          (v_m.payload->>'shares')::numeric,v_m.proposer_profile_id
        );
      end if;
    elsif v_m.kind='template_change' then
      perform public._identity_apply_template_change_motion(p_motion);
    end if;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'motion.'||v_status,v_m.target_profile_id,
    jsonb_build_object(
      'motion_id',v_m.id,'kind',v_m.kind,'role',v_m.proposed_role_key,
      'motion_class',v_m.motion_class,'required_bps',v_m.required_bps,
      'conflict_disclosed',v_m.conflict_disclosed,
      'payload',v_m.payload,
      'turnout_bps',v_turnout_bps,'yes_bps',v_yes_bps,'reason',v_reason
    )
  );

  return jsonb_build_object(
    'ok',true,'status',v_status,'motion_class',v_m.motion_class,
    'required_bps',v_m.required_bps,'turnout_bps',v_turnout_bps,
    'yes_bps',v_yes_bps,'reason',v_reason
  );
end;
$fn$;

drop function if exists public.propose_enterprise_role(uuid,text,text,text,text,text,integer);

create or replace function public.propose_enterprise_role(
  p_target uuid,
  p_kind text,
  p_role_key text default 'employee',
  p_department text default '',
  p_title text default '',
  p_reason text default '',
  p_days integer default 3,
  p_conflict_disclosed boolean default false
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
  v_effective_role text;
  v_motion_class text;
  v_required_bps integer;
  v_snapshot jsonb:='{}'::jsonb;
  v_conflict_disclosed boolean:=coalesce(p_conflict_disclosed,false);
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));

  perform 1
    from public.enterprises
   where id=v_eid
   for update;

  if public._identity_shares(v_eid,v_uid)<=0 then
    raise exception 'only shareholders may propose role changes';
  end if;
  if v_kind not in ('appointment','removal') then
    raise exception 'invalid motion kind';
  end if;

  select * into v_target
    from public.enterprise_members
   where enterprise_id=v_eid
     and profile_id=p_target
     and status='active';
  if not found then raise exception 'target is not an active enterprise member'; end if;

  if p_target=v_uid and not v_conflict_disclosed then
    raise exception 'proposer must disclose a conflict when proposing for self';
  end if;

  if v_kind='appointment' then
    if v_role is null then raise exception 'role is required'; end if;
    if not exists(
      select 1 from public.enterprise_role_catalog where key=v_role
    ) then
      raise exception 'unknown role';
    end if;
    if v_target.role_key=v_role then
      raise exception 'target already holds this role';
    end if;
  else
    if v_target.role_key='employee' then
      raise exception 'target already has the base employee role';
    end if;
    v_role:=null;
  end if;

  v_effective_role:=case
    when v_kind='appointment' then v_role
    else v_target.role_key
  end;
  v_motion_class:=case
    when v_effective_role in (
      'chairperson','director','supervisor','ceo','finance','identity_admin'
    ) then 'major'
    else 'ordinary'
  end;
  v_required_bps:=case when v_motion_class='major' then 6667 else 5001 end;

  select coalesce(jsonb_object_agg(s.profile_id::text,s.shares),'{}'::jsonb)
    into v_snapshot
    from public.enterprise_shareholders s
    join public.enterprise_members m
      on m.enterprise_id=s.enterprise_id
     and m.profile_id=s.profile_id
   where s.enterprise_id=v_eid
     and s.shares>0
     and m.status='active';

  insert into public.enterprise_role_motions(
    enterprise_id,kind,target_profile_id,proposed_role_key,
    proposed_department,proposed_title,reason,proposer_profile_id,
    quorum_bps,approval_bps,closes_at,motion_class,share_snapshot,
    required_bps,conflict_disclosed
  ) values(
    v_eid,v_kind,p_target,v_role,trim(coalesce(p_department,'')),
    trim(coalesce(p_title,'')),trim(coalesce(p_reason,'')),v_uid,
    case when v_motion_class='major' then 0 else 5000 end,
    v_required_bps,now()+make_interval(days=>v_days),v_motion_class,
    v_snapshot,v_required_bps,v_conflict_disclosed
  )
  returning id into v_motion;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'motion.created',p_target,
    jsonb_build_object(
      'motion_id',v_motion,'kind',v_kind,'role',v_role,
      'effective_role',v_effective_role,
      'motion_class',v_motion_class,'required_bps',v_required_bps,
      'conflict_disclosed',v_conflict_disclosed,
      'shareholder_count',(
        select count(*) from jsonb_object_keys(v_snapshot)
      )
    )
  );

  return jsonb_build_object(
    'ok',true,'motion_id',v_motion,'motion_class',v_motion_class,
    'required_bps',v_required_bps,'conflict_disclosed',v_conflict_disclosed
  );
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

  select * into v_m
    from public.enterprise_role_motions
   where id=p_motion
   for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then raise exception 'motion is closed'; end if;
  if now()>=v_m.closes_at then
    perform public._identity_finalize_motion(p_motion);
    raise exception 'voting period has ended';
  end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  v_shares:=coalesce(
    (v_m.share_snapshot->>v_uid::text)::numeric,
    0
  );
  if v_shares<=0 then
    raise exception 'only shareholders in the proposal snapshot may vote';
  end if;

  insert into public.enterprise_role_votes(
    motion_id,voter_profile_id,choice,shares_at_vote
  ) values(p_motion,v_uid,v_choice,v_shares)
  on conflict (motion_id,voter_profile_id) do update
    set choice=excluded.choice,shares_at_vote=excluded.shares_at_vote,
        voted_at=now(),updated_at=now();

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_m.enterprise_id,v_uid,'motion.vote_cast',null,
    jsonb_build_object(
      'motion_id',p_motion,'choice',v_choice,'shares',v_shares,
      'motion_class',v_m.motion_class
    )
  );

  select coalesce(sum(coalesce(
    (v_m.share_snapshot->>rv.voter_profile_id::text)::numeric,0
  )),0)
    into v_cast
    from public.enterprise_role_votes rv
   where rv.motion_id=p_motion;

  select coalesce(sum(value::numeric),0)
    into v_total
    from jsonb_each_text(v_m.share_snapshot);

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

  select * into v_m
    from public.enterprise_role_motions
   where id=p_motion;
  if not found then raise exception 'motion not found'; end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  select coalesce(sum(coalesce(
    (v_m.share_snapshot->>rv.voter_profile_id::text)::numeric,0
  )),0)
    into v_cast
    from public.enterprise_role_votes rv
   where rv.motion_id=p_motion;

  select coalesce(sum(value::numeric),0)
    into v_total
    from jsonb_each_text(v_m.share_snapshot);

  if now()<v_m.closes_at and v_cast<v_total then
    raise exception 'voting is still in progress';
  end if;

  return public._identity_finalize_motion(p_motion);
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

  select owner_profile_id into v_owner
    from public.enterprises
   where id=v_eid
   for update;

  if v_uid<>v_owner then raise exception 'only the enterprise owner may change shares'; end if;
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'target is not an active enterprise member';
  end if;
  if p_profile=v_owner and v_shares<=0 then
    raise exception 'enterprise owner must retain voting shares';
  end if;
  -- New positive-share holders and share changes are governance-sensitive.
  -- Ordinary employee additions do not pass through this RPC.
  if exists(
    select 1
      from public.enterprise_role_motions
     where enterprise_id=v_eid
       and status='open'
  ) or exists(
    select 1
      from public.enterprise_board_motions
     where enterprise_id=v_eid
       and status='open'
  ) then
    raise exception 'cannot change shares while a role or board motion is open';
  end if;

  insert into public.enterprise_shareholders(
    enterprise_id,profile_id,shares,updated_by
  ) values(v_eid,p_profile,v_shares,v_uid)
  on conflict (enterprise_id,profile_id) do update
    set shares=excluded.shares,updated_by=excluded.updated_by,
        updated_at=now();

  select public._identity_total_shares(v_eid) into v_total;
  if v_total<=0 then
    raise exception 'enterprise must have positive voting shares';
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'shares.updated',p_profile,
    jsonb_build_object('shares',v_shares,'total_shares',v_total)
  );

  return jsonb_build_object(
    'ok',true,'shares',v_shares,'total_shares',v_total
  );
end;
$fn$;

create or replace function public._identity_can_read_full_point_ledger(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._identity_is_board_director(p_eid,p_uid)
    or exists(
      select 1
        from public.enterprise_members m
       where m.enterprise_id=p_eid
         and m.profile_id=p_uid
         and m.status='active'
         and m.role_key='auditor'
    )
    or public._identity_role_permissions(p_eid,p_uid) ? 'audit.read';
$fn$;
create or replace function public._identity_award_evidence_is_valid(
  p_eid uuid,
  p_profile uuid,
  p_evidence_type text,
  p_evidence_id uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_owner uuid;
  v_type text:=lower(trim(coalesce(p_evidence_type,'')));
begin
  if p_evidence_id is null then return false; end if;
  select owner_profile_id into v_owner
    from public.enterprises where id=p_eid;

  if v_type='acceptance' then
    return exists(
      select 1
        from public.task_logs l
        join public.tasks t on t.id=l.task_id
       where l.id=p_evidence_id
         and l.employee_id=p_profile
         and t.employee_id=p_profile
         and t.boss_id=v_owner
    );
  elsif v_type='collaboration' then
    return exists(
      select 1
        from public.worklogs w
       where w.id=p_evidence_id
         and w.employee_id=p_profile
         and w.boss_id=v_owner
    );
  elsif v_type='knowledge' then
    return exists(
      select 1
        from public.knowledge_items k
       where k.id=p_evidence_id
         and k.owner_id=p_profile
         and (k.boss_id is null or k.boss_id=v_owner)
    ) or exists(
      select 1
        from public.community_posts p
       where p.id=p_evidence_id
         and p.author_id=p_profile
    );
  end if;
  return false;
end;
$fn$;
-- ------------------------------------------------------------ chairperson points
create or replace function public._identity_is_chairperson(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(
    select 1
      from public.enterprise_members m
     where m.enterprise_id=p_eid
       and m.profile_id=p_uid
       and m.status='active'
       and (
         m.role_key='chairperson'
         or exists(
           select 1
             from public.enterprise_role_assignments a
            where a.enterprise_id=m.enterprise_id
              and a.profile_id=m.profile_id
              and a.status='active'
              and a.starts_at<=now()
              and (a.ends_at is null or a.ends_at>now())
              and a.office_key='chairperson'
         )
       )
  );
$fn$;

create or replace function public.award_points(
  p_profile uuid,
  p_amount integer,
  p_evidence_type text,
  p_evidence_id uuid,
  p_reason text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_quarter text;
  v_pool public.enterprise_point_pools%rowtype;
  v_evidence_type text:=lower(trim(coalesce(p_evidence_type,'')));
  v_reason text:=trim(coalesce(p_reason,''));
  v_ledger uuid;
  v_remaining integer;
  v_balance integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not public._identity_is_chairperson(v_eid,v_uid) then
    raise exception 'only the active chairperson may award points';
  end if;
  if p_profile is null then raise exception 'point recipient is required'; end if;
  if p_profile=v_uid then
    raise exception 'chairperson cannot award points to self';
  end if;
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'point recipient is not an active enterprise member';
  end if;

  perform 1 from public.profiles where id=p_profile for update;

  if p_amount is null or p_amount<=0 then
    raise exception 'point amount must be positive';
  end if;
  if v_evidence_type='' or p_evidence_id is null then
    raise exception 'evidence is required for point awards';
  end if;
  if not public._identity_award_evidence_is_valid(
    v_eid,p_profile,v_evidence_type,p_evidence_id
  ) then
    raise exception 'evidence record is not allowed';
  end if;
  if v_reason='' then
    raise exception 'reason is required for point awards';
  end if;
  if exists(
    select 1
      from public.enterprise_point_ledger l
     where l.enterprise_id=v_eid
       and l.profile_id=p_profile
       and l.entry_type='award'
       and l.evidence_type=v_evidence_type
       and l.evidence_id=p_evidence_id
  ) then
    raise exception 'point evidence was already awarded';
  end if;

  v_quarter:=to_char(now() at time zone 'UTC','YYYY')
    ||'-Q'||to_char(now() at time zone 'UTC','Q');
  select p.* into v_pool
    from public.enterprise_point_pools p
   where p.enterprise_id=v_eid
     and p.quarter=v_quarter
     and p.status='active'
   order by p.approved_at desc
   limit 1
   for update;
  if not found then
    raise exception 'no active point pool for current quarter';
  end if;
  if not exists(
    select 1
      from public.enterprise_board_motions bm
     where bm.id=v_pool.board_motion_id
       and bm.enterprise_id=v_pool.enterprise_id
       and bm.kind='point_pool'
       and bm.status='passed'
  ) then
    raise exception 'point pool is not board approved';
  end if;
  if p_amount>v_pool.single_award_limit then
    raise exception 'single award limit exceeded';
  end if;
  if p_amount>v_pool.remaining_amount then
    raise exception 'point pool exceeded';
  end if;

  update public.enterprise_point_pools
     set remaining_amount=remaining_amount-p_amount
   where id=v_pool.id
   returning remaining_amount into v_remaining;

  insert into public.enterprise_point_ledger(
    enterprise_id,profile_id,amount,entry_type,pool_id,evidence_type,
    evidence_id,reason,actor_profile_id
  ) values(
    v_eid,p_profile,p_amount,'award',v_pool.id,v_evidence_type,
    p_evidence_id,v_reason,v_uid
  ) returning id into v_ledger;

  select coalesce(sum(l.amount),0)::integer into v_balance
    from public.enterprise_point_ledger l
   where l.enterprise_id=v_eid
     and l.profile_id=p_profile;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'point.awarded',p_profile,
    jsonb_build_object(
      'ledger_id',v_ledger,'pool_id',v_pool.id,'amount',p_amount,
      'evidence_type',v_evidence_type,'evidence_id',p_evidence_id,
      'reason',v_reason,'pool_remaining',v_remaining
    )
  );

  return jsonb_build_object(
    'ok',true,'ledger_id',v_ledger,'amount',p_amount,
    'balance',v_balance,'pool_remaining',v_remaining,
    'points_are_permanent',true
  );
end;
$fn$;

create or replace function public.get_point_state()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_quarter text;
  v_pool public.enterprise_point_pools%rowtype;
  v_balance integer;
  v_ledger jsonb;
  v_can_read_full_ledger boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  v_can_read_full_ledger:=public._identity_can_read_full_point_ledger(
    v_eid,v_uid
  );

  v_quarter:=to_char(now() at time zone 'UTC','YYYY')
    ||'-Q'||to_char(now() at time zone 'UTC','Q');
  select p.* into v_pool
    from public.enterprise_point_pools p
   where p.enterprise_id=v_eid
     and p.quarter=v_quarter
     and p.status='active'
   order by p.approved_at desc
   limit 1;

  select coalesce(sum(l.amount),0)::integer into v_balance
    from public.enterprise_point_ledger l
   where l.enterprise_id=v_eid
     and l.profile_id=v_uid;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',l.id,
        'profile_id',l.profile_id,
        'profile_name',recipient.name,
        'amount',l.amount,
        'entry_type',l.entry_type,
        'evidence_type',l.evidence_type,
        'evidence_id',l.evidence_id,
        'reason',l.reason,
        'actor_profile_id',l.actor_profile_id,
        'actor_name',a.name,
        'created_at',l.created_at
      ) order by l.created_at desc
    ),'[]'::jsonb
  ) into v_ledger
  from (
    select l.*
      from public.enterprise_point_ledger l
     where l.enterprise_id=v_eid
       and (v_can_read_full_ledger or l.profile_id=v_uid)
     order by l.created_at desc
  ) l
  left join public.profiles recipient on recipient.id=l.profile_id
  left join public.profiles a on a.id=l.actor_profile_id;

  return jsonb_build_object(
    'ok',true,
    'balance',v_balance,
    'can_read_full_ledger',v_can_read_full_ledger,
    'ledger_scope',case when v_can_read_full_ledger then 'enterprise' else 'self' end,
    'pool',case
      when v_pool.id is null then 'null'::jsonb
      else jsonb_build_object(
        'id',v_pool.id,
        'quarter',v_pool.quarter,
        'total',v_pool.total_amount,
        'remaining',v_pool.remaining_amount,
        'single_award_limit',v_pool.single_award_limit,
        'approved_at',v_pool.approved_at
      )
    end,
    'ledger',v_ledger,
    'points_are_permanent',true
  );
end;
$fn$;

create or replace function public.unlock_knowledge_content(p_post uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_post public.community_posts%rowtype;
  v_unlock public.enterprise_knowledge_unlocks%rowtype;
  v_cost integer;
  v_balance integer;
  v_ledger uuid;
  v_after integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_post is null then raise exception 'knowledge post is required'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  perform 1 from public.profiles where id=v_uid for update;

  select * into v_post
    from public.community_posts
   where id=p_post
   for share;
  if not found then raise exception 'knowledge post not found'; end if;

  if v_post.is_required then
    return jsonb_build_object(
      'ok',true,'unlocked',true,'required',true,'cost',0,
      'content',v_post.content,'points_are_permanent',true
    );
  end if;
  if v_post.unlock_cost=0 or v_post.author_id=v_uid then
    return jsonb_build_object(
      'ok',true,'unlocked',true,'required',false,'cost',0,
      'content',v_post.content,'points_are_permanent',true
    );
  end if;

  select * into v_unlock
    from public.enterprise_knowledge_unlocks u
   where u.profile_id=v_uid
     and u.post_id=p_post;
  if found then
    return jsonb_build_object(
      'ok',true,'unlocked',true,'required',false,
      'cost',v_unlock.cost,'already_unlocked',true,
      'content',v_post.content,'points_are_permanent',true
    );
  end if;

  v_cost:=v_post.unlock_cost;
  select coalesce(sum(l.amount),0)::integer into v_balance
    from public.enterprise_point_ledger l
   where l.enterprise_id=v_eid
     and l.profile_id=v_uid;
  if v_balance<v_cost then
    raise exception 'insufficient points to unlock knowledge';
  end if;

  insert into public.enterprise_point_ledger(
    enterprise_id,profile_id,amount,entry_type,pool_id,evidence_type,
    evidence_id,reason,actor_profile_id
  ) values(
    v_eid,v_uid,-v_cost,'unlock',null,'knowledge',p_post,
    'Unlock knowledge content',v_uid
  ) returning id into v_ledger;

  insert into public.enterprise_knowledge_unlocks(
    enterprise_id,profile_id,post_id,cost,ledger_id
  ) values(
    v_eid,v_uid,p_post,v_cost,v_ledger
  );

  v_after:=v_balance-v_cost;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'knowledge.unlocked',v_uid,
    jsonb_build_object(
      'post_id',p_post,'ledger_id',v_ledger,'cost',v_cost,
      'balance_after',v_after
    )
  );

  return jsonb_build_object(
    'ok',true,'unlocked',true,'required',false,
    'cost',v_cost,'balance',v_after,'ledger_id',v_ledger,
    'content',v_post.content,'points_are_permanent',true
  );
end;
$fn$;

create or replace function public.set_enterprise_ui_mode(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if p_mode not in ('simple','advanced') then
    raise exception 'invalid mode';
  end if;
  v_eid:=public._identity_bootstrap(
    public._identity_owner_for_uid(v_uid)
  );
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  update public.enterprise_members
     set preferred_mode=p_mode,
         updated_at=now()
   where enterprise_id=v_eid
     and profile_id=v_uid;
  return jsonb_build_object('ok',true,'mode',p_mode);
end;
$fn$;

-- ------------------------------------------------------------ task 5 grants
revoke all on function public.set_enterprise_ui_mode(text) from public;
revoke all on function public.set_enterprise_ui_mode(text) from anon;
revoke all on function public.set_enterprise_ui_mode(text) from authenticated;
grant execute on function public.set_enterprise_ui_mode(text) to authenticated;


revoke all on function public._identity_is_chairperson(uuid,uuid) from public;
revoke all on function public._identity_is_chairperson(uuid,uuid) from anon;
revoke all on function public._identity_is_chairperson(uuid,uuid) from authenticated;

revoke all on function public._identity_apply_point_pool_motion(uuid) from public;
revoke all on function public._identity_apply_point_pool_motion(uuid) from anon;
revoke all on function public._identity_apply_point_pool_motion(uuid) from authenticated;

revoke all on function public._identity_can_read_community_post(uuid,uuid) from public;
revoke all on function public._identity_can_read_community_post(uuid,uuid) from anon;
revoke all on function public._identity_can_read_community_post(uuid,uuid) from authenticated;
grant execute on function public._identity_can_read_community_post(uuid,uuid) to authenticated;

revoke all on function public.award_points(uuid,integer,text,uuid,text) from public;
revoke all on function public.award_points(uuid,integer,text,uuid,text) from anon;
revoke all on function public.award_points(uuid,integer,text,uuid,text) from authenticated;
grant execute on function public.award_points(uuid,integer,text,uuid,text) to authenticated;

revoke all on function public.get_point_state() from public;
revoke all on function public.get_point_state() from anon;
revoke all on function public.get_point_state() from authenticated;
grant execute on function public.get_point_state() to authenticated;
revoke all on function public._identity_can_read_full_point_ledger(uuid,uuid) from public;
revoke all on function public._identity_can_read_full_point_ledger(uuid,uuid) from anon;
revoke all on function public._identity_can_read_full_point_ledger(uuid,uuid) from authenticated;
revoke all on function public._identity_award_evidence_is_valid(uuid,uuid,text,uuid) from public;
revoke all on function public._identity_award_evidence_is_valid(uuid,uuid,text,uuid) from anon;
revoke all on function public._identity_award_evidence_is_valid(uuid,uuid,text,uuid) from authenticated;

revoke all on function public.unlock_knowledge_content(uuid) from public;
revoke all on function public.unlock_knowledge_content(uuid) from anon;
revoke all on function public.unlock_knowledge_content(uuid) from authenticated;
grant execute on function public.unlock_knowledge_content(uuid) to authenticated;

-- ------------------------------------------------------------ task 4 grants
revoke all on function public._identity_is_board_director(uuid,uuid) from public;
revoke all on function public._identity_is_board_director(uuid,uuid) from anon;
revoke all on function public._identity_is_board_director(uuid,uuid) from authenticated;
revoke all on function public._identity_board_director_count(uuid) from public;
revoke all on function public._identity_board_director_count(uuid) from anon;
revoke all on function public._identity_board_director_count(uuid) from authenticated;
revoke all on function public._identity_finalize_motion(uuid) from public;
revoke all on function public._identity_finalize_motion(uuid) from anon;
revoke all on function public._identity_finalize_motion(uuid) from authenticated;

revoke all on function public.create_board_motion(text,text,jsonb,boolean) from public;
revoke all on function public.create_board_motion(text,text,jsonb,boolean) from anon;
revoke all on function public.create_board_motion(text,text,jsonb,boolean) from authenticated;
grant execute on function public.create_board_motion(text,text,jsonb,boolean) to authenticated;

revoke all on function public.cast_board_vote(uuid,text) from public;
revoke all on function public.cast_board_vote(uuid,text) from anon;
revoke all on function public.cast_board_vote(uuid,text) from authenticated;
grant execute on function public.cast_board_vote(uuid,text) to authenticated;

revoke all on function public.finalize_board_motion(uuid) from public;
revoke all on function public.finalize_board_motion(uuid) from anon;
revoke all on function public.finalize_board_motion(uuid) from authenticated;
grant execute on function public.finalize_board_motion(uuid) to authenticated;

revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from public;
revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from anon;
revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from authenticated;
grant execute on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) to authenticated;

revoke all on function public.cast_enterprise_role_vote(uuid,text) from public;
revoke all on function public.cast_enterprise_role_vote(uuid,text) from anon;
revoke all on function public.cast_enterprise_role_vote(uuid,text) from authenticated;
grant execute on function public.cast_enterprise_role_vote(uuid,text) to authenticated;

revoke all on function public.close_enterprise_role_vote(uuid) from public;
revoke all on function public.close_enterprise_role_vote(uuid) from anon;
revoke all on function public.close_enterprise_role_vote(uuid) from authenticated;
grant execute on function public.close_enterprise_role_vote(uuid) to authenticated;

revoke all on function public.set_enterprise_shareholder(uuid,numeric) from public;
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from anon;
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from authenticated;

-- ============================================================
-- Final review remediation
-- ============================================================

-- High-risk template changes require a major shareholder motion. This
-- comment is retained as a contract marker; the implementation below
-- creates a motion instead of rejecting the request. legacy marker:
-- high-risk template changes require a major shareholder motion.
-- Share and template changes are shareholder motions. The payload is
-- kept on the motion so the exact approved change can be audited and
-- applied only after the vote passes.
alter table public.enterprise_role_motions
  drop constraint if exists enterprise_role_motions_kind_check;
alter table public.enterprise_role_motions
  add constraint enterprise_role_motions_kind_check
  check (kind in ('appointment','removal','share_change','template_change'));
alter table public.enterprise_role_motions
  add column if not exists payload jsonb not null default '{}'::jsonb;
alter table public.enterprise_role_motions
  alter column target_profile_id drop not null;

create unique index if not exists enterprise_one_open_share_motion_idx
  on public.enterprise_role_motions(enterprise_id,target_profile_id)
  where status='open' and kind='share_change';
create unique index if not exists enterprise_one_open_template_motion_idx
  on public.enterprise_role_motions(
    enterprise_id,(payload->>'template_id'),(payload->>'template_key')
  )
  where status='open' and kind='template_change';

-- Owners and CEOs can administer temporary assignments. The legacy
-- template capability remains mandatory so the permission ceiling is
-- still evaluated by the ordinary identity-admin path.
update public.enterprise_role_catalog
   set permissions = permissions || '["identity.manage_templates"]'::jsonb
 where key in ('chairperson','ceo')
   and not (permissions ? 'identity.manage_templates');

create or replace function public._identity_can_use_advanced_mode(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(public._identity_role_permissions(p_eid,p_uid) ?| array[
    'company.manage',
    'projects.view_all','projects.manage',
    'people.view_all','people.manage',
    'worklogs.approve','tasks.assign','tasks.grade',
    'finance.view','finance.manage','reports.view','audit.read',
    'identity.manage_templates','governance.manage','governance.vote'
  ],false);
$fn$;

create or replace function public.set_enterprise_ui_mode(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if p_mode not in ('simple','advanced') then
    raise exception 'invalid mode';
  end if;
  v_eid:=public._identity_bootstrap(
    public._identity_owner_for_uid(v_uid)
  );
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if p_mode='advanced'
     and not public._identity_can_use_advanced_mode(v_eid,v_uid) then
    raise exception 'advanced mode requires management, finance, audit or governance permission';
  end if;
  update public.enterprise_members
     set preferred_mode=p_mode,
         updated_at=now()
   where enterprise_id=v_eid
     and profile_id=v_uid;
  return jsonb_build_object('ok',true,'mode',p_mode);
end;
$fn$;

create or replace function public._identity_create_shareholder_motion(
  p_eid uuid,
  p_uid uuid,
  p_kind text,
  p_target uuid,
  p_role_key text,
  p_department text,
  p_title text,
  p_reason text,
  p_payload jsonb,
  p_motion_class text,
  p_days integer,
  p_conflict_disclosed boolean
) returns uuid
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_motion uuid;
  v_days integer;
  v_required_bps integer:=case when p_motion_class='major' then 6667 else 5001 end;
  v_snapshot jsonb:='{}'::jsonb;
begin
  v_days:=coalesce(
    p_days,
    case when p_motion_class='major' then 5 else 3 end
  );
  v_days:=least(greatest(v_days,1),14);

  select coalesce(jsonb_object_agg(s.profile_id::text,s.shares),'{}'::jsonb)
    into v_snapshot
    from public.enterprise_shareholders s
    join public.enterprise_members m
      on m.enterprise_id=s.enterprise_id
     and m.profile_id=s.profile_id
   where s.enterprise_id=p_eid
     and s.shares>0
     and m.status='active';

  insert into public.enterprise_role_motions(
    enterprise_id,kind,target_profile_id,proposed_role_key,
    proposed_department,proposed_title,reason,proposer_profile_id,
    quorum_bps,approval_bps,closes_at,motion_class,share_snapshot,
    required_bps,conflict_disclosed,payload
  ) values(
    p_eid,p_kind,p_target,p_role_key,
    trim(coalesce(p_department,'')),trim(coalesce(p_title,'')),
    trim(coalesce(p_reason,'')),p_uid,
    case when p_motion_class='major' then 0 else 5000 end,
    v_required_bps,now()+make_interval(days=>v_days),p_motion_class,
    v_snapshot,v_required_bps,coalesce(p_conflict_disclosed,false),
    coalesce(p_payload,'{}'::jsonb)
  ) returning id into v_motion;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_eid,p_uid,'motion.created',p_target,
    jsonb_build_object(
      'motion_id',v_motion,'kind',p_kind,'motion_class',p_motion_class,
      'required_bps',v_required_bps,'days',v_days,
      'conflict_disclosed',coalesce(p_conflict_disclosed,false),
      'shareholder_count',(select count(*) from jsonb_object_keys(v_snapshot))
    )
  );
  return v_motion;
end;
$fn$;

drop function if exists public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean);

create or replace function public.propose_enterprise_role(
  p_target uuid,
  p_kind text,
  p_role_key text default 'employee',
  p_department text default '',
  p_title text default '',
  p_reason text default '',
  p_days integer default null,
  p_conflict_disclosed boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_target public.enterprise_members%rowtype;
  v_motion uuid;
  v_kind text:=lower(trim(coalesce(p_kind,'')));
  v_role text:=nullif(trim(coalesce(p_role_key,'')),'');
  v_effective_role text;
  v_motion_class text;
  v_required_bps integer;
  v_conflict_disclosed boolean:=coalesce(p_conflict_disclosed,false);
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));

  perform 1
    from public.enterprises
   where id=v_eid
   for update;

  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if public._identity_shares(v_eid,v_uid)<=0 then
    raise exception 'only active shareholders may propose role changes';
  end if;
  if v_kind not in ('appointment','removal') then
    raise exception 'invalid motion kind';
  end if;

  select * into v_target
    from public.enterprise_members
   where enterprise_id=v_eid
     and profile_id=p_target
     and status='active';
  if not found then raise exception 'target is not an active enterprise member'; end if;

  if p_target=v_uid and not v_conflict_disclosed then
    raise exception 'proposer must disclose a conflict when proposing for self';
  end if;

  if v_kind='appointment' then
    if v_role is null then raise exception 'role is required'; end if;
    if not exists(
      select 1 from public.enterprise_role_catalog where key=v_role
    ) then
      raise exception 'unknown role';
    end if;
    if v_target.role_key=v_role then
      raise exception 'target already holds this role';
    end if;
  else
    if v_target.role_key='employee' then
      raise exception 'target already has the base employee role';
    end if;
    v_role:=null;
  end if;

  v_effective_role:=case
    when v_kind='appointment' then v_role
    else v_target.role_key
  end;
  v_motion_class:=case
    when v_effective_role in (
      'chairperson','director','supervisor','ceo','finance','identity_admin'
    ) then 'major'
    else 'ordinary'
  end;
  v_required_bps:=case when v_motion_class='major' then 6667 else 5001 end;

  v_motion:=public._identity_create_shareholder_motion(
    v_eid,v_uid,v_kind,p_target,v_role,
    p_department,p_title,p_reason,'{}'::jsonb,
    v_motion_class,p_days,v_conflict_disclosed
  );

  return jsonb_build_object(
    'ok',true,'motion_id',v_motion,'motion_class',v_motion_class,
    'required_bps',v_required_bps,'conflict_disclosed',v_conflict_disclosed
  );
exception when unique_violation then
  raise exception 'this member already has an open role motion';
end;
$fn$;

create or replace function public.propose_enterprise_share_change(
  p_profile uuid,
  p_shares numeric,
  p_reason text default '',
  p_days integer default 5,
  p_conflict_disclosed boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_owner uuid;
  v_motion uuid;
  v_shares numeric:=round(greatest(coalesce(p_shares,0),0),4);
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if public._identity_shares(v_eid,v_uid)<=0 then
    raise exception 'only active shareholders may propose share changes';
  end if;
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'target is not an active enterprise member';
  end if;
  select owner_profile_id into v_owner
    from public.enterprises where id=v_eid for update;
  if p_profile=v_owner and v_shares<=0 then
    raise exception 'enterprise owner must retain voting shares';
  end if;
  if v_reason='' then
    raise exception 'share change reason is required';
  end if;

  v_motion:=public._identity_create_shareholder_motion(
    v_eid,v_uid,'share_change',p_profile,null,'','',
    v_reason,jsonb_build_object('shares',v_shares),
    'major',coalesce(p_days,5),coalesce(p_conflict_disclosed,false)
  );

  return jsonb_build_object(
    'ok',true,'motion_id',v_motion,'motion_class','major',
    'required_bps',6667,'status','open','days',coalesce(p_days,5),
    'conflict_disclosed',coalesce(p_conflict_disclosed,false)
  );
end;
$fn$;

create or replace function public.propose_template_change(
  p_template uuid,
  p_name text,
  p_permissions jsonb,
  p_reason text default '',
  p_days integer default 5,
  p_conflict_disclosed boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_template public.enterprise_role_templates%rowtype;
  v_motion uuid;
  v_reason text:=trim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;
  select * into v_template
    from public.enterprise_role_templates
   where id=p_template and enterprise_id=v_eid and archived_at is null
   for update;
  if not found then raise exception 'role template not found'; end if;
  if p_permissions is null or jsonb_typeof(p_permissions)<>'array' then
    raise exception 'permissions must be an array';
  end if;
  if not public._identity_permissions_are_grantable(
    v_eid,v_uid,p_permissions
  ) then
    raise exception 'cannot grant permissions you do not hold';
  end if;
  if v_reason='' then raise exception 'template change reason is required'; end if;

  v_motion:=public._identity_create_shareholder_motion(
    v_eid,v_uid,'template_change',null,null,'','',
    v_reason,
    jsonb_build_object(
      'template_id',v_template.id,
      'template_key',v_template.key,
      'name',trim(coalesce(p_name,'')),
      'permissions',p_permissions
    ),
    'major',coalesce(p_days,5),coalesce(p_conflict_disclosed,false)
  );
  return jsonb_build_object(
    'ok',true,'motion_id',v_motion,'motion_class','major',
    'required_bps',6667,'status','open','days',coalesce(p_days,5)
  );
end;
$fn$;

create or replace function public._identity_apply_template_change_motion(
  p_motion uuid
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_m public.enterprise_role_motions%rowtype;
  v_t public.enterprise_role_templates%rowtype;
  v_current public.enterprise_role_template_versions%rowtype;
  v_version_id uuid;
  v_version integer;
  v_permissions jsonb;
  v_operation text;
  v_source_template_id uuid;
  v_template_id uuid;
  v_key text;
  v_name text;
begin
  select * into v_m from public.enterprise_role_motions
   where id=p_motion for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.kind<>'template_change' or v_m.status<>'passed' then
    raise exception 'template change motion is not approved';
  end if;
  v_operation:=lower(coalesce(v_m.payload->>'operation','update'));
  v_permissions:=coalesce(v_m.payload->'permissions','[]'::jsonb);
  if jsonb_typeof(v_permissions)<>'array' then
    raise exception 'template permissions payload is invalid';
  end if;

  if v_operation='clone' then
    v_source_template_id:=nullif(v_m.payload->>'source_template_id','')::uuid;
    v_key:=btrim(coalesce(v_m.payload->>'template_key',''));
    v_name:=btrim(coalesce(v_m.payload->>'name',''));
    if v_source_template_id is null or v_key='' or v_name='' then
      raise exception 'clone template payload is invalid';
    end if;
    perform 1 from public.enterprise_role_templates
     where id=v_source_template_id
       and enterprise_id=v_m.enterprise_id
       and archived_at is null
     for update;
    if not found then raise exception 'source template not found'; end if;
    if exists(
      select 1 from public.enterprise_role_templates
       where enterprise_id=v_m.enterprise_id and key=v_key
    ) then
      raise exception 'template key already exists';
    end if;

    insert into public.enterprise_role_templates(
      enterprise_id,key,name,office_key,is_system
    ) values(v_m.enterprise_id,v_key,v_name,'',false)
    returning id into v_template_id;

    insert into public.enterprise_role_template_versions(
      template_id,version,status,created_by,effective_at
    ) values(v_template_id,1,'active',v_m.proposer_profile_id,now())
    returning id into v_version_id;

    insert into public.enterprise_role_template_permissions(
      template_version_id,permission_key,resource,action,scope,conditions,high_risk
    )
    select v_version_id,btrim(coalesce(value->>'permission_key',value->>'key','')),
      coalesce(nullif(btrim(coalesce(value->>'resource','')),''),
        split_part(btrim(coalesce(value->>'permission_key',value->>'key','')),'.',1)),
      coalesce(nullif(btrim(coalesce(value->>'action','')),''),
        case when strpos(btrim(coalesce(value->>'permission_key',value->>'key','')),'.')>0
          then substr(btrim(coalesce(value->>'permission_key',value->>'key','')),strpos(btrim(coalesce(value->>'permission_key',value->>'key','')),'.')+1)
          else btrim(coalesce(value->>'permission_key',value->>'key','')) end),
      coalesce(nullif(btrim(coalesce(value->>'scope','')),''),'self'),
      coalesce(value->'conditions','{}'::jsonb),
      coalesce((value->>'high_risk')::boolean,
        btrim(coalesce(value->>'permission_key',value->>'key','')) in (
          'identity.manage_templates','identity.manage_shares',
          'governance.vote','governance.manage','finance.manage',
          'finance.approve_company','data.export_all','data.delete_all',
          'company.delete'
        ))
    from jsonb_array_elements(v_permissions) value
    where btrim(coalesce(value->>'permission_key',value->>'key',''))<>'';

    insert into public.enterprise_identity_audit(
      enterprise_id,actor_profile_id,action,target_profile_id,details
    ) values(
      v_m.enterprise_id,v_m.proposer_profile_id,'role_template.clone_applied',null,
      jsonb_build_object(
        'motion_id',v_m.id,
        'source_template_id',v_source_template_id,
        'template_id',v_template_id,
        'key',v_key,
        'name',v_name,
        'version',1
      )
    );
    return;
  elsif v_operation<>'update' then
    raise exception 'template change operation is invalid';
  end if;

  v_template_id:=nullif(v_m.payload->>'template_id','')::uuid;
  if v_template_id is null then raise exception 'template id is required'; end if;
  select * into v_t from public.enterprise_role_templates
   where id=v_template_id and enterprise_id=v_m.enterprise_id
   for update;
  if not found then raise exception 'role template not found'; end if;
  select * into v_current from public.enterprise_role_template_versions
   where template_id=v_t.id and status='active'
   order by version desc limit 1 for update;
  if not found then raise exception 'role template has no active version'; end if;

  update public.enterprise_role_template_versions
     set status='retired'
   where id=v_current.id;
  v_version:=v_current.version+1;
  insert into public.enterprise_role_template_versions(
    template_id,version,status,created_by,effective_at
  ) values(v_t.id,v_version,'active',v_m.proposer_profile_id,now())
  returning id into v_version_id;

  insert into public.enterprise_role_template_permissions(
    template_version_id,permission_key,resource,action,scope,conditions,high_risk
  )
  select v_version_id,btrim(coalesce(value->>'permission_key',value->>'key','')),
    coalesce(nullif(btrim(coalesce(value->>'resource','')),''),
      split_part(btrim(coalesce(value->>'permission_key',value->>'key','')),'.',1)),
    coalesce(nullif(btrim(coalesce(value->>'action','')),''),
      case when strpos(btrim(coalesce(value->>'permission_key',value->>'key','')),'.')>0
        then substr(btrim(coalesce(value->>'permission_key',value->>'key','')),strpos(btrim(coalesce(value->>'permission_key',value->>'key','')),'.')+1)
        else btrim(coalesce(value->>'permission_key',value->>'key','')) end),
    coalesce(nullif(btrim(coalesce(value->>'scope','')),''),'self'),
    coalesce(value->'conditions','{}'::jsonb),
    coalesce((value->>'high_risk')::boolean,
      btrim(coalesce(value->>'permission_key',value->>'key','')) in (
        'identity.manage_templates','identity.manage_shares',
        'governance.vote','governance.manage','finance.manage',
        'finance.approve_company','data.export_all','data.delete_all',
        'company.delete'
      ))
  from jsonb_array_elements(v_permissions) value
  where btrim(coalesce(value->>'permission_key',value->>'key',''))<>'';

  update public.enterprise_role_templates
     set name=coalesce(nullif(btrim(v_m.payload->>'name'),''),name)
   where id=v_t.id;
end;
$fn$;

drop function if exists public.set_member_role_assignment(uuid,uuid,timestamptz,text);

create or replace function public.set_member_role_assignment(
  p_profile uuid,
  p_template uuid,
  p_ends_at timestamptz,
  p_reason text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_owner uuid;
  v_is_owner boolean:=false;
  v_is_ceo boolean:=false;
  v_template_id uuid;
  v_template_version_id uuid;
  v_office_key text;
  v_assignment_id uuid;
  v_template_permissions jsonb:='[]'::jsonb;
  v_high_risk boolean:=false;
  v_governance_sensitive boolean:=false;
  v_reason text:=btrim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));

  perform 1 from public.enterprises where id=v_eid for update;
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;
  v_is_owner:=v_owner=v_uid;
  v_is_ceo:=exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=v_eid and m.profile_id=v_uid
       and m.status='active' and m.role_key='ceo'
    union all
    select 1 from public.enterprise_role_assignments a
     where a.enterprise_id=v_eid and a.profile_id=v_uid
       and a.status='active' and a.starts_at<=now()
       and (a.ends_at is null or a.ends_at>now())
       and a.office_key='ceo'
  );

  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if not (public._identity_role_permissions(v_eid,v_uid) ? 'identity.manage_templates') then
    raise exception 'identity template management permission required';
  end if;
  if not (v_is_owner or v_is_ceo) then
    raise exception 'only the CEO or enterprise owner may set temporary assignments';
  end if;

  if p_profile=auth.uid() then
    raise exception 'cannot assign a role to yourself';
  end if;
  if v_reason='' then
    raise exception 'temporary assignment reason is required';
  end if;
  if p_ends_at is null then
    raise exception 'secondary assignments must expire';
  end if;
  if p_ends_at<=now() then
    raise exception 'assignment end must be in the future';
  end if;
  if p_ends_at>now()+interval '7 days' then
    raise exception 'temporary assignment cannot exceed 7 days';
  end if;

  if not exists (
    select 1 from public.enterprise_members m
     where m.enterprise_id=v_eid and m.profile_id=p_profile
       and m.status='active'
  ) then
    raise exception 'profile is not an active enterprise member';
  end if;

  select t.id,t.office_key into v_template_id,v_office_key
    from public.enterprise_role_templates t
   where t.id=p_template and t.enterprise_id=v_eid
     and t.archived_at is null
   for update;
  if not found then raise exception 'role template not found'; end if;

  select v.id into v_template_version_id
    from public.enterprise_role_template_versions v
   where v.template_id=v_template_id and v.status='active'
   order by v.version desc limit 1 for share;
  if v_template_version_id is null then
    raise exception 'role template has no active version';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'permission_key',p.permission_key,'resource',p.resource,
    'action',p.action,'scope',p.scope,'conditions',p.conditions,
    'high_risk',p.high_risk
  ) order by p.permission_key),'[]'::jsonb)
  into v_template_permissions
  from public.enterprise_role_template_permissions p
  where p.template_version_id=v_template_version_id;

  select exists (
    select 1 from public.enterprise_role_template_permissions p
     where p.template_version_id=v_template_version_id and p.high_risk
  ) into v_high_risk;
  v_governance_sensitive:=v_office_key<>'' or v_high_risk;

  if v_governance_sensitive and (
    exists(select 1 from public.enterprise_role_motions
            where enterprise_id=v_eid and status='open')
    or exists(select 1 from public.enterprise_board_motions
              where enterprise_id=v_eid and status='open')
  ) then
    raise exception 'cannot change voting-sensitive composition while a motion is open';
  end if;

  if v_high_risk then
    raise exception 'template contains high-risk permissions';
  end if;
  if not v_is_owner and not public._identity_permissions_are_grantable(
    v_eid,v_uid,v_template_permissions
  ) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  select a.id into v_assignment_id
    from public.enterprise_role_assignments a
    join public.enterprise_role_template_versions av
      on av.id=a.template_version_id
   where a.enterprise_id=v_eid and a.profile_id=p_profile
     and av.template_id=v_template_id and a.status='active'
     and a.is_primary=false
   order by a.created_at desc limit 1 for update of a;

  if v_assignment_id is null then
    insert into public.enterprise_role_assignments(
      enterprise_id,profile_id,template_version_id,office_key,is_primary,
      status,starts_at,ends_at,appointed_by
    ) values(
      v_eid,p_profile,v_template_version_id,v_office_key,false,
      'active',now(),p_ends_at,v_uid
    ) returning id into v_assignment_id;
  else
    update public.enterprise_role_assignments
       set template_version_id=v_template_version_id,
           office_key=v_office_key,is_primary=false,status='active',
           starts_at=now(),ends_at=p_ends_at,appointed_by=v_uid
     where id=v_assignment_id;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'role_assignment.set',p_profile,
    jsonb_build_object(
      'assignment_id',v_assignment_id,'template_id',v_template_id,
      'template_version_id',v_template_version_id,'office_key',v_office_key,
      'starts_at',now(),'ends_at',p_ends_at,'reason',v_reason
    )
  );

  return jsonb_build_object(
    'ok',true,'assignment_id',v_assignment_id,'enterprise_id',v_eid,
    'profile_id',p_profile,'template_id',v_template_id,
    'template_version_id',v_template_version_id,'office_key',v_office_key,
    'ends_at',p_ends_at,'reason',v_reason
  );
end;
$fn$;

revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from public;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from anon;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) from authenticated;
grant execute on function public.set_member_role_assignment(uuid,uuid,timestamptz,text) to authenticated;

create or replace function public.get_enterprise_identity_state()
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_total numeric:=0;
  v_permissions jsonb:='[]'::jsonb;
  v_is_owner boolean:=false;
  v_is_shareholder boolean:=false;
  v_is_board boolean:=false;
  v_is_auditor boolean:=false;
  v_is_governance boolean:=false;
  v_is_chairperson boolean:=false;
  v_is_ceo boolean:=false;
  v_can_read_governance boolean:=false;
  v_advanced boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;

  v_permissions:=public._identity_role_permissions(v_eid,v_uid);
  v_total:=public._identity_total_shares(v_eid);
  v_is_shareholder:=public._identity_shares(v_eid,v_uid)>0;
  v_is_board:=public._identity_is_board_director(v_eid,v_uid);
  v_is_auditor:=v_permissions ? 'audit.read';
  v_is_governance:=v_permissions ? 'governance.manage'
    or v_permissions ? 'governance.vote'
    or v_permissions ? 'identity.manage_templates'
    or v_permissions ? 'identity.manage_shares';
  v_is_chairperson:=public._identity_is_chairperson(v_eid,v_uid);
  select e.owner_profile_id=v_uid into v_is_owner
    from public.enterprises e where e.id=v_eid;
  v_is_ceo:=exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=v_eid and m.profile_id=v_uid
       and m.status='active' and m.role_key='ceo'
    union all
    select 1 from public.enterprise_role_assignments a
     where a.enterprise_id=v_eid and a.profile_id=v_uid
       and a.status='active' and a.starts_at<=now()
       and (a.ends_at is null or a.ends_at>now())
       and a.office_key='ceo'
  );
  v_can_read_governance:=v_is_shareholder or v_is_board
    or v_is_auditor or v_is_governance;
  v_advanced:=public._identity_can_use_advanced_mode(v_eid,v_uid);

  return jsonb_build_object(
    'enterprise',(
      select jsonb_build_object(
        'id',e.id,'name',e.name
      ) || case when v_can_read_governance then jsonb_build_object(
        'owner_profile_id',e.owner_profile_id,
        'quorum_bps',e.quorum_bps,'approval_bps',e.approval_bps
      ) else '{}'::jsonb end
      from public.enterprises e where e.id=v_eid
    ),
    'me',(
      select jsonb_build_object(
        'profile_id',m.profile_id,'name',p.name,'code',p.code,
        'role_key',m.role_key,'role_name',r.name,
        'department',m.department,'title',m.title,
        'is_owner',v_is_owner,
        'is_ceo',v_is_ceo,
        'is_chairperson',v_is_chairperson,
        'is_board_director',v_is_board,
        'can_manage_assignments',v_is_owner or v_is_ceo,
        'preferred_mode',case
          when m.preferred_mode='advanced' and not v_advanced then 'simple'
          else m.preferred_mode
        end,
        'permissions',v_permissions
      )
      || case when v_can_read_governance then jsonb_build_object(
        'is_shareholder',v_is_shareholder,
        'shares',coalesce((
          select s.shares from public.enterprise_shareholders s
           where s.enterprise_id=v_eid and s.profile_id=v_uid
        ),0),
        'share_percent',case when v_total>0 then round(coalesce((
          select s.shares from public.enterprise_shareholders s
           where s.enterprise_id=v_eid and s.profile_id=v_uid
        ),0)/v_total*100,2) else 0 end
      ) else '{}'::jsonb end
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      join public.enterprise_role_catalog r on r.key=m.role_key
      where m.enterprise_id=v_eid and m.profile_id=v_uid
    ),
    'point_state',public.get_point_state(),
    'roles',case when v_can_read_governance then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'key',r.key,'name',r.name,'description',r.description,
        'permissions',r.permissions,'rank',r.rank
      ) order by r.rank desc),'[]'::jsonb)
      from public.enterprise_role_catalog r
    ) else '[]'::jsonb end,
    'members',case when v_can_read_governance then (
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
    ) else '[]'::jsonb end,
    'motions',case when v_can_read_governance then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',x.id,'kind',x.kind,'status',x.status,
        'target_profile_id',x.target_profile_id,'target_name',tp.name,
        'proposed_role_key',x.proposed_role_key,
        'proposed_role_name',coalesce(rr.name,''),
        'proposed_department',x.proposed_department,
        'proposed_title',x.proposed_title,'reason',x.reason,
        'proposer_profile_id',x.proposer_profile_id,'proposer_name',pp.name,
        'quorum_bps',x.quorum_bps,'approval_bps',x.approval_bps,
        'motion_class',x.motion_class,'required_bps',x.required_bps,
        'conflict_disclosed',x.conflict_disclosed,'payload',x.payload,
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
          x.status='open' and v_is_shareholder and now()<x.closes_at
          and (x.share_snapshot ? v_uid::text)
        ),
        'decision_reason',x.decision_reason,'decided_at',x.decided_at,
        'created_at',x.created_at
      )),'[]'::jsonb)
      from public.enterprise_role_motions x
      left join public.profiles tp on tp.id=x.target_profile_id
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
    ) else '[]'::jsonb end,
    'board_motions',case when v_can_read_governance then (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',bm.id,'title',bm.title,'kind',bm.kind,'status',bm.status,
        'payload',bm.payload,'conflict_disclosed',bm.conflict_disclosed,
        'proposer_profile_id',bm.proposer_profile_id,
        'proposer_name',pp.name,'created_at',bm.created_at,
        'decided_at',bm.decided_at,
        'cast_count',coalesce(v.cast_count,0),
        'yes_count',coalesce(v.yes_count,0),
        'no_count',coalesce(v.no_count,0),
        'abstain_count',coalesce(v.abstain_count,0),
        'my_choice',coalesce((
          select bv.choice from public.enterprise_board_votes bv
           where bv.motion_id=bm.id and bv.director_profile_id=v_uid
        ),''),
        'can_vote',bm.status='open' and v_is_board,
        'can_finalize',bm.status='open' and v_is_board
      )),'[]'::jsonb)
      from public.enterprise_board_motions bm
      join public.profiles pp on pp.id=bm.proposer_profile_id
      left join lateral (
        select
          count(*) as cast_count,
          count(*) filter(where choice='yes') as yes_count,
          count(*) filter(where choice='no') as no_count,
          count(*) filter(where choice='abstain') as abstain_count
        from public.enterprise_board_votes z where z.motion_id=bm.id
      ) v on true
      where bm.enterprise_id=v_eid
    ) else '[]'::jsonb end
  );
end;
$fn$;

revoke all on function public.get_enterprise_identity_state() from public;
revoke all on function public.get_enterprise_identity_state() from anon;
revoke all on function public.get_enterprise_identity_state() from authenticated;
grant execute on function public.get_enterprise_identity_state() to authenticated;

drop function if exists public.post_community_message(text,text);

create or replace function public.post_community_message(
  p_content text,
  p_topic text default 'share',
  p_unlock_cost integer default 0,
  p_is_required boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_name text;
  v_role text;
  v_topic text:=lower(trim(coalesce(p_topic,'share')));
  v_content text:=trim(coalesce(p_content,''));
  v_cost integer:=greatest(coalesce(p_unlock_cost,0),0);
  v_required boolean:=coalesce(p_is_required,false);
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select name,role into v_name,v_role
    from public.profiles
   where id=v_uid and coalesce(active,true)=true;
  if v_name is null then raise exception 'profile not found'; end if;
  if char_length(v_content)<1 then raise exception 'message is empty'; end if;
  if char_length(v_content)>2000 then raise exception 'message is too long'; end if;
  if char_length(v_topic)<1 or char_length(v_topic)>24 then
    v_topic:='share';
  end if;
  insert into public.community_posts(
    author_id,author_name,author_role,topic,content,
    unlock_cost,is_required
  ) values(
    v_uid,v_name,coalesce(v_role,'employee'),v_topic,v_content,
    v_cost,v_required
  ) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;

create or replace function public.list_knowledge_posts(p_limit integer default 80)
returns jsonb
language plpgsql
stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_limit integer:=least(greatest(coalesce(p_limit,80),1),100);
  v_result jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select e.id into v_eid
    from public.enterprises e
   where e.owner_profile_id=public._identity_owner_for_uid(v_uid)
   limit 1;
  if v_eid is null then
    select m.enterprise_id into v_eid
      from public.enterprise_members m
     where m.profile_id=v_uid and m.status='active'
     order by m.updated_at desc
     limit 1;
  end if;
  if v_eid is null or not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select coalesce(jsonb_agg(item order by created_at desc),'[]'::jsonb)
    into v_result
    from (
      select p.created_at,jsonb_build_object(
        'id',p.id,'author_id',p.author_id,'author_name',p.author_name,
        'author_role',p.author_role,'topic',p.topic,
        'content',case
          when p.author_id=v_uid or p.is_required or p.unlock_cost=0
            or exists(select 1 from public.enterprise_knowledge_unlocks u
                       where u.profile_id=v_uid and u.post_id=p.id)
          then p.content else '' end,
        'preview',left(p.content,180),
        'unlock_cost',p.unlock_cost,'is_required',p.is_required,
        'locked',not (
          p.author_id=v_uid or p.is_required or p.unlock_cost=0
          or exists(select 1 from public.enterprise_knowledge_unlocks u
                     where u.profile_id=v_uid and u.post_id=p.id)
        ),
        'created_at',p.created_at
      ) item
      from public.community_posts p
      order by p.created_at desc
      limit v_limit
    ) posts;
  return v_result;
end;
$fn$;

revoke all on function public.post_community_message(text,text,integer,boolean) from public;
revoke all on function public.post_community_message(text,text,integer,boolean) from anon;
revoke all on function public.post_community_message(text,text,integer,boolean) from authenticated;
grant execute on function public.post_community_message(text,text,integer,boolean) to authenticated;

revoke all on function public.list_knowledge_posts(integer) from public;
revoke all on function public.list_knowledge_posts(integer) from anon;
revoke all on function public.list_knowledge_posts(integer) from authenticated;
grant execute on function public.list_knowledge_posts(integer) to authenticated;

-- Internal helpers remain non-callable through REST.
revoke all on function public._identity_create_shareholder_motion(uuid,uuid,text,uuid,text,text,text,text,jsonb,text,integer,boolean) from public;
revoke all on function public._identity_create_shareholder_motion(uuid,uuid,text,uuid,text,text,text,text,jsonb,text,integer,boolean) from anon;
revoke all on function public._identity_create_shareholder_motion(uuid,uuid,text,uuid,text,text,text,text,jsonb,text,integer,boolean) from authenticated;

revoke all on function public._identity_apply_template_change_motion(uuid) from public;
revoke all on function public._identity_apply_template_change_motion(uuid) from anon;
revoke all on function public._identity_apply_template_change_motion(uuid) from authenticated;

revoke all on function public._identity_can_use_advanced_mode(uuid,uuid) from public;
revoke all on function public._identity_can_use_advanced_mode(uuid,uuid) from anon;
revoke all on function public._identity_can_use_advanced_mode(uuid,uuid) from authenticated;

revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from public;
revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from anon;
revoke all on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) from authenticated;
grant execute on function public.propose_enterprise_role(uuid,text,text,text,text,text,integer,boolean) to authenticated;

revoke all on function public.propose_enterprise_share_change(uuid,numeric,text,integer,boolean) from public;
revoke all on function public.propose_enterprise_share_change(uuid,numeric,text,integer,boolean) from anon;
revoke all on function public.propose_enterprise_share_change(uuid,numeric,text,integer,boolean) from authenticated;
grant execute on function public.propose_enterprise_share_change(uuid,numeric,text,integer,boolean) to authenticated;

revoke all on function public.propose_template_change(uuid,text,jsonb,text,integer,boolean) from public;
revoke all on function public.propose_template_change(uuid,text,jsonb,text,integer,boolean) from anon;
revoke all on function public.propose_template_change(uuid,text,jsonb,text,integer,boolean) from authenticated;
grant execute on function public.propose_template_change(uuid,text,jsonb,text,integer,boolean) to authenticated;

-- Direct share mutation is bootstrap/internal only. Clients must use a
-- major shareholder motion and finalization applies it transactionally.
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from public;
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from anon;
revoke all on function public.set_enterprise_shareholder(uuid,numeric) from authenticated;
