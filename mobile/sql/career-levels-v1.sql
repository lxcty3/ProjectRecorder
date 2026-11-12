-- ============================================================
-- Career levels v1
--
-- Five personal levels. Each level maps to a fixed set of roles.
-- A person's level is independent, but appointment requires
-- person.career_level >= role.level.
--
-- Promotion: owner/HR proposes, owner/board approves.
-- Additive and idempotent. ASCII-only.
-- ============================================================

alter table public.enterprise_members
  add column if not exists career_level integer not null default 1;

do $do$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid='public.enterprise_members'::regclass
       and conname='enterprise_members_career_level_check'
  ) then
    alter table public.enterprise_members
      add constraint enterprise_members_career_level_check
      check (career_level between 1 and 5);
  end if;
end;
$do$;

create table if not exists public.enterprise_career_levels (
  level integer primary key check (level between 1 and 5),
  name text not null,
  description text not null default ''
);

insert into public.enterprise_career_levels(level,name,description) values
  (1,'L1 Junior','Entry level, executes assigned work'),
  (2,'L2 Intermediate','Independent contributor or team lead'),
  (3,'L3 Senior','Owns projects, people or a department'),
  (4,'L4 Principal','Senior management or specialist'),
  (5,'L5 Expert / Governance','Executive and governance roles')
on conflict (level) do update set
  name=excluded.name, description=excluded.description;

create table if not exists public.enterprise_career_role_levels (
  role_key text primary key
    references public.enterprise_role_catalog(key) on delete cascade,
  level integer not null
    references public.enterprise_career_levels(level) on delete cascade
);

insert into public.enterprise_career_role_levels(role_key,level) values
  ('employee',1),
  ('team_lead',2),('finance',2),('hr',2),('auditor',2),
  ('project_manager',3),('department_manager',3),
  ('vice_president',4),('identity_admin',4),
  ('ceo',5),('director',5),('supervisor',5),('chairperson',5)
on conflict (role_key) do update set level=excluded.level;

-- Existing members inherit their current role's level.
update public.enterprise_members m
   set career_level = coalesce((
     select r.level from public.enterprise_career_role_levels r
      where r.role_key = m.role_key
   ), 1)
 where m.career_level is null or m.career_level = 1;

create table if not exists public.enterprise_career_level_history (
  id bigserial primary key,
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  profile_id uuid not null
    references public.profiles(id) on delete cascade,
  from_level integer,
  to_level integer not null,
  reason text not null default '',
  changed_by uuid references public.profiles(id) on delete set null,
  approved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists career_history_profile_idx
  on public.enterprise_career_level_history(enterprise_id, profile_id, created_at desc);

create table if not exists public.enterprise_career_level_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  profile_id uuid not null
    references public.profiles(id) on delete cascade,
  requested_level integer not null
    check (requested_level between 1 and 5),
  reason text not null default '',
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','cancelled')),
  requested_by uuid not null
    references public.profiles(id) on delete cascade,
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  decision_reason text not null default '',
  created_at timestamptz not null default now()
);

create unique index if not exists career_requests_one_pending_idx
  on public.enterprise_career_level_requests(enterprise_id, profile_id)
  where status='pending';

alter table public.enterprise_career_levels enable row level security;
alter table public.enterprise_career_role_levels enable row level security;
alter table public.enterprise_career_level_history enable row level security;
alter table public.enterprise_career_level_requests enable row level security;

revoke all on public.enterprise_career_levels from public, anon, authenticated;
revoke all on public.enterprise_career_role_levels from public, anon, authenticated;
revoke all on public.enterprise_career_level_history from public, anon, authenticated;
revoke all on public.enterprise_career_level_requests from public, anon, authenticated;

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------

