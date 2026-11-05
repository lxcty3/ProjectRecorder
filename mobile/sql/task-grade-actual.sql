-- ============================================================
--  Grade a task using the ACTUAL measured time.
--
--  The rule changed:
--      before - base points came from est_hours (the boss's guess)
--      now    - base points come from task_logs: started_at to
--               finished_at, i.e. what the timer actually measured
--
--  The boss's estimate is only a reference now: it is shown in the
--  UI next to the real number, and used as a fallback when there is
--  no measured time at all (old tasks finished before the timer
--  existed, or the employee never tapped start).
--
--  Still clamped to 0..24 hours. A forgotten tap can otherwise
--  measure a week of work.
--
--  The response says which number was used, so the app can be
--  honest about it:
--      'source': 'actual' | 'estimate'
--
--  This file is ASCII-only on purpose.
-- ============================================================

create or replace function public.grade_task(p_task uuid, p_grade text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_task public.tasks%rowtype;
  v_grade text := upper(trim(coalesce(p_grade, '')));
  v_mult numeric;
  v_hours numeric;
  v_actual numeric;
  v_source text := 'estimate';
  v_base integer;
  v_amount integer;
  v_balance integer;
  v_start timestamptz;
  v_end timestamptz;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  if v_grade not in ('S', 'A', 'B', 'C') then
    raise exception 'grade must be S, A, B or C';
  end if;

  select * into v_task from public.tasks where id = p_task;
  if not found then
    raise exception 'no such task';
  end if;

  if v_task.boss_id is distinct from v_uid then
    raise exception 'not your task';
  end if;

  if v_task.grade is not null then
    raise exception 'already graded';
  end if;
  if not exists(
    select 1 from public.task_acceptance a
     where a.task_id=p_task and a.status='accepted'
  ) then
    raise exception 'task acceptance required before grading';
  end if;

  if not exists (
    select 1 from public.task_logs where task_id = p_task
  ) then
    raise exception 'task is not finished yet';
  end if;

  v_mult := case v_grade
              when 'S' then 1.2
              when 'A' then 1.0
              when 'B' then 0.8
              else 0
            end;

  /* Measured time wins. */
  select l.started_at, l.finished_at
    into v_start, v_end
    from public.task_logs l
   where l.task_id = p_task
   order by l.finished_at desc nulls last
   limit 1;

  if v_start is not null and v_end is not null and v_end > v_start then
    v_actual := round(
      extract(epoch from (v_end - v_start)) / 3600.0, 2
    );
    v_hours := v_actual;
    v_source := 'actual';
  else
    v_hours := coalesce(v_task.est_hours, 0);
    v_source := 'estimate';
  end if;

  v_hours := least(greatest(v_hours, 0), 24);

  v_base := coalesce(v_task.est_merit, round(v_hours * 10));
  v_amount := round(v_base * v_mult);

  update public.tasks
     set grade = v_grade,
         merit_awarded = v_amount,
         graded_at = now(),
         graded_by = v_uid,
         updated_at = now()
   where id = p_task;

  if v_amount <> 0 then
    insert into public.merit_ledger (
      boss_id, profile_id, amount, kind, reason, source_id
    ) values (
      v_task.boss_id, v_task.employee_id, v_amount, 'grade', '', p_task
    );
  end if;

  select coalesce(sum(amount), 0) into v_balance
    from public.merit_ledger where profile_id = v_task.employee_id;

  return jsonb_build_object(
    'ok', true,
    'grade', v_grade,
    'hours', v_hours,
    'source', v_source,
    'amount', v_amount,
    'balance', v_balance
  );
end;
$fn$;

revoke all on function public.grade_task(uuid, text) from public;
revoke all on function public.grade_task(uuid, text) from anon;
grant execute on function public.grade_task(uuid, text) to authenticated;

-- ============================================================
--  Verify:
--    select pg_get_function_arguments(oid) from pg_proc
--     where proname = 'grade_task';
-- ============================================================
