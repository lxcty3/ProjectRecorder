-- ============================================================
-- Shareholder meeting attendance verification v1
--
-- Attendance materially affects quorum and meeting records, so a
-- signed-in session alone is not enough for a one-tap action.
-- The caller must re-enter the account code (staff or boss code)
-- that belongs to auth.uid().
--
-- This migration also revokes the old unverified attendance RPC
-- from authenticated clients. The old function remains in the
-- database for compatibility, but clients must use the verified
-- function below.
--
-- ASCII-only and safe to run more than once.
-- ============================================================

create or replace function public.record_shareholder_meeting_attendance_verified(
  p_meeting uuid,
  p_status text,
  p_note text default '',
  p_verification_code text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.shareholder_meetings%rowtype;
  v_status text:=lower(btrim(coalesce(p_status,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_entered text:=lower(btrim(coalesce(p_verification_code,'')));
  v_code text;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if v_status not in ('pending','attending','absent','leave') then
    raise exception 'invalid attendance status';
  end if;
  if v_status='leave' and v_note='' then
    raise exception 'leave note required';
  end if;
  if v_entered='' then
    return jsonb_build_object(
      'ok',false,'code','verification_failed',
      'error','account code verification required'
    );
  end if;

  select lower(btrim(coalesce(p.code,''))) into v_code
    from public.profiles p
   where p.id=v_uid;
  if v_code is null or v_code='' or v_code<>v_entered then
    return jsonb_build_object(
      'ok',false,'code','verification_failed',
      'error','identity verification failed'
    );
  end if;

  select * into v_row
    from public.shareholder_meetings
   where id=p_meeting
   for update;
  if not found then
    raise exception 'meeting not found';
  end if;
  if not public._meeting_is_shareholder(v_row.enterprise_id,v_uid) then
    return jsonb_build_object(
      'ok',false,'code','permission_denied',
      'error','only shareholders may respond'
    );
  end if;
  if v_row.status not in ('scheduled','approved') then
    raise exception 'attendance is only available for scheduled meetings';
  end if;

  insert into public.shareholder_meeting_attendance(
    meeting_id,profile_id,attendance_status,leave_note
  ) values(
    p_meeting,v_uid,v_status,case when v_status='leave' then v_note else '' end
  )
  on conflict (meeting_id,profile_id) do update set
    attendance_status=excluded.attendance_status,
    leave_note=excluded.leave_note,
    recorded_at=now();

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'shareholder_meeting.attendance',null,
    jsonb_build_object(
      'meeting_id',p_meeting,
      'status',v_status,
      'note',v_note,
      'verified',true,
      'verification_method','account_code'
    )
  );

  return jsonb_build_object(
    'ok',true,
    'meeting_id',p_meeting,
    'status',v_status,
    'verified',true
  );
end;
$fn$;

revoke all on function public.record_shareholder_meeting_attendance_verified(
  uuid,text,text,text
) from public,anon,authenticated;
grant execute on function public.record_shareholder_meeting_attendance_verified(
  uuid,text,text,text
) to authenticated;

-- Force updated clients through the verified path.
revoke execute on function public.record_shareholder_meeting_attendance(
  uuid,text,text
) from authenticated;

-- Verification:
--   select proname,prosecdef
--     from pg_proc
--    where proname='record_shareholder_meeting_attendance_verified';