create or replace function public._career_level_can_manage(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_perms jsonb;
  v_owner uuid;
begin
  if not public._identity_is_member(p_eid, p_uid) then return false; end if;
  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  v_perms := public._identity_role_permissions(p_eid, p_uid);
  return p_uid = v_owner
    or v_perms ? 'people.manage'
    or (select role_key from public.enterprise_members
         where enterprise_id=p_eid and profile_id=p_uid and status='active') = 'hr';
end;
$fn$;

create or replace function public._career_level_can_approve(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_perms jsonb;
  v_owner uuid;
  v_role text;
begin
  if not public._identity_is_member(p_eid, p_uid) then return false; end if;
  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  select role_key into v_role from public.enterprise_members
   where enterprise_id=p_eid and profile_id=p_uid and status='active';
  v_perms := public._identity_role_permissions(p_eid, p_uid);
  return p_uid = v_owner
    or v_role in ('chairperson','director')
    or v_perms ? 'governance.manage'
    or public._identity_is_board_director(p_eid, p_uid);
end;
$fn$;

revoke all on function public._career_level_can_manage(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._career_level_can_approve(uuid,uuid)
  from public, anon, authenticated;

-- Appointment must respect the role's level.
create or replace function public._career_level_check_role_motion()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_member_level integer;
  v_role_level integer;
begin
  if NEW.kind <> 'appointment' or NEW.proposed_role_key is null then
    return NEW;
  end if;
  select coalesce(m.career_level,1) into v_member_level
    from public.enterprise_members m
   where m.enterprise_id=NEW.enterprise_id
     and m.profile_id=NEW.target_profile_id;
  select coalesce(r.level,1) into v_role_level
    from public.enterprise_career_role_levels r
   where r.role_key=NEW.proposed_role_key;
  if v_member_level < v_role_level then
    raise exception 'career level too low for this role';
  end if;
  return NEW;
end;
$fn$;

drop trigger if exists trg_career_level_role_motion on public.enterprise_role_motions;
create trigger trg_career_level_role_motion
before insert on public.enterprise_role_motions
for each row execute function public._career_level_check_role_motion();

-- ------------------------------------------------------------
-- State
-- ------------------------------------------------------------

create or replace function public.get_career_level_state()
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_my_level integer := 1;
  v_my_role text := 'employee';
  v_my_role_level integer := 1;
  v_can_manage boolean := false;
  v_can_approve boolean := false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select coalesce(m.career_level,1), m.role_key,
         coalesce(r.level,1)
    into v_my_level, v_my_role, v_my_role_level
    from public.enterprise_members m
    left join public.enterprise_career_role_levels r on r.role_key=m.role_key
   where m.enterprise_id=v_eid and m.profile_id=v_uid and m.status='active';
  v_can_manage := public._career_level_can_manage(v_eid, v_uid);
  v_can_approve := public._career_level_can_approve(v_eid, v_uid);

  return jsonb_build_object(
    'ok', true,
    'me', jsonb_build_object(
      'profile_id', v_uid,
      'career_level', v_my_level,
      'role_key', v_my_role,
      'role_level', v_my_role_level,
      'can_manage', v_can_manage,
      'can_approve', v_can_approve
    ),
    'levels', coalesce((
      select jsonb_agg(jsonb_build_object(
        'level', l.level, 'name', l.name, 'description', l.description
      ) order by l.level)
      from public.enterprise_career_levels l
    ), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'role_key', r.role_key, 'role_name', c.name, 'level', r.level
      ) order by r.level, c.rank desc)
      from public.enterprise_career_role_levels r
      join public.enterprise_role_catalog c on c.key=r.role_key
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'profile_id', m.profile_id,
        'name', p.name,
        'role_key', m.role_key,
        'role_name', c.name,
        'career_level', m.career_level,
        'role_level', coalesce(r.level,1),
        'shares', coalesce(s.shares,0)
      ) order by m.career_level desc, c.rank desc, p.name)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      join public.enterprise_role_catalog c on c.key=m.role_key
      left join public.enterprise_career_role_levels r on r.role_key=m.role_key
      left join public.enterprise_shareholders s
        on s.enterprise_id=m.enterprise_id and s.profile_id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id,
        'profile_id', q.profile_id,
        'name', p.name,
        'requested_level', q.requested_level,
        'current_level', m.career_level,
        'reason', q.reason,
        'status', q.status,
        'requested_by', q.requested_by,
        'requester_name', rp.name,
        'created_at', q.created_at
      ) order by q.created_at desc)
      from public.enterprise_career_level_requests q
      join public.profiles p on p.id=q.profile_id
      join public.profiles rp on rp.id=q.requested_by
      join public.enterprise_members m
        on m.enterprise_id=q.enterprise_id and m.profile_id=q.profile_id
      where q.enterprise_id=v_eid and q.status='pending'
    ), '[]'::jsonb)
  );
