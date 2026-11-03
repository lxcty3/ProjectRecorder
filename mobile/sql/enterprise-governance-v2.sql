-- ============================================================
-- Project Recorder - Enterprise governance v2
--
-- Run this file after enterprise-identity.sql.
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
-- Active assignments contribute permissions from the template's current
-- version. Time bounds are evaluated here so a due assignment stops
-- granting access even before the expiry RPC marks it expired.
create or replace function public._identity_role_permissions(p_eid uuid,p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
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

  v_permissions:=v_permissions||coalesce((
    select jsonb_agg(distinct to_jsonb(p.permission_key))
      from public.enterprise_role_assignments a
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

-- ------------------------------------------------------------ template writes
create or replace function public.clone_role_template(
  p_source uuid,
  p_name text,
  p_key text
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
  v_requested jsonb:='[]'::jsonb;
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

  select t.* into v_source
    from public.enterprise_role_templates t
   where t.id=p_source
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

  select coalesce(jsonb_agg(value->>'permission_key'),'[]'::jsonb)
    into v_requested
    from jsonb_array_elements(v_permissions) value;

  if exists (
    select 1
      from jsonb_array_elements_text(v_requested) requested(key)
     where not (
       public._identity_role_permissions(v_eid,v_uid) ? requested.key
     )
  ) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  if exists (
    select 1
      from jsonb_array_elements(v_permissions) requested(value)
     where coalesce((requested.value->>'high_risk')::boolean,false)
  ) then
    raise exception 'high-risk template changes require a major shareholder motion';
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

create or replace function public.update_role_template(
  p_template uuid,
  p_name text,
  p_permissions jsonb
)
returns jsonb
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
  v_requested jsonb:='[]'::jsonb;
  v_high_risk boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
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

  select coalesce(jsonb_agg(value->>'permission_key'),'[]'::jsonb)
    into v_requested
    from jsonb_array_elements(v_permissions) value;

  if exists (
    select 1
      from jsonb_array_elements_text(v_requested) requested(key)
     where not (
       public._identity_role_permissions(v_eid,auth.uid()) ? requested.key
     )
  ) then
    raise exception 'cannot grant permissions you do not hold';
  end if;

  if v_high_risk then
    raise exception 'high-risk template changes require a major shareholder motion';
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
create or replace function public.set_member_role_assignment(
  p_profile uuid,
  p_template uuid,
  p_ends_at timestamptz
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
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

  if exists (
    select 1
      from public.enterprise_role_template_permissions p
     where p.template_version_id=v_template_version_id
       and p.high_risk
  ) then
    raise exception 'template contains high-risk permissions';
  end if;

  if exists (
    select 1
      from public.enterprise_role_template_permissions p
     where p.template_version_id=v_template_version_id
       and not (
         public._identity_role_permissions(v_eid,v_uid) ? p.permission_key
       )
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

  return jsonb_build_object(
    'ok',true,
    'assignment_id',v_assignment_id,
    'enterprise_id',v_eid,
    'profile_id',p_profile,
    'template_id',v_template_id,
    'template_version_id',v_template_version_id,
    'office_key',v_office_key,
    'ends_at',p_ends_at
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

  update public.enterprise_role_assignments
     set status='expired'
   where enterprise_id=v_eid
     and status='active'
     and ends_at is not null
     and ends_at <= now();

  get diagnostics v_expired=row_count;
  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'expired_count',v_expired
  );
end;
$fn$;

-- ------------------------------------------------------------ template RPC grants
revoke all on function public._identity_role_permissions(uuid,uuid) from public;
revoke all on function public._identity_role_permissions(uuid,uuid) from anon;
revoke all on function public._identity_role_permissions(uuid,uuid) from authenticated;

revoke all on function public.clone_role_template(uuid,text,text) from public;
revoke all on function public.clone_role_template(uuid,text,text) from anon;
revoke all on function public.clone_role_template(uuid,text,text) from authenticated;
grant execute on function public.clone_role_template(uuid,text,text) to authenticated;

revoke all on function public.update_role_template(uuid,text,jsonb) from public;
revoke all on function public.update_role_template(uuid,text,jsonb) from anon;
revoke all on function public.update_role_template(uuid,text,jsonb) from authenticated;
grant execute on function public.update_role_template(uuid,text,jsonb) to authenticated;

revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz) from public;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz) from anon;
revoke all on function public.set_member_role_assignment(uuid,uuid,timestamptz) from authenticated;
grant execute on function public.set_member_role_assignment(uuid,uuid,timestamptz) to authenticated;

revoke all on function public.expire_role_assignments() from public;
revoke all on function public.expire_role_assignments() from anon;
revoke all on function public.expire_role_assignments() from authenticated;
grant execute on function public.expire_role_assignments() to authenticated;
