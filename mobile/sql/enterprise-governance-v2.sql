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
grant execute on function public.provision_default_role_templates(uuid) to authenticated;

revoke all on function public.get_enterprise_role_templates() from public;
revoke all on function public.get_enterprise_role_templates() from anon;
grant execute on function public.get_enterprise_role_templates() to authenticated;
