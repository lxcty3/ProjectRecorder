-- ============================================================
-- Custom career roles v1
--
-- Enterprise owners/HR can create their own career roles and map
-- each to one of the five career levels. Assigning a custom role
-- sets the member's career_level to the role's level.
--
-- Additive and idempotent. ASCII-only.
-- ============================================================

create table if not exists public.enterprise_career_roles (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  name text not null,
  level integer not null
    references public.enterprise_career_levels(level) on delete restrict,
  description text not null default '',
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists career_roles_name_idx
  on public.enterprise_career_roles(enterprise_id, lower(name))
  where active;

alter table public.enterprise_members
  add column if not exists career_role_id uuid
    references public.enterprise_career_roles(id) on delete set null;

alter table public.enterprise_career_roles enable row level security;
revoke all on public.enterprise_career_roles from public, anon, authenticated;

create or replace function public.list_career_roles()
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'name', r.name,
    'level', r.level,
    'description', r.description,
    'active', r.active,
    'assigned_members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'profile_id', m.profile_id,
        'name', p.name
      ) order by p.name)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.career_role_id=r.id and m.status='active'
    ), '[]'::jsonb)
  ) order by r.level, r.name), '[]'::jsonb)
    into v_rows
    from public.enterprise_career_roles r
   where r.enterprise_id=v_eid and r.active=true;
  return jsonb_build_object('ok', true, 'roles', v_rows);
end;
$fn$;

revoke all on function public.list_career_roles()
  from public, anon, authenticated;
grant execute on function public.list_career_roles()
  to authenticated;

create or replace function public.create_career_role(
  p_name text,
  p_level integer,
  p_description text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_name text := trim(coalesce(p_name,''));
  v_desc text := trim(coalesce(p_description,''));
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._career_level_can_manage(v_eid, v_uid) then
    raise exception 'not allowed to manage career roles';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'career role name must be 2 to 40 characters';
  end if;
  if p_level is null or p_level < 1 or p_level > 5 then
    raise exception 'level must be 1 to 5';
  end if;
  insert into public.enterprise_career_roles(
    enterprise_id, name, level, description, created_by
  ) values (
    v_eid, v_name, p_level, left(v_desc,500), v_uid
  ) returning id into v_id;
  return jsonb_build_object('ok', true, 'role_id', v_id);
exception when unique_violation then
  raise exception 'a career role with this name already exists';
end;
$fn$;

revoke all on function public.create_career_role(text,integer,text)
  from public, anon, authenticated;
grant execute on function public.create_career_role(text,integer,text)
  to authenticated;

create or replace function public.assign_career_role(
  p_profile uuid,
  p_role uuid
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_role public.enterprise_career_roles%rowtype;
  v_from integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._career_level_can_manage(v_eid, v_uid) then
    raise exception 'not allowed to assign career roles';
  end if;
  select * into v_role from public.enterprise_career_roles
   where id=p_role and enterprise_id=v_eid and active=true;
  if not found then raise exception 'career role not found'; end if;
  select career_level into v_from from public.enterprise_members
   where enterprise_id=v_eid and profile_id=p_profile and status='active';
  if v_from is null then raise exception 'member not found'; end if;
  update public.enterprise_members
     set career_role_id=v_role.id, career_level=v_role.level, updated_at=now()
   where enterprise_id=v_eid and profile_id=p_profile;
  if v_from <> v_role.level then
    insert into public.enterprise_career_level_history(
      enterprise_id, profile_id, from_level, to_level, reason, changed_by, approved_by
    ) values (
      v_eid, p_profile, v_from, v_role.level,
      'assigned career role: ' || v_role.name, v_uid, v_uid
    );
  end if;
  return jsonb_build_object('ok', true, 'level', v_role.level);
end;
$fn$;

revoke all on function public.assign_career_role(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.assign_career_role(uuid,uuid)
  to authenticated;

insert into public.app_migrations(version,name,notes)
values (
  'career-custom-roles-v1',
  'Custom career roles',
  'Enterprise owners/HR can create career roles and map them to L1-L5'
)
on conflict (version) do update set notes=excluded.notes;
