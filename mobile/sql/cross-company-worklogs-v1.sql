-- Cross-company membership worklogs v1
-- Boss accounts that join another company become ordinary members there,
-- and their worklogs belong to the active company, not their own.

alter table public.worklogs
  add column if not exists enterprise_id uuid
    references public.enterprises(id) on delete set null;
alter table public.work_sessions
  add column if not exists enterprise_id uuid
    references public.enterprises(id) on delete set null;

create index if not exists worklogs_enterprise_idx
  on public.worklogs(enterprise_id, work_date desc);
create index if not exists work_sessions_enterprise_idx
  on public.work_sessions(enterprise_id, started_at desc);

create or replace function public._worklog_scope(
  p_uid uuid,
  p_enterprise uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_eid uuid := p_enterprise;
  v_owner uuid;
  v_boss uuid;
begin
  if v_eid is null then
    select active_enterprise_id into v_eid
      from public.profiles where id = p_uid;
  end if;

  if v_eid is null then
    select coalesce(boss_id, id) into v_boss
      from public.profiles where id = p_uid;
    if v_boss = p_uid then
      v_eid := public._identity_ensure_enterprise(p_uid);
    else
      select id into v_eid
        from public.enterprises
       where owner_profile_id = v_boss
       order by created_at, id limit 1;
    end if;
  end if;

  if v_eid is null then
    raise exception 'no active company';
  end if;

  select owner_profile_id into v_owner
    from public.enterprises where id = v_eid;
  if v_owner is null then
    raise exception 'company not found';
  end if;

  if not public._identity_is_member(v_eid, p_uid) then
    raise exception 'not an enterprise member';
  end if;

  return jsonb_build_object('enterprise_id', v_eid, 'boss_id', v_owner);
end;
$fn$;
revoke all on function public._worklog_scope(uuid,uuid) from public,anon,authenticated;

create or replace function public.end_work(p_enterprise uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.work_sessions%rowtype;
  v_hours numeric;
  v_merit integer;
  v_balance integer;
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_capped boolean := false;
  v_scope jsonb;
  v_boss uuid;
  v_eid uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  select * into v_row
    from public.work_sessions
   where profile_id = v_uid and ended_at is null
   order by started_at desc
   limit 1;

  if not found then
    raise exception 'not working';
  end if;

  v_scope := public._worklog_scope(v_uid, p_enterprise);
  v_boss := (v_scope->>'boss_id')::uuid;
  v_eid := (v_scope->>'enterprise_id')::uuid;

  v_hours := round(
    extract(epoch from (now() - v_row.started_at)) / 3600.0, 2
  );

  if v_hours > 24 then
    v_hours := 24;
    v_capped := true;
  end if;

  if v_hours < 0.005 then
    v_hours := 0;
  end if;

  update public.work_sessions
     set ended_at = now(),
         hours = v_hours,
         enterprise_id = coalesce(enterprise_id, v_eid),
         boss_id = coalesce(boss_id, v_boss)
   where id = v_row.id;

  if v_hours > 0 then
    insert into public.worklogs (
      boss_id, employee_id, enterprise_id, task_id,
      work_date, hours, content, source
    ) values (
      v_boss, v_uid, v_eid, v_row.task_id, v_today, v_hours, '', 'timer'
    );

    v_merit := round(v_hours * 10);
    if v_merit <> 0 then
      insert into public.merit_ledger (
        boss_id, profile_id, amount, kind, reason, source_id
      ) values (
        v_boss, v_uid, v_merit, 'hours', '', v_row.id
      );
    end if;
  else
    v_merit := 0;
  end if;

  select coalesce(sum(amount), 0) into v_balance
    from public.merit_ledger where profile_id = v_uid;

  return jsonb_build_object(
    'ok', true, 'hours', v_hours, 'recorded', v_hours > 0,
    'capped', v_capped, 'merit', v_merit, 'balance', v_balance,
    'enterprise_id', v_eid
  );
end;
$fn$;

create or replace function public.start_work(
  p_task uuid default null,
  p_enterprise uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_boss uuid;
  v_eid uuid;
  v_scope jsonb;
  v_open public.work_sessions%rowtype;
  v_hours numeric;
  v_id uuid;
  v_started timestamptz;
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_closed_stale boolean := false;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  v_scope := public._worklog_scope(v_uid, p_enterprise);
  v_boss := (v_scope->>'boss_id')::uuid;
  v_eid := (v_scope->>'enterprise_id')::uuid;

  select * into v_open
    from public.work_sessions
   where profile_id = v_uid and ended_at is null
   order by started_at desc
   limit 1;

  if found then
    v_hours := round(
      extract(epoch from (now() - v_open.started_at)) / 3600.0, 2
    );

    if v_hours <= 24 then
      raise exception 'already working';
    end if;

    v_hours := 24;
    update public.work_sessions
       set ended_at = now(), hours = v_hours,
           enterprise_id = coalesce(enterprise_id, v_eid),
           boss_id = coalesce(boss_id, v_boss)
     where id = v_open.id;

    insert into public.worklogs (
      boss_id, employee_id, enterprise_id, task_id,
      work_date, hours, content, source
    ) values (
      v_boss, v_uid, v_eid, v_open.task_id, v_today, v_hours, '', 'timer'
    );

    insert into public.merit_ledger (
      boss_id, profile_id, amount, kind, reason, source_id
    ) values (
      v_boss, v_uid, round(v_hours * 10), 'hours', '', v_open.id
    );

    v_closed_stale := true;
  end if;

  insert into public.work_sessions (
    boss_id, profile_id, enterprise_id, task_id
  ) values (v_boss, v_uid, v_eid, p_task)
  returning id, started_at into v_id, v_started;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'started_at', v_started,
    'closed_stale', v_closed_stale, 'enterprise_id', v_eid
  );
end;
$fn$;

drop function if exists public.start_work(uuid);

revoke all on function public.end_work(uuid) from public,anon,authenticated;
revoke all on function public.start_work(uuid,uuid) from public,anon,authenticated;
grant execute on function public.end_work(uuid) to authenticated;
grant execute on function public.start_work(uuid,uuid) to authenticated;

insert into public.app_migrations(version,name,notes)
values(
  'cross-company-worklogs-v1',
  'Cross company worklogs',
  'worklogs and work sessions carry enterprise_id; boss accounts log work as ordinary members'
)
on conflict (version) do update set notes = excluded.notes;
