-- ProjectRecorder multi-account sync health v1
-- ASCII-only and idempotent.

create table if not exists public.client_protocol_versions (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  protocol_version integer not null,
  app_version text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.client_protocol_versions enable row level security;
revoke all on public.client_protocol_versions from public,anon,authenticated;

create or replace function public.get_client_protocol()
returns jsonb
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select jsonb_build_object(
    'protocol_version',2,
    'minimum_protocol_version',2,
    'minimum_app_version','2.0.9'
  );
$fn$;
revoke all on function public.get_client_protocol() from public;
grant execute on function public.get_client_protocol() to anon,authenticated;

create or replace function public.register_client_protocol(
  p_protocol integer,
  p_app_version text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  insert into public.client_protocol_versions(
    profile_id,protocol_version,app_version,updated_at
  ) values(v_uid,greatest(coalesce(p_protocol,0),0),coalesce(p_app_version,''),now())
  on conflict(profile_id) do update set
    protocol_version=excluded.protocol_version,
    app_version=excluded.app_version,
    updated_at=now();
  return public.get_client_protocol();
end;
$fn$;
revoke all on function public.register_client_protocol(integer,text) from public,anon,authenticated;
grant execute on function public.register_client_protocol(integer,text) to authenticated;

create or replace function public.repair_my_organization()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_profile public.profiles%rowtype;
  v_eid uuid;
  v_role text;
  v_mode text:='simple';
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_profile from public.profiles where id=v_uid;
  if not found then raise exception 'profile not found'; end if;

  if v_profile.role not in ('boss','admin') then
    if v_profile.boss_id is null then
      return jsonb_build_object(
        'ok',true,'status','pending','message','waiting for a company invitation'
      );
    end if;

    select m.enterprise_id into v_eid
      from public.enterprise_members m
     where m.profile_id=v_uid and m.status='active'
     order by case when m.enterprise_id=v_profile.active_enterprise_id then 0 else 1 end,
              m.appointed_at nulls last
     limit 1;

    if v_eid is null then
      return jsonb_build_object(
        'ok',true,'status','pending','message','waiting for an active company membership'
      );
    end if;

    update public.profiles
       set active_enterprise_id=v_eid
     where id=v_uid and active_enterprise_id is distinct from v_eid;
  else
    select id into v_eid from public.enterprises
     where id=v_profile.active_enterprise_id
       and owner_profile_id=v_uid
     limit 1;
    if v_eid is null then
      select id into v_eid from public.enterprises
       where owner_profile_id=v_uid
       order by created_at,id limit 1;
    end if;
    if v_eid is null then
      v_eid:=public._identity_bootstrap(v_uid);
    else
      perform public._identity_bootstrap(v_uid);
    end if;
    update public.profiles
       set active_enterprise_id=v_eid
     where id=v_uid and active_enterprise_id is distinct from v_eid;
  end if;

  select m.role_key,m.preferred_mode into v_role,v_mode
    from public.enterprise_members m
   where m.enterprise_id=v_eid and m.profile_id=v_uid and m.status='active'
   limit 1;

  if v_role is null then
    return jsonb_build_object(
      'ok',false,'status','repair_failed','enterprise_id',v_eid,
      'message','company exists but membership is missing'
    );
  end if;

  return jsonb_build_object(
    'ok',true,'status','ready','enterprise_id',v_eid,
    'role_key',v_role,'preferred_mode',coalesce(v_mode,'simple')
  );
end;
$fn$;
revoke all on function public.repair_my_organization() from public,anon,authenticated;
grant execute on function public.repair_my_organization() to authenticated;

create or replace function public.get_organization_health(p_enterprise uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=p_enterprise;
  v_can_view boolean:=false;
  v_members integer:=0;
  v_active integer:=0;
  v_shareholders integer:=0;
  v_shares numeric:=0;
  v_owner_role boolean:=false;
  v_open_motions integer:=0;
  v_checks jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    select active_enterprise_id into v_eid from public.profiles where id=v_uid;
  end if;
  if v_eid is null then
    return jsonb_build_object(
      'ok',false,'status','no_active_company',
      'message','repair_my_organization must run first'
    );
  end if;

  v_can_view:=public._identity_is_member(v_eid,v_uid)
    and public._identity_can_use_advanced_mode(v_eid,v_uid);
  if not v_can_view then
    raise exception 'permission denied';
  end if;

  select count(*),count(*) filter (where status='active')
    into v_members,v_active
    from public.enterprise_members where enterprise_id=v_eid;
  select count(*),coalesce(sum(shares),0)
    into v_shareholders,v_shares
    from public.enterprise_shareholders where enterprise_id=v_eid and shares>0;
  select exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=v_eid and m.profile_id=v_uid
       and m.status='active' and m.role_key='chairperson'
  ) into v_owner_role;
  select count(*) into v_open_motions
    from public.enterprise_role_motions
   where enterprise_id=v_eid and status='open' and closes_at>now();

  v_checks:=jsonb_build_array(
    jsonb_build_object('key','members','label','Active members',
      'ok',v_active>0,'detail',v_active::text||' / '||v_members::text),
    jsonb_build_object('key','shares','label','Shareholders and shares',
      'ok',v_shareholders>0 and v_shares>0,
      'detail',v_shareholders::text||' holders / '||v_shares::text||' units'),
    jsonb_build_object('key','chairperson','label','Chairperson membership',
      'ok',v_owner_role,'detail',case when v_owner_role then 'present' else 'missing' end),
    jsonb_build_object('key','motions','label','Open governance motions',
      'ok',true,'detail',v_open_motions::text)
  );

  return jsonb_build_object(
    'ok',true,'enterprise_id',v_eid,'counts',jsonb_build_object(
      'members',v_members,'active_members',v_active,
      'shareholders',v_shareholders,'shares',v_shares,
      'open_motions',v_open_motions
    ),'checks',v_checks
  );
end;
$fn$;
revoke all on function public.get_organization_health(uuid) from public,anon,authenticated;
grant execute on function public.get_organization_health(uuid) to authenticated;


insert into public.app_migrations(version,name,notes)
values(
  'multi-account-sync-health-v1',
  'Multi-account sync health',
  'account scoped client database, queue preservation, organization repair and protocol checks'
)
on conflict (version) do nothing;
-- ------------------------------------------------------------ tombstones
create table if not exists public.sync_tombstones (
  table_name text not null
    check (table_name in ('tasks','task_logs','worklogs')),
  row_id uuid not null,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  deleted_by uuid references public.profiles(id) on delete set null,
  deleted_at timestamptz not null default now(),
  primary key (table_name,row_id)
);
create index if not exists sync_tombstones_enterprise_idx
  on public.sync_tombstones(enterprise_id,deleted_at desc);
alter table public.sync_tombstones enable row level security;
revoke all on public.sync_tombstones from public,anon,authenticated;

create or replace function public._reject_tombstoned_sync_row()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if exists(
    select 1 from public.sync_tombstones t
     where t.table_name=tg_table_name and t.row_id=new.id
  ) then
    raise exception 'record deleted on another device';
  end if;
  return new;
end;
$fn$;

do $do$
begin
  if to_regclass('public.tasks') is not null then
    drop trigger if exists reject_tombstoned_tasks on public.tasks;
    create trigger reject_tombstoned_tasks
      before insert or update on public.tasks
      for each row execute function public._reject_tombstoned_sync_row();
  end if;
  if to_regclass('public.task_logs') is not null then
    drop trigger if exists reject_tombstoned_task_logs on public.task_logs;
    create trigger reject_tombstoned_task_logs
      before insert or update on public.task_logs
      for each row execute function public._reject_tombstoned_sync_row();
  end if;
  if to_regclass('public.worklogs') is not null then
    drop trigger if exists reject_tombstoned_worklogs on public.worklogs;
    create trigger reject_tombstoned_worklogs
      before insert or update on public.worklogs
      for each row execute function public._reject_tombstoned_sync_row();
  end if;
end;
$do$;

create or replace function public.delete_sync_record(
  p_table text,
  p_id uuid,
  p_enterprise uuid default null
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=p_enterprise;
  v_boss uuid;
  v_employee uuid;
  v_allowed boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_table not in ('tasks','task_logs','worklogs') then
    raise exception 'unsupported tombstone table';
  end if;

  if p_table='tasks' then
    select boss_id,employee_id into v_boss,v_employee from public.tasks where id=p_id;
    v_allowed:=v_uid=v_boss
      or (v_eid is not null and public._identity_can_use_advanced_mode(v_eid,v_uid));
  elsif p_table='task_logs' then
    select boss_id,employee_id into v_boss,v_employee from public.task_logs where id=p_id;
    v_allowed:=v_uid=v_employee or v_uid=v_boss
      or (v_eid is not null and public._identity_can_use_advanced_mode(v_eid,v_uid));
  else
    select boss_id,employee_id into v_boss,v_employee from public.worklogs where id=p_id;
    v_allowed:=v_uid=v_employee or v_uid=v_boss
      or (v_eid is not null and public._identity_can_use_advanced_mode(v_eid,v_uid));
  end if;

  if v_eid is null then
    v_eid:=public._identity_ensure_enterprise(public._identity_owner_for_uid(v_uid));
  end if;
  if not v_allowed then raise exception 'permission denied'; end if;

  insert into public.sync_tombstones(
    table_name,row_id,enterprise_id,deleted_by,deleted_at
  ) values(p_table,p_id,v_eid,v_uid,now())
  on conflict(table_name,row_id) do update set
    enterprise_id=excluded.enterprise_id,
    deleted_by=excluded.deleted_by,
    deleted_at=excluded.deleted_at;

  if p_table='tasks' then
    delete from public.tasks where id=p_id;
  elsif p_table='task_logs' then
    delete from public.task_logs where id=p_id;
  else
    delete from public.worklogs where id=p_id;
  end if;

  return jsonb_build_object('ok',true,'deleted',true,'table',p_table,'id',p_id);
end;
$fn$;
revoke all on function public.delete_sync_record(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.delete_sync_record(text,uuid,uuid) to authenticated;

create or replace function public.get_sync_tombstones(p_since timestamptz default null)
returns jsonb
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
    'table_name',t.table_name,
    'row_id',t.row_id,
    'enterprise_id',t.enterprise_id,
    'deleted_at',t.deleted_at
  ) order by t.deleted_at), '[]'::jsonb)
  from public.sync_tombstones t
  where (p_since is null or t.deleted_at>p_since)
    and exists(
      select 1 from public.enterprise_members m
       where m.enterprise_id=t.enterprise_id
         and m.profile_id=auth.uid()
         and m.status='active'
    );
$fn$;
revoke all on function public.get_sync_tombstones(timestamptz) from public,anon,authenticated;
grant execute on function public.get_sync_tombstones(timestamptz) to authenticated;

insert into public.app_migrations(version,name,notes)
values(
  'multi-account-sync-health-v1',
  'Multi-account sync health',
  'account scoped client database, queue preservation, tombstones, organization repair and protocol checks'
)
on conflict (version) do update set notes=excluded.notes;
