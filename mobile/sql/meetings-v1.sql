-- ============================================================
-- Meetings v1: recording + AI summary
--
-- Audio stays on the device. For summarization the client uploads a
-- temporary copy to the private meeting-audio bucket; the Edge Function
-- deletes it after processing.
-- ============================================================

create table if not exists public.meetings (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  organizer_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  title text not null,
  meeting_date timestamptz not null default now(),
  location text not null default '',
  agenda text not null default '',
  participants jsonb not null default '[]'::jsonb,
  consent_confirmed boolean not null default false,
  audio_path text not null default '',
  transcript text not null default '',
  summary text not null default '',
  decisions jsonb not null default '[]'::jsonb,
  actions jsonb not null default '[]'::jsonb,
  risks jsonb not null default '[]'::jsonb,
  status text not null default 'draft'
    check (status in ('draft','recording','processing','ready','failed')),
  error text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists meetings_enterprise_idx
  on public.meetings(enterprise_id, meeting_date desc);

alter table public.meetings enable row level security;
revoke all on public.meetings from public, anon, authenticated;

create or replace function public.create_meeting(
  p_title text,
  p_date timestamptz,
  p_location text,
  p_agenda text,
  p_participants jsonb,
  p_consent boolean
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if char_length(trim(coalesce(p_title,''))) < 1 then
    raise exception 'meeting title is required';
  end if;
  if not coalesce(p_consent,false) then
    raise exception 'recording consent is required';
  end if;
  insert into public.meetings(
    enterprise_id, organizer_profile_id, title, meeting_date,
    location, agenda, participants, consent_confirmed, status
  ) values (
    v_eid, v_uid, trim(p_title), coalesce(p_date, now()),
    left(coalesce(p_location,''),200), left(coalesce(p_agenda,''),2000),
    coalesce(p_participants,'[]'::jsonb), true, 'draft'
  ) returning id into v_id;
  return jsonb_build_object('ok', true, 'meeting_id', v_id);
end;
$fn$;

create or replace function public.update_meeting_status(
  p_meeting uuid,
  p_status text,
  p_error text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.meetings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if v_row.organizer_profile_id <> v_uid then
    raise exception 'only the organizer can update this meeting';
  end if;
  if p_status not in ('draft','recording','processing','ready','failed') then
    raise exception 'invalid meeting status';
  end if;
  update public.meetings
     set status=p_status, error=left(coalesce(p_error,''),1000),
         updated_at=now()
   where id=p_meeting;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.update_meeting_summary(
  p_meeting uuid,
  p_transcript text,
  p_summary text,
  p_decisions jsonb default '[]'::jsonb,
  p_actions jsonb default '[]'::jsonb,
  p_risks jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.meetings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if v_row.organizer_profile_id <> v_uid then
    raise exception 'only the organizer can update this meeting';
  end if;
  update public.meetings
     set transcript=left(coalesce(p_transcript,''),60000),
         summary=left(coalesce(p_summary,''),12000),
         decisions=coalesce(p_decisions,'[]'::jsonb),
         actions=coalesce(p_actions,'[]'::jsonb),
         risks=coalesce(p_risks,'[]'::jsonb),
         status='ready', error='', updated_at=now()
   where id=p_meeting;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.update_meeting_audio(
  p_meeting uuid,
  p_audio_path text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.meetings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.meetings where id=p_meeting for update;
  if not found then raise exception 'meeting not found'; end if;
  if v_row.organizer_profile_id <> v_uid then
    raise exception 'only the organizer can update this meeting';
  end if;
  update public.meetings
     set audio_path=left(coalesce(p_audio_path,''),500), updated_at=now()
   where id=p_meeting;
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.list_meetings(p_limit integer default 50)
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
    'id', m.id,
    'title', m.title,
    'meeting_date', m.meeting_date,
    'location', m.location,
    'agenda', m.agenda,
    'participants', m.participants,
    'consent_confirmed', m.consent_confirmed,
    'audio_path', case when m.organizer_profile_id=v_uid then m.audio_path else '' end,
    'transcript', m.transcript,
    'summary', m.summary,
    'decisions', m.decisions,
    'actions', m.actions,
    'risks', m.risks,
    'status', m.status,
    'error', m.error,
    'organizer_profile_id', m.organizer_profile_id,
    'organizer_name', p.name,
    'is_organizer', m.organizer_profile_id=v_uid,
    'created_at', m.created_at
  ) order by m.meeting_date desc), '[]'::jsonb)
    into v_rows
    from public.meetings m
    join public.profiles p on p.id=m.organizer_profile_id
   where m.enterprise_id=v_eid
   order by m.meeting_date desc
   limit greatest(1, least(coalesce(p_limit,50),100));
  return jsonb_build_object('ok', true, 'meetings', v_rows);
end;
$fn$;

create or replace function public.get_meeting(p_meeting uuid)
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.meetings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.meetings where id=p_meeting;
  if not found then raise exception 'meeting not found'; end if;
  if not public._identity_is_member(v_row.enterprise_id, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  return jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'title', v_row.title,
    'meeting_date', v_row.meeting_date,
    'location', v_row.location,
    'agenda', v_row.agenda,
    'participants', v_row.participants,
    'consent_confirmed', v_row.consent_confirmed,
    'audio_path', case when v_row.organizer_profile_id=v_uid then v_row.audio_path else '' end,
    'transcript', v_row.transcript,
    'summary', v_row.summary,
    'decisions', v_row.decisions,
    'actions', v_row.actions,
    'risks', v_row.risks,
    'status', v_row.status,
    'error', v_row.error,
    'is_organizer', v_row.organizer_profile_id=v_uid
  );
end;
$fn$;

create or replace function public.delete_meeting(p_meeting uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  delete from public.meetings
   where id=p_meeting and organizer_profile_id=v_uid;
  if not found then raise exception 'meeting not found or not allowed'; end if;
  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.create_meeting(text,timestamptz,text,text,jsonb,boolean)
  from public, anon, authenticated;
grant execute on function public.create_meeting(text,timestamptz,text,text,jsonb,boolean)
  to authenticated;
revoke all on function public.update_meeting_status(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.update_meeting_status(uuid,text,text)
  to authenticated;
revoke all on function public.update_meeting_summary(uuid,text,text,jsonb,jsonb,jsonb)
  from public, anon, authenticated;
grant execute on function public.update_meeting_summary(uuid,text,text,jsonb,jsonb,jsonb)
  to authenticated;
revoke all on function public.update_meeting_audio(uuid,text)
  from public, anon, authenticated;
grant execute on function public.update_meeting_audio(uuid,text)
  to authenticated;
revoke all on function public.list_meetings(integer)
  from public, anon, authenticated;
grant execute on function public.list_meetings(integer)
  to authenticated;
revoke all on function public.get_meeting(uuid)
  from public, anon, authenticated;
grant execute on function public.get_meeting(uuid)
  to authenticated;
revoke all on function public.delete_meeting(uuid)
  from public, anon, authenticated;
grant execute on function public.delete_meeting(uuid)
  to authenticated;

insert into storage.buckets(id,name,public)
values ('meeting-audio','meeting-audio',false)
on conflict (id) do nothing;

drop policy if exists "meeting audio owner insert" on storage.objects;
create policy "meeting audio owner insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id='meeting-audio'
    and (storage.foldername(name))[1]=auth.uid()::text
  );

drop policy if exists "meeting audio owner read" on storage.objects;
create policy "meeting audio owner read" on storage.objects
  for select to authenticated
  using (
    bucket_id='meeting-audio'
    and (storage.foldername(name))[1]=auth.uid()::text
  );

drop policy if exists "meeting audio owner delete" on storage.objects;
create policy "meeting audio owner delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id='meeting-audio'
    and (storage.foldername(name))[1]=auth.uid()::text
  );

insert into public.app_migrations(version,name,notes)
values (
  'meetings-v1',
  'Meetings and AI summaries',
  'Meeting records, local audio, temporary storage upload and AI summary'
)
on conflict (version) do update set notes=excluded.notes;
