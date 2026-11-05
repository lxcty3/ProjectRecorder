-- ============================================================
-- Project Recorder - Shareholder meetings
--
-- Run after enterprise-identity.sql and enterprise-governance-v2.sql.
-- The current month regular meeting is created automatically when the
-- meeting board is loaded. Special meetings require more than half of
-- active shareholders by headcount.
-- ============================================================

create table if not exists public.shareholder_meetings (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  meeting_month date not null,
  meeting_type text not null check (meeting_type in ('regular','special')),
  title text not null,
  agenda text not null default '',
  reason text not null default '',
  scheduled_at timestamptz not null,
  status text not null default 'scheduled'
    check (status in ('pending_approval','scheduled','approved','completed','cancelled','rejected')),
  initiated_by uuid references public.profiles(id) on delete set null,
  approval_threshold_bps integer not null default 5001,
  approved_at timestamptz,
  completed_at timestamptz,
  minutes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists shareholder_meetings_one_regular_idx
  on public.shareholder_meetings(enterprise_id, meeting_month)
  where meeting_type='regular'
    and status in ('pending_approval','scheduled','approved','completed');

create unique index if not exists shareholder_meetings_one_special_idx
  on public.shareholder_meetings(enterprise_id, meeting_month)
  where meeting_type='special'
    and status in ('pending_approval','scheduled','approved','completed');

create index if not exists shareholder_meetings_schedule_idx
  on public.shareholder_meetings(enterprise_id, scheduled_at desc);

create table if not exists public.shareholder_meeting_votes (
  meeting_id uuid not null references public.shareholder_meetings(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  note text not null default '',
  voted_at timestamptz not null default now(),
  primary key (meeting_id, profile_id)
);

create table if not exists public.shareholder_meeting_attendance (
  meeting_id uuid not null references public.shareholder_meetings(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  attendance_status text not null default 'pending'
    check (attendance_status in ('pending','attending','absent','leave')),
  leave_note text not null default '',
  recorded_at timestamptz not null default now(),
  primary key (meeting_id, profile_id)
);

alter table public.shareholder_meetings enable row level security;
alter table public.shareholder_meeting_votes enable row level security;
alter table public.shareholder_meeting_attendance enable row level security;

revoke all on table public.shareholder_meetings from public, anon, authenticated;
revoke all on table public.shareholder_meeting_votes from public, anon, authenticated;
revoke all on table public.shareholder_meeting_attendance from public, anon, authenticated;

create or replace function public._meeting_enterprise(p_uid uuid)
returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(
    (select e.id from public.enterprises e
      where e.owner_profile_id=p_uid limit 1),
    (select m.enterprise_id from public.enterprise_members m
      where m.profile_id=p_uid and m.status='active'
      order by m.updated_at desc limit 1)
  );
$fn$;

create or replace function public._meeting_has_permission(
  p_eid uuid,p_uid uuid,p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb:='[]'::jsonb;
begin
  if p_uid is null or p_eid is null then return false; end if;
  if exists(select 1 from public.enterprises e
    where e.id=p_eid and e.owner_profile_id=p_uid) then return true; end if;
  if not exists(select 1 from public.enterprise_members m
    where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active') then
    return false;
  end if;
  v_permissions:=coalesce(public._identity_role_permissions(p_eid,p_uid),'[]'::jsonb);
  return v_permissions ?| p_permissions;
end;
$fn$;

create or replace function public._meeting_is_shareholder(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._meeting_has_permission(p_eid,p_uid,array['identity.vote','identity.propose']::text[])
    or coalesce(public._identity_shares(p_eid,p_uid),0)>0;
$fn$;

create or replace function public._meeting_is_executive(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._meeting_has_permission(
    p_eid,p_uid,array['company.manage','governance.manage']::text[]);
$fn$;

create or replace function public._meeting_shareholder_count(p_eid uuid)
returns integer
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select count(*)::integer
    from public.enterprise_shareholders s
    join public.enterprise_members m
      on m.enterprise_id=s.enterprise_id and m.profile_id=s.profile_id
   where s.enterprise_id=p_eid and s.shares>0 and m.status='active';
$fn$;

create or replace function public._meeting_ensure_regular(p_eid uuid)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_month date:=date_trunc('month',timezone('Asia/Shanghai',now()))::date;
  v_id uuid;
  v_scheduled timestamptz;
begin
  select id into v_id from public.shareholder_meetings
   where enterprise_id=p_eid and meeting_month=v_month and meeting_type='regular'
     and status in ('pending_approval','scheduled','approved','completed')
   limit 1;
  if v_id is not null then return v_id; end if;
  v_scheduled:=timezone('Asia/Shanghai',date_trunc('month',timezone('Asia/Shanghai',now()))+interval '1 month'-interval '1 day'+interval '18 hours');
  insert into public.shareholder_meetings(
    enterprise_id,meeting_month,meeting_type,title,agenda,scheduled_at,status
  ) values(
    p_eid,v_month,'regular',to_char(now(),'YYYY-MM')||' Regular Shareholder Meeting',
    'Monthly required shareholder meeting',v_scheduled,'scheduled'
  )
  on conflict do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.shareholder_meetings
     where enterprise_id=p_eid and meeting_month=v_month and meeting_type='regular'
       and status in ('pending_approval','scheduled','approved','completed')
     limit 1;
  end if;
  return v_id;
end;
$fn$;

create or replace function public.get_shareholder_meetings(p_enterprise uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=coalesce(p_enterprise,public._meeting_enterprise(auth.uid()));
  v_regular uuid;
  v_shareholder boolean;
  v_executive boolean;
  v_can_view boolean;
  v_total integer;
  v_month date:=date_trunc('month',timezone('Asia/Shanghai',now()))::date;
  v_month_status text;
  v_special_pending integer:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then raise exception 'enterprise not found'; end if;
  v_shareholder:=public._meeting_is_shareholder(v_eid,v_uid);
  v_executive:=public._meeting_is_executive(v_eid,v_uid);
  v_can_view:=v_shareholder or v_executive
    or public._meeting_has_permission(v_eid,v_uid,array['audit.read','governance.vote']::text[]);
  if not v_can_view then
    return jsonb_build_object('ok',false,'code','permission_denied','error','shareholder or governance access required');
  end if;
  v_regular:=public._meeting_ensure_regular(v_eid);
  v_total:=public._meeting_shareholder_count(v_eid);
  select case
    when exists(select 1 from public.shareholder_meetings m
      where m.enterprise_id=v_eid and m.meeting_month=v_month
        and m.meeting_type='regular' and m.status='scheduled') then 'scheduled'
    when exists(select 1 from public.shareholder_meetings m
      where m.enterprise_id=v_eid and m.meeting_month=v_month
        and m.meeting_type='regular' and m.status='approved') then 'approved'
    when exists(select 1 from public.shareholder_meetings m
      where m.enterprise_id=v_eid and m.meeting_month=v_month
        and m.meeting_type='regular' and m.status='completed') then 'completed'
    else 'missing' end
    into v_month_status;
  select count(*)::integer into v_special_pending
    from public.shareholder_meetings m
   where m.enterprise_id=v_eid and m.meeting_month=v_month
     and m.meeting_type='special' and m.status='pending_approval';
  return jsonb_build_object(
    'ok',true,'enterprise_id',v_eid,'month',v_month,
    'monthly_required',true,'month_status',v_month_status,
    'total_shareholders',v_total,'special_pending',v_special_pending,
    'meetings',(
      select coalesce(jsonb_agg(item),'[]'::jsonb) from (
        select jsonb_build_object(
          'id',m.id,'meeting_month',m.meeting_month,'meeting_type',m.meeting_type,
          'title',m.title,'agenda',m.agenda,'reason',m.reason,
          'scheduled_at',m.scheduled_at,'status',m.status,
          'initiated_by',m.initiated_by,'initiator_name',ip.name,
          'approval_threshold_bps',m.approval_threshold_bps,
          'completed_at',m.completed_at,'minutes',m.minutes,
          'eligible_count',v_total,
          'yes_count',coalesce(v.yes_count,0),
          'no_count',coalesce(v.no_count,0),
          'abstain_count',coalesce(v.abstain_count,0),
          'my_vote',coalesce((select x.choice from public.shareholder_meeting_votes x
            where x.meeting_id=m.id and x.profile_id=v_uid),''),
          'my_attendance',coalesce((select a.attendance_status from public.shareholder_meeting_attendance a
            where a.meeting_id=m.id and a.profile_id=v_uid),'pending'),
          'my_leave_note',coalesce((select a.leave_note from public.shareholder_meeting_attendance a
            where a.meeting_id=m.id and a.profile_id=v_uid),''),
          'attendance',coalesce(att.rows,'[]'::jsonb),
          'actions',jsonb_build_object(
            'vote',v_shareholder and m.meeting_type='special' and m.status='pending_approval',
            'attend',v_shareholder and m.status in ('scheduled','approved'),
            'complete',v_executive and m.status in ('scheduled','approved')
          )
        ) item,m.scheduled_at
        from public.shareholder_meetings m
        left join public.profiles ip on ip.id=m.initiated_by
        left join lateral (
          select count(*) filter(where z.choice='yes') yes_count,
                 count(*) filter(where z.choice='no') no_count,
                 count(*) filter(where z.choice='abstain') abstain_count
          from public.shareholder_meeting_votes z where z.meeting_id=m.id
        ) v on true
        left join lateral (
          select coalesce(jsonb_agg(jsonb_build_object(
            'profile_id',s.profile_id,'name',p.name,'shares',s.shares,
            'status',coalesce(a.attendance_status,'pending'),
            'note',coalesce(a.leave_note,'')
          ) order by p.name),'[]'::jsonb) rows
          from public.enterprise_shareholders s
          join public.profiles p on p.id=s.profile_id
          left join public.shareholder_meeting_attendance a
            on a.meeting_id=m.id and a.profile_id=s.profile_id
          where s.enterprise_id=m.enterprise_id and s.shares>0
            and exists(select 1 from public.enterprise_members em
              where em.enterprise_id=s.enterprise_id and em.profile_id=s.profile_id
                and em.status='active')
        ) att on true
        where m.enterprise_id=v_eid
        order by m.scheduled_at desc limit 50
      ) x
    ),
    'shareholders',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'profile_id',s.profile_id,'name',p.name,'shares',s.shares
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_shareholders s
      join public.profiles p on p.id=s.profile_id
      where s.enterprise_id=v_eid and s.shares>0
        and exists(select 1 from public.enterprise_members em
          where em.enterprise_id=s.enterprise_id and em.profile_id=s.profile_id
            and em.status='active')
    ),
    'access',jsonb_build_object(
      'can_view',v_can_view,'can_initiate_special',v_shareholder
        and not exists(select 1 from public.shareholder_meetings m
          where m.enterprise_id=v_eid and m.meeting_month=v_month
            and m.meeting_type='special'
            and m.status in ('pending_approval','scheduled','approved','completed')),
      'can_complete',v_executive,'is_shareholder',v_shareholder
    ),
    'generated_at',now()
  );
end;
$fn$;

create or replace function public.initiate_shareholder_meeting(
  p_title text,p_agenda text,p_scheduled_at timestamptz,p_reason text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._meeting_enterprise(auth.uid());
  v_title text:=btrim(coalesce(p_title,''));
  v_agenda text:=btrim(coalesce(p_agenda,''));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_month date:=date_trunc('month',timezone('Asia/Shanghai',now()))::date;
  v_total integer;
  v_yes integer;
  v_id uuid;
  v_status text:='pending_approval';
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._meeting_is_shareholder(v_eid,v_uid) then
    return jsonb_build_object('ok',false,'code','permission_denied','error','only shareholders may initiate');
  end if;
  if v_title='' or v_agenda='' or v_reason='' then
    raise exception 'title, agenda, and special meeting reason required';
  end if;
  if p_scheduled_at is null or p_scheduled_at<=now()
     or date_trunc('month',timezone('Asia/Shanghai',p_scheduled_at))::date<>v_month then
    raise exception 'special meeting must be scheduled in the current month and in the future';
  end if;
  if exists(select 1 from public.shareholder_meetings m
    where m.enterprise_id=v_eid and m.meeting_month=v_month and m.meeting_type='special'
      and m.status in ('pending_approval','scheduled','approved','completed')) then
    raise exception 'one active special meeting already exists this month';
  end if;
  insert into public.shareholder_meetings(
    enterprise_id,meeting_month,meeting_type,title,agenda,reason,
    scheduled_at,status,initiated_by
  ) values(v_eid,v_month,'special',v_title,v_agenda,v_reason,p_scheduled_at,'pending_approval',v_uid)
  returning id into v_id;
  insert into public.shareholder_meeting_votes(meeting_id,profile_id,choice,note)
    values(v_id,v_uid,'yes','initiator');
  v_total:=public._meeting_shareholder_count(v_eid);
  select count(*)::integer into v_yes from public.shareholder_meeting_votes
    where meeting_id=v_id and choice='yes';
  if v_yes*2>v_total then
    v_status:='approved';
    update public.shareholder_meetings set status='approved',approved_at=now(),updated_at=now()
      where id=v_id;
  end if;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_eid,v_uid,'shareholder_meeting.initiated',null,
    jsonb_build_object('meeting_id',v_id,'title',v_title,'status',v_status,
      'yes_count',v_yes,'eligible_count',v_total,'reason',v_reason));
  return jsonb_build_object('ok',true,'meeting_id',v_id,'status',v_status,
    'yes_count',v_yes,'eligible_count',v_total,'majority_required',(v_total/2)+1);
end;
$fn$;

create or replace function public.vote_shareholder_meeting(
  p_meeting uuid,p_choice text,p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.shareholder_meetings%rowtype;
  v_choice text:=lower(btrim(coalesce(p_choice,'')));
  v_total integer;
  v_yes integer;
  v_cast integer;
  v_status text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_choice not in ('yes','no','abstain') then raise exception 'invalid meeting vote'; end if;
  select * into v_row from public.shareholder_meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if not public._meeting_is_shareholder(v_row.enterprise_id,v_uid) then
    return jsonb_build_object('ok',false,'code','permission_denied','error','only shareholders may vote');
  end if;
  if v_row.meeting_type<>'special' or v_row.status<>'pending_approval' then
    raise exception 'meeting is not pending approval';
  end if;
  insert into public.shareholder_meeting_votes(meeting_id,profile_id,choice,note)
    values(p_meeting,v_uid,v_choice,btrim(coalesce(p_note,'')))
  on conflict (meeting_id,profile_id) do update set
    choice=excluded.choice,note=excluded.note,voted_at=now();
  v_total:=public._meeting_shareholder_count(v_row.enterprise_id);
  select count(*)::integer,
    count(*) filter(where choice='yes')::integer
    into v_cast,v_yes
    from public.shareholder_meeting_votes where meeting_id=p_meeting;
  if v_yes*2>v_total then
    v_status:='approved';
    update public.shareholder_meetings
      set status='approved',approved_at=now(),updated_at=now() where id=p_meeting;
  elsif (v_yes+(v_total-v_cast))*2<=v_total then
    v_status:='rejected';
    update public.shareholder_meetings
      set status='rejected',updated_at=now() where id=p_meeting;
  else
    v_status:='pending_approval';
  end if;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_row.enterprise_id,v_uid,'shareholder_meeting.vote',null,
    jsonb_build_object('meeting_id',p_meeting,'choice',v_choice,
      'yes_count',v_yes,'cast_count',v_cast,'eligible_count',v_total,'status',v_status));
  return jsonb_build_object('ok',true,'status',v_status,'yes_count',v_yes,
    'cast_count',v_cast,'eligible_count',v_total,'majority_required',(v_total/2)+1);
end;
$fn$;

create or replace function public.record_shareholder_meeting_attendance(
  p_meeting uuid,p_status text,p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.shareholder_meetings%rowtype;
  v_status text:=lower(btrim(coalesce(p_status,'')));
  v_note text:=btrim(coalesce(p_note,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_status not in ('pending','attending','absent','leave') then
    raise exception 'invalid attendance status';
  end if;
  if v_status='leave' and v_note='' then raise exception 'leave note required'; end if;
  select * into v_row from public.shareholder_meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if not public._meeting_is_shareholder(v_row.enterprise_id,v_uid) then
    return jsonb_build_object('ok',false,'code','permission_denied','error','only shareholders may respond');
  end if;
  if v_row.status not in ('scheduled','approved') then
    raise exception 'attendance is only available for scheduled meetings';
  end if;
  insert into public.shareholder_meeting_attendance(meeting_id,profile_id,attendance_status,leave_note)
    values(p_meeting,v_uid,v_status,case when v_status='leave' then v_note else '' end)
  on conflict (meeting_id,profile_id) do update set
    attendance_status=excluded.attendance_status,
    leave_note=excluded.leave_note,recorded_at=now();
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_row.enterprise_id,v_uid,'shareholder_meeting.attendance',null,
    jsonb_build_object('meeting_id',p_meeting,'status',v_status,'note',v_note));
  return jsonb_build_object('ok',true,'meeting_id',p_meeting,'status',v_status);
end;
$fn$;

create or replace function public.complete_shareholder_meeting(
  p_meeting uuid,p_minutes text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.shareholder_meetings%rowtype;
  v_minutes text:=btrim(coalesce(p_minutes,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.shareholder_meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if not public._meeting_is_executive(v_row.enterprise_id,v_uid) then
    return jsonb_build_object('ok',false,'code','permission_denied','error','governance authority required');
  end if;
  if v_row.status not in ('scheduled','approved') then raise exception 'meeting is not open'; end if;
  if v_minutes='' then raise exception 'meeting minutes required'; end if;
  update public.shareholder_meetings set
    status='completed',completed_at=now(),minutes=v_minutes,updated_at=now()
  where id=p_meeting returning * into v_row;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_row.enterprise_id,v_uid,'shareholder_meeting.completed',null,
    jsonb_build_object('meeting_id',p_meeting,'minutes',v_minutes));
  return jsonb_build_object('ok',true,'meeting_id',p_meeting,'status','completed');
end;
$fn$;

revoke all on function public._meeting_enterprise(uuid) from public, anon, authenticated;
revoke all on function public._meeting_has_permission(uuid,uuid,text[]) from public, anon, authenticated;
revoke all on function public._meeting_is_shareholder(uuid,uuid) from public, anon, authenticated;
revoke all on function public._meeting_is_executive(uuid,uuid) from public, anon, authenticated;
revoke all on function public._meeting_shareholder_count(uuid) from public, anon, authenticated;
revoke all on function public._meeting_ensure_regular(uuid) from public, anon, authenticated;
revoke all on function public.get_shareholder_meetings(uuid) from public, anon, authenticated;
revoke all on function public.initiate_shareholder_meeting(text,text,timestamptz,text) from public, anon, authenticated;
revoke all on function public.vote_shareholder_meeting(uuid,text,text) from public, anon, authenticated;
revoke all on function public.record_shareholder_meeting_attendance(uuid,text,text) from public, anon, authenticated;
revoke all on function public.complete_shareholder_meeting(uuid,text) from public, anon, authenticated;

grant execute on function public.get_shareholder_meetings(uuid) to authenticated;
grant execute on function public.initiate_shareholder_meeting(text,text,timestamptz,text) to authenticated;
grant execute on function public.vote_shareholder_meeting(uuid,text,text) to authenticated;
grant execute on function public.record_shareholder_meeting_attendance(uuid,text,text) to authenticated;
grant execute on function public.complete_shareholder_meeting(uuid,text) to authenticated;