end;
$fn$;

revoke all on function public.get_career_level_state()
  from public, anon, authenticated;
grant execute on function public.get_career_level_state()
  to authenticated;

-- ------------------------------------------------------------
-- Promotion requests
-- ------------------------------------------------------------

create or replace function public.request_career_level_change(
  p_profile uuid,
  p_level integer,
  p_reason text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_current integer;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._career_level_can_manage(v_eid, v_uid) then
    raise exception 'not allowed to manage career levels';
  end if;
  if p_level is null or p_level < 1 or p_level > 5 then
    raise exception 'level must be 1 to 5';
  end if;
  select career_level into v_current
    from public.enterprise_members
   where enterprise_id=v_eid and profile_id=p_profile and status='active';
  if v_current is null then raise exception 'member not found'; end if;
  if v_current = p_level then raise exception 'level is unchanged'; end if;
  insert into public.enterprise_career_level_requests(
    enterprise_id, profile_id, requested_level, reason, requested_by
  ) values (
    v_eid, p_profile, p_level, left(coalesce(p_reason,''),1000), v_uid
  ) returning id into v_id;
  return jsonb_build_object('ok', true, 'request_id', v_id);
exception when unique_violation then
  raise exception 'this member already has a pending career level request';
end;
$fn$;

revoke all on function public.request_career_level_change(uuid,integer,text)
  from public, anon, authenticated;
grant execute on function public.request_career_level_change(uuid,integer,text)
  to authenticated;

create or replace function public.decide_career_level_request(
  p_request uuid,
  p_approve boolean,
  p_reason text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_row public.enterprise_career_level_requests%rowtype;
  v_from integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._career_level_can_approve(v_eid, v_uid) then
    raise exception 'not allowed to approve career levels';
  end if;
  select * into v_row from public.enterprise_career_level_requests
   where id=p_request and enterprise_id=v_eid for update;
  if not found then raise exception 'request not found'; end if;
  if v_row.status <> 'pending' then raise exception 'request is not pending'; end if;
  select career_level into v_from from public.enterprise_members
   where enterprise_id=v_eid and profile_id=v_row.profile_id;
  if coalesce(p_approve,false) then
    update public.enterprise_members
       set career_level=v_row.requested_level, updated_at=now()
     where enterprise_id=v_eid and profile_id=v_row.profile_id;
    insert into public.enterprise_career_level_history(
      enterprise_id, profile_id, from_level, to_level, reason, changed_by, approved_by
    ) values (
      v_eid, v_row.profile_id, v_from, v_row.requested_level,
      left(coalesce(v_row.reason,''),1000), v_row.requested_by, v_uid
    );
    update public.enterprise_career_level_requests
       set status='approved', decided_by=v_uid, decided_at=now(),
           decision_reason=left(coalesce(p_reason,''),1000)
     where id=p_request;
  else
    update public.enterprise_career_level_requests
       set status='rejected', decided_by=v_uid, decided_at=now(),
           decision_reason=left(coalesce(p_reason,''),1000)
     where id=p_request;
  end if;
  return jsonb_build_object('ok', true, 'approved', coalesce(p_approve,false));
end;
$fn$;

revoke all on function public.decide_career_level_request(uuid,boolean,text)
  from public, anon, authenticated;
grant execute on function public.decide_career_level_request(uuid,boolean,text)
  to authenticated;

insert into public.app_migrations(version,name,notes)
values (
  'career-levels-v1',
  'Career levels',
  'Five personal career levels mapped to fixed roles; promotion via owner/HR request and board approval'
)
on conflict (version) do update set notes=excluded.notes;
