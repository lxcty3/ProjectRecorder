-- ============================================================
--  Grade a finished task, and pay it out in merit points.
--
--  The loop this closes:
--      boss assigns -> employee finishes -> boss grades -> points land
--
--  Design notes
--  ------------
--  * Base amount comes from the assignment: est_merit if the boss
--    set one, otherwise hours * 10.
--
--    Hours are CLAMPED to 0..24. There is real data in this database
--    with est_hours around 500 (a typo that never got cleaned up),
--    and without the clamp one typo would mint thousands of points
--    and wreck the economy. A day is 24 hours; that is the cap.
--
--  * Grading is one-shot. A task that is already graded refuses a
--    second grade instead of silently paying twice. Re-adjusting is
--    what the manual merit_add is for.
--
--  * Only a finished task can be graded: there must be a task_logs
--    row for it. Otherwise a boss could pay out work nobody did.
--
--  * The reason text is left EMPTY on purpose. This project keeps
--    every sql/*.sql pure ASCII (a full-width character once broke
--    a dollar-quoted body), so the human-readable label is composed
--    on the client from kind + source_id.
-- ============================================================

alter table public.tasks
  add column if not exists est_merit      integer,
  add column if not exists grade          text,
  add column if not exists merit_awarded  integer,
  add column if not exists graded_at      timestamptz,
  add column if not exists graded_by      uuid;

create index if not exists tasks_pending_grade_idx
  on public.tasks (boss_id, plan_date desc)
  where grade is null;

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
  v_base integer;
  v_amount integer;
  v_balance integer;
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

  v_hours := least(greatest(coalesce(v_task.est_hours, 0), 0), 24);
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
--    select column_name from information_schema.columns
--     where table_schema = 'public' and table_name = 'tasks'
--       and column_name in ('grade','merit_awarded','est_merit');
-- ============================================================
