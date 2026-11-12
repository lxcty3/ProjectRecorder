-- ============================================================
-- Community polls v1
--
-- Additive and idempotent. ASCII-only.
--
-- A poll is attached to one community post. Any active member of the
-- poll's enterprise can vote once, and can change their vote while the
-- poll is open. Results are exposed as aggregates only: the vote table
-- is never directly readable and voter ids are never returned.
-- ============================================================

create table if not exists public.community_polls (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null unique
    references public.community_posts(id) on delete cascade,
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  creator_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  question text not null,
  options jsonb not null default '[]'::jsonb,
  allow_note boolean not null default false,
  closes_at timestamptz not null,
  status text not null default 'open'
    check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create index if not exists community_polls_enterprise_idx
  on public.community_polls(enterprise_id, created_at desc);
create index if not exists community_polls_open_idx
  on public.community_polls(status, closes_at);

create table if not exists public.community_poll_votes (
  poll_id uuid not null
    references public.community_polls(id) on delete cascade,
  voter_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  option_id text not null,
  note text not null default '',
  voted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (poll_id, voter_profile_id)
);

create index if not exists community_poll_votes_option_idx
  on public.community_poll_votes(poll_id, option_id);

alter table public.community_polls enable row level security;
alter table public.community_poll_votes enable row level security;

revoke all on public.community_polls from public, anon, authenticated;
revoke all on public.community_poll_votes from public, anon, authenticated;

-- ------------------------------------------------------------
-- Internal helpers
-- ------------------------------------------------------------

create or replace function public._community_poll_member(
  p_poll uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select p_uid is not null and exists (
    select 1
      from public.community_polls p
     where p.id = p_poll
       and public._identity_is_member(p.enterprise_id, p_uid)
  );
$fn$;

revoke all on function public._community_poll_member(uuid,uuid)
  from public, anon, authenticated;

create or replace function public._community_poll_payload(
  p_poll uuid,
  p_uid uuid
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_row public.community_polls%rowtype;
  v_counts jsonb := '{}'::jsonb;
  v_total integer := 0;
  v_my_option text;
  v_my_note text;
  v_owner uuid;
  v_status text;
begin
  select * into v_row from public.community_polls where id = p_poll;
  if not found then
    return null;
  end if;

  select coalesce(jsonb_object_agg(option_id, cnt), '{}'::jsonb)
    into v_counts
    from (
      select option_id, count(*)::int as cnt
        from public.community_poll_votes
       where poll_id = p_poll
       group by option_id
    ) counted;

  select count(*)::int into v_total
    from public.community_poll_votes
   where poll_id = p_poll;

  select option_id, note
    into v_my_option, v_my_note
    from public.community_poll_votes
   where poll_id = p_poll
     and voter_profile_id = p_uid;

  select owner_profile_id into v_owner
    from public.enterprises
   where id = v_row.enterprise_id;

  v_status := case
    when v_row.status = 'open' and v_row.closes_at <= now() then 'closed'
    else v_row.status
  end;

  return jsonb_build_object(
    'id', v_row.id,
    'post_id', v_row.post_id,
    'question', v_row.question,
    'options', v_row.options,
    'allow_note', v_row.allow_note,
    'closes_at', v_row.closes_at,
    'status', v_status,
    'total', v_total,
    'counts', v_counts,
    'my_option', v_my_option,
    'my_note', v_my_note,
    'is_creator', p_uid = v_row.creator_profile_id,
    'can_close', p_uid = v_row.creator_profile_id or p_uid = v_owner
  );
end;
$fn$;

revoke all on function public._community_poll_payload(uuid,uuid)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- Create a poll (also creates its community post)
-- ------------------------------------------------------------

create or replace function public.create_community_poll(
  p_board uuid,
  p_content text,
  p_question text,
  p_options jsonb,
  p_closes_at timestamptz,
  p_allow_note boolean default false
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_name text;
  v_role text;
  v_board uuid := coalesce(p_board, '10000000-0000-4000-8000-000000000001');
  v_question text := trim(coalesce(p_question, ''));
  v_content text := trim(coalesce(p_content, ''));
  v_post uuid;
  v_poll uuid;
  v_count integer := 0;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if not public._community_can_post_board(v_board, v_uid) then
    raise exception 'board posting denied';
  end if;
  if char_length(v_question) < 1 or char_length(v_question) > 120 then
    raise exception 'question must be 1 to 120 characters';
  end if;
  if v_content = '' then
    v_content := v_question;
  end if;
  if char_length(v_content) > 2000 then
    raise exception 'post content is too long';
  end if;
  if p_options is null or jsonb_typeof(p_options) <> 'array' then
    raise exception 'options must be an array';
  end if;
  v_count := jsonb_array_length(p_options);
  if v_count < 2 or v_count > 6 then
    raise exception 'poll needs 2 to 6 options';
  end if;
  if exists (
    select 1
      from jsonb_array_elements(p_options) o
     where char_length(trim(coalesce(o->>'id', ''))) < 1
        or char_length(trim(coalesce(o->>'text', ''))) < 1
        or char_length(trim(o->>'text')) > 80
  ) then
    raise exception 'option text must be 1 to 80 characters';
  end if;
  if (
    select count(distinct o->>'id')
      from jsonb_array_elements(p_options) o
  ) <> v_count then
    raise exception 'option ids must be unique';
  end if;
  if p_closes_at is null
     or p_closes_at <= now()
     or p_closes_at > now() + interval '30 days' then
    raise exception 'close time must be within 30 days';
  end if;

  select active_enterprise_id into v_eid
    from public.profiles where id = v_uid;
  if v_eid is null then
    v_eid := public._identity_ensure_enterprise(v_uid);
  end if;
  if v_eid is null or not public._identity_is_member(v_eid, v_uid) then
    raise exception 'no active company membership';
  end if;

  select name, role into v_name, v_role
    from public.profiles
   where id = v_uid and coalesce(active, true) = true;
  if v_name is null then
    raise exception 'profile not found';
  end if;

  insert into public.community_posts(
    board_id, author_id, author_name, author_role, topic, content,
    unlock_cost, is_required, last_activity_at, updated_at
  ) values (
    v_board, v_uid, v_name, coalesce(v_role, 'employee'), 'poll', v_content,
    0, false, now(), now()
  ) returning id into v_post;

  insert into public.community_polls(
    post_id, enterprise_id, creator_profile_id, question, options,
    allow_note, closes_at
  ) values (
    v_post, v_eid, v_uid, v_question, p_options,
    coalesce(p_allow_note, false), p_closes_at
  ) returning id into v_poll;

  return jsonb_build_object('ok', true, 'post_id', v_post, 'poll_id', v_poll);
end;
$fn$;

revoke all on function public.create_community_poll(
  uuid,text,text,jsonb,timestamptz,boolean
) from public, anon, authenticated;
grant execute on function public.create_community_poll(
  uuid,text,text,jsonb,timestamptz,boolean
) to authenticated;

-- ------------------------------------------------------------
-- Cast / change a vote
-- ------------------------------------------------------------

create or replace function public.vote_community_poll(
  p_poll uuid,
  p_option text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.community_polls%rowtype;
  v_has_option boolean := false;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  select * into v_row
    from public.community_polls
   where id = p_poll
   for update;
  if not found then
    raise exception 'poll not found';
  end if;
  if not public._community_poll_member(p_poll, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if v_row.status <> 'open' or v_row.closes_at <= now() then
    update public.community_polls
       set status = 'closed', closed_at = coalesce(closed_at, now())
     where id = p_poll and status = 'open';
    raise exception 'poll closed';
  end if;
  select exists (
    select 1 from jsonb_array_elements(v_row.options) o
     where o->>'id' = p_option
  ) into v_has_option;
  if not v_has_option then
    raise exception 'invalid option';
  end if;

  insert into public.community_poll_votes(
    poll_id, voter_profile_id, option_id, note
  ) values (
    p_poll, v_uid, p_option,
    case when v_row.allow_note then left(coalesce(p_note, ''), 300) else '' end
  )
  on conflict (poll_id, voter_profile_id) do update
    set option_id = excluded.option_id,
        note = excluded.note,
        updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'poll', public._community_poll_payload(p_poll, v_uid)
  );
end;
$fn$;

revoke all on function public.vote_community_poll(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.vote_community_poll(uuid,text,text)
  to authenticated;

-- ------------------------------------------------------------
-- Close a poll (creator or enterprise owner)
-- ------------------------------------------------------------

create or replace function public.close_community_poll(p_poll uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.community_polls%rowtype;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  select * into v_row
    from public.community_polls
   where id = p_poll
   for update;
  if not found then
    raise exception 'poll not found';
  end if;
  select owner_profile_id into v_owner
    from public.enterprises
   where id = v_row.enterprise_id;
  if v_uid <> v_row.creator_profile_id and v_uid <> v_owner then
    raise exception 'not allowed';
  end if;
  update public.community_polls
     set status = 'closed', closed_at = coalesce(closed_at, now())
   where id = p_poll;
  return jsonb_build_object(
    'ok', true,
    'poll', public._community_poll_payload(p_poll, v_uid)
  );
end;
$fn$;

revoke all on function public.close_community_poll(uuid)
  from public, anon, authenticated;
grant execute on function public.close_community_poll(uuid)
  to authenticated;

-- ------------------------------------------------------------
-- Feed lookup: poll payloads for the posts currently on screen
-- ------------------------------------------------------------

create or replace function public.get_community_polls_for_posts(
  p_posts uuid[]
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_polls jsonb;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  select coalesce(jsonb_agg(public._community_poll_payload(p.id, v_uid)), '[]'::jsonb)
    into v_polls
    from public.community_polls p
   where p.post_id = any(coalesce(p_posts, '{}'::uuid[]))
     and public._community_poll_member(p.id, v_uid);
  return jsonb_build_object('ok', true, 'polls', v_polls);
end;
$fn$;

revoke all on function public.get_community_polls_for_posts(uuid[])
  from public, anon, authenticated;
grant execute on function public.get_community_polls_for_posts(uuid[])
  to authenticated;

insert into public.app_migrations(version, name, notes)
values (
  'community-polls-v1',
  'Community polls',
  'Anonymized community polls with one vote per enterprise member'
)
on conflict (version) do update set notes = excluded.notes;
