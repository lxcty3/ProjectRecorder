-- ProjectRecorder platform stability and migration registry.
-- ASCII-only, additive and idempotent.

create table if not exists public.app_migrations (
  version text primary key,
  name text not null,
  notes text not null default '',
  applied_at timestamptz not null default now(),
  applied_by uuid references public.profiles(id) on delete set null
);
alter table public.app_migrations enable row level security;
revoke all on public.app_migrations from anon,authenticated;

create or replace function public.record_app_migration(
  p_version text,p_name text,p_notes text default ''
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid();
begin
  insert into public.app_migrations(version,name,notes,applied_by)
  values(btrim(p_version),btrim(p_name),btrim(coalesce(p_notes,'')),v_uid)
  on conflict (version) do update set
    name=excluded.name,notes=excluded.notes,applied_at=now(),
    applied_by=coalesce(excluded.applied_by,public.app_migrations.applied_by);
  return jsonb_build_object('ok',true,'version',btrim(p_version));
end;
$fn$;

insert into public.app_migrations(version,name,notes)
select 'core','Core tables','profiles/projects/worklogs'
where to_regclass('public.profiles') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'enterprise-identity','Enterprise identity','roles, members and shares'
where to_regclass('public.enterprise_members') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'enterprise-governance-v2','Enterprise governance','point pools and knowledge unlocks'
where to_regclass('public.enterprise_point_pools') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'community','Legacy community','community_posts'
where to_regclass('public.community_posts') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'community-forum-v1','Community forum v2.1','boards, comments and notifications'
where to_regclass('public.community_boards') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'shareholder-meetings-v1','Shareholder meetings','meetings, votes and leave'
where to_regclass('public.shareholder_meetings') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'decision-approvals-v1','Decision approvals','decision and approval queues'
where to_regclass('public.decision_items') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'execution-tracking-v1','Execution tracking','acceptance, handoff and changes'
where to_regclass('public.task_acceptance') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'operations-economics-v1','Operations economics','projects, skills and evidence'
where to_regclass('public.project_economics') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'work-intake-v1','Work intake','forms, requests and triage'
where to_regclass('public.intake_requests') is not null
on conflict (version) do nothing;
insert into public.app_migrations(version,name,notes)
select 'organization-founders-v1','Organization founders','founders, share lots and equity'
where to_regclass('public.organization_foundations') is not null
on conflict (version) do nothing;

create or replace function public.get_platform_health()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_profile jsonb;
  v_checks jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select jsonb_build_object(
    'id',p.id,'name',p.name,'role',p.role,
    'active_enterprise_id',p.active_enterprise_id
  ) into v_profile from public.profiles p where p.id=v_uid;
  select jsonb_build_array(
    jsonb_build_object('key','profiles','label','Profiles','ok',
      to_regclass('public.profiles') is not null),
    jsonb_build_object('key','enterprise_identity','label','Enterprise identity','ok',
      to_regclass('public.enterprise_members') is not null),
    jsonb_build_object('key','community','label','Community','ok',
      to_regclass('public.community_posts') is not null),
    jsonb_build_object('key','community_forum','label','Community forum','ok',
      to_regclass('public.community_boards') is not null),
    jsonb_build_object('key','shareholder_meetings','label','Shareholder meetings','ok',
      to_regclass('public.shareholder_meetings') is not null),
    jsonb_build_object('key','decisions','label','Decision center','ok',
      to_regclass('public.decision_items') is not null),
    jsonb_build_object('key','execution','label','Execution tracking','ok',
      to_regclass('public.task_acceptance') is not null),
    jsonb_build_object('key','operations','label','Operations economics','ok',
      to_regclass('public.project_economics') is not null),
    jsonb_build_object('key','intake','label','Work intake','ok',
      to_regclass('public.intake_requests') is not null),
    jsonb_build_object('key','organization','label','Organization founders','ok',
      to_regclass('public.organization_foundations') is not null)
  ) into v_checks;
  return jsonb_build_object(
    'ok',true,
    'server_time',now(),
    'database_ready',not exists(
      select 1 from jsonb_array_elements(v_checks) c where not (c->>'ok')::boolean
    ),
    'profile',v_profile,
    'checks',v_checks,
    'migrations',coalesce((select jsonb_agg(jsonb_build_object(
      'version',m.version,'name',m.name,'applied_at',m.applied_at
    ) order by m.applied_at desc) from public.app_migrations m),'[]'::jsonb)
  );
end;
$fn$;

revoke all on function public.record_app_migration(text,text,text) from public,anon,authenticated;
revoke all on function public.get_platform_health() from public,anon,authenticated;
grant execute on function public.get_platform_health() to authenticated;
