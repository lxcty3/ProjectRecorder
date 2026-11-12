-- ============================================================
-- Enterprise votes v1 + unified vote center support
--
-- Two formal vote modes:
--   headcount: one active member = one vote, anonymous aggregate
--   shares:    one share = one vote, named and auditable
--
-- Additive and idempotent. ASCII-only.
-- ============================================================

create table if not exists public.enterprise_votes (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null
    references public.enterprises(id) on delete cascade,
  creator_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  title text not null,
  description text not null default '',
  mode text not null check (mode in ('headcount','shares')),
  quorum_bps integer not null default 5000
    check (quorum_bps between 0 and 10000),
  status text not null default 'open'
    check (status in ('open','closed','cancelled')),
  closes_at timestamptz not null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  result text not null default ''
    check (result in ('','passed','rejected','cancelled'))
);

create index if not exists enterprise_votes_scope_idx
  on public.enterprise_votes(enterprise_id, created_at desc);
create index if not exists enterprise_votes_open_idx
  on public.enterprise_votes(status, closes_at);

create table if not exists public.enterprise_vote_records (
  vote_id uuid not null
    references public.enterprise_votes(id) on delete cascade,
  voter_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  weight numeric(18,4) not null default 1,
  note text not null default '',
  voted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (vote_id, voter_profile_id)
);

create index if not exists enterprise_vote_records_choice_idx
  on public.enterprise_vote_records(vote_id, choice);

alter table public.enterprise_votes enable row level security;
alter table public.enterprise_vote_records enable row level security;

revoke all on public.enterprise_votes from public, anon, authenticated;
revoke all on public.enterprise_vote_records from public, anon, authenticated;

-- ------------------------------------------------------------
-- Permission helpers
-- ------------------------------------------------------------

create or replace function public._enterprise_vote_can_create(
  p_eid uuid,
  p_uid uuid,
  p_mode text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_perms jsonb;
  v_owner uuid;
begin
  if not public._identity_is_member(p_eid, p_uid) then
    return false;
  end if;
  select owner_profile_id into v_owner
    from public.enterprises where id = p_eid;
  v_perms := public._identity_role_permissions(p_eid, p_uid);
  if p_mode = 'headcount' then
    return p_uid = v_owner
      or v_perms ? 'people.manage'
      or v_perms ? 'governance.manage';
  end if;
  if p_mode = 'shares' then
    return public._identity_shares(p_eid, p_uid) > 0
      or public._identity_is_board_director(p_eid, p_uid)
      or v_perms ? 'governance.vote'
      or v_perms ? 'governance.manage';
  end if;
  return false;
end;
$fn$;

revoke all on function public._enterprise_vote_can_create(uuid,uuid,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- Payload: aggregate + viewer's own state
-- ------------------------------------------------------------

create or replace function public._enterprise_vote_payload(
  p_vote uuid,
  p_uid uuid
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_row public.enterprise_votes%rowtype;
  v_eligible integer := 0;
  v_total_shares numeric := 0;
  v_cast_count integer := 0;
  v_cast_shares numeric := 0;
  v_yes_count integer := 0;
  v_no_count integer := 0;
  v_abstain_count integer := 0;
  v_yes_shares numeric := 0;
  v_no_shares numeric := 0;
  v_abstain_shares numeric := 0;
  v_my_choice text := '';
  v_my_weight numeric := 0;
  v_status text;
  v_quorum_met boolean := false;
  v_passed boolean := false;
  v_details jsonb := '[]'::jsonb;
  v_owner uuid;
begin
  select * into v_row from public.enterprise_votes where id = p_vote;
  if not found then return null; end if;
  if not public._identity_is_member(v_row.enterprise_id, p_uid) then
    return null;
  end if;

  select count(*)::integer into v_eligible
    from public.enterprise_members m
   where m.enterprise_id = v_row.enterprise_id and m.status = 'active';

  select coalesce(sum(s.shares),0) into v_total_shares
    from public.enterprise_shareholders s
    join public.enterprise_members m
      on m.enterprise_id = s.enterprise_id
     and m.profile_id = s.profile_id
     and m.status = 'active'
   where s.enterprise_id = v_row.enterprise_id and s.shares > 0;

  select
    count(*)::integer,
    coalesce(sum(weight),0),
    count(*) filter (where choice = 'yes')::integer,
    count(*) filter (where choice = 'no')::integer,
    count(*) filter (where choice = 'abstain')::integer,
    coalesce(sum(weight) filter (where choice = 'yes'),0),
    coalesce(sum(weight) filter (where choice = 'no'),0),
    coalesce(sum(weight) filter (where choice = 'abstain'),0)
    into v_cast_count, v_cast_shares, v_yes_count, v_no_count, v_abstain_count,
         v_yes_shares, v_no_shares, v_abstain_shares
    from public.enterprise_vote_records
   where vote_id = p_vote;

  select choice, weight into v_my_choice, v_my_weight
    from public.enterprise_vote_records
   where vote_id = p_vote and voter_profile_id = p_uid;

  select owner_profile_id into v_owner
    from public.enterprises where id = v_row.enterprise_id;

  v_status := case
    when v_row.status = 'open' and v_row.closes_at <= now() then 'closed'
    else v_row.status
  end;

  if v_row.mode = 'headcount' then
    v_quorum_met := v_eligible > 0
      and v_cast_count * 10000 >= v_eligible * v_row.quorum_bps;
    v_passed := v_quorum_met and v_yes_count > v_no_count;
  else
    v_quorum_met := v_total_shares > 0
      and v_cast_shares * 10000 >= v_total_shares * v_row.quorum_bps;
    v_passed := v_quorum_met and v_yes_shares > v_no_shares;
  end if;

  if v_row.mode = 'shares' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'profile_id', r.voter_profile_id,
      'name', p.name,
      'shares', r.weight,
      'choice', r.choice,
      'voted_at', r.voted_at
    ) order by r.voted_at), '[]'::jsonb)
      into v_details
      from public.enterprise_vote_records r
      join public.profiles p on p.id = r.voter_profile_id
     where r.vote_id = p_vote;
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'description', v_row.description,
    'mode', v_row.mode,
    'status', v_status,
    'quorum_bps', v_row.quorum_bps,
    'closes_at', v_row.closes_at,
    'created_at', v_row.created_at,
    'creator_profile_id', v_row.creator_profile_id,
    'creator_name', (select p.name from public.profiles p where p.id = v_row.creator_profile_id),
    'eligible_count', v_eligible,
    'eligible_shares', v_total_shares,
    'cast_count', v_cast_count,
    'cast_shares', v_cast_shares,
    'yes_count', v_yes_count,
    'no_count', v_no_count,
    'abstain_count', v_abstain_count,
    'yes_shares', v_yes_shares,
    'no_shares', v_no_shares,
    'abstain_shares', v_abstain_shares,
    'my_choice', coalesce(v_my_choice,''),
    'my_weight', coalesce(v_my_weight,
      case when v_row.mode = 'shares'
        then public._identity_shares(v_row.enterprise_id, p_uid) else 1 end),
    'can_vote', v_status = 'open' and (
      (v_row.mode = 'headcount'
        and public._identity_is_member(v_row.enterprise_id, p_uid))
      or (v_row.mode = 'shares'
        and public._identity_shares(v_row.enterprise_id, p_uid) > 0)
    ),
    'can_close', p_uid = v_row.creator_profile_id or p_uid = v_owner,
    'quorum_met', v_quorum_met,
    'passed', v_passed,
    'result', case
      when v_status = 'open' then ''
      when v_row.result <> '' then v_row.result
      when v_passed then 'passed' else 'rejected'
    end,
    'details', v_details
  );
end;
$fn$;

revoke all on function public._enterprise_vote_payload(uuid,uuid)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- Create / vote / close
-- ------------------------------------------------------------

create or replace function public.create_enterprise_vote(
  p_title text,
  p_description text,
  p_mode text,
  p_closes_at timestamptz,
  p_quorum_bps integer default 5000
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_title text := trim(coalesce(p_title,''));
  v_desc text := trim(coalesce(p_description,''));
  v_mode text := lower(trim(coalesce(p_mode,'')));
  v_quorum integer := greatest(0, least(coalesce(p_quorum_bps,5000),10000));
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if char_length(v_title) < 1 or char_length(v_title) > 120 then
    raise exception 'title must be 1 to 120 characters';
  end if;
  if char_length(v_desc) > 2000 then
    raise exception 'description is too long';
  end if;
  if v_mode not in ('headcount','shares') then
    raise exception 'invalid vote mode';
  end if;
  if p_closes_at is null or p_closes_at <= now()
     or p_closes_at > now() + interval '30 days' then
    raise exception 'close time must be within 30 days';
  end if;
  select active_enterprise_id into v_eid from public.profiles where id = v_uid;
  if v_eid is null then v_eid := public._identity_ensure_enterprise(v_uid); end if;
  if v_eid is null or not public._identity_is_member(v_eid, v_uid) then
    raise exception 'no active company membership';
  end if;
  if not public._enterprise_vote_can_create(v_eid, v_uid, v_mode) then
    raise exception 'not allowed to create this vote';
  end if;
  insert into public.enterprise_votes(
    enterprise_id, creator_profile_id, title, description, mode,
    quorum_bps, closes_at
  ) values (
    v_eid, v_uid, v_title, v_desc, v_mode, v_quorum, p_closes_at
  ) returning id into v_id;
  return jsonb_build_object('ok', true, 'vote_id', v_id);
end;
$fn$;

revoke all on function public.create_enterprise_vote(text,text,text,timestamptz,integer)
  from public, anon, authenticated;
grant execute on function public.create_enterprise_vote(text,text,text,timestamptz,integer)
  to authenticated;

create or replace function public.cast_enterprise_vote(
  p_vote uuid,
  p_choice text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.enterprise_votes%rowtype;
  v_mode text;
  v_weight numeric;
  v_choice text := lower(trim(coalesce(p_choice,'')));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.enterprise_votes where id = p_vote for update;
  if not found then raise exception 'vote not found'; end if;
  if v_row.status <> 'open' or v_row.closes_at <= now() then
    update public.enterprise_votes
       set status = 'closed', closed_at = coalesce(closed_at, now())
     where id = p_vote and status = 'open';
    raise exception 'vote closed';
  end if;
  if not public._identity_is_member(v_row.enterprise_id, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  v_mode := v_row.mode;
  if v_mode = 'headcount' then
    v_weight := 1;
  else
    v_weight := public._identity_shares(v_row.enterprise_id, v_uid);
    if v_weight <= 0 then
      raise exception 'only shareholders can vote';
    end if;
  end if;
  if v_choice not in ('yes','no','abstain') then
    raise exception 'invalid choice';
  end if;
  insert into public.enterprise_vote_records(
    vote_id, voter_profile_id, choice, weight, note
  ) values (
    p_vote, v_uid, v_choice, v_weight, left(coalesce(p_note,''),300)
  )
  on conflict (vote_id, voter_profile_id) do update
    set choice = excluded.choice,
        weight = excluded.weight,
        note = excluded.note,
        updated_at = now();
  return jsonb_build_object(
    'ok', true,
    'vote', public._enterprise_vote_payload(p_vote, v_uid)
  );
end;
$fn$;

revoke all on function public.cast_enterprise_vote(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.cast_enterprise_vote(uuid,text,text)
  to authenticated;

create or replace function public.close_enterprise_vote(p_vote uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.enterprise_votes%rowtype;
  v_owner uuid;
  v_payload jsonb;
  v_result text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.enterprise_votes where id = p_vote for update;
  if not found then raise exception 'vote not found'; end if;
  select owner_profile_id into v_owner
    from public.enterprises where id = v_row.enterprise_id;
  if v_uid <> v_row.creator_profile_id and v_uid <> v_owner then
    raise exception 'not allowed';
  end if;
  v_payload := public._enterprise_vote_payload(p_vote, v_uid);
  v_result := case when coalesce((v_payload->>'passed')::boolean,false)
    then 'passed' else 'rejected' end;
  update public.enterprise_votes
     set status = 'closed', closed_at = coalesce(closed_at, now()),
         result = v_result
   where id = p_vote;
  return jsonb_build_object(
    'ok', true,
    'vote', public._enterprise_vote_payload(p_vote, v_uid)
  );
end;
$fn$;

revoke all on function public.close_enterprise_vote(uuid)
  from public, anon, authenticated;
grant execute on function public.close_enterprise_vote(uuid)
  to authenticated;

-- ------------------------------------------------------------
-- Lists
-- ------------------------------------------------------------

create or replace function public.list_enterprise_votes(
  p_scope text default 'all',
  p_limit integer default 100
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_scope text := lower(trim(coalesce(p_scope,'all')));
  v_rows jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select active_enterprise_id into v_eid from public.profiles where id = v_uid;
  if v_eid is null then v_eid := public._identity_ensure_enterprise(v_uid); end if;
  if v_eid is null then raise exception 'no active company'; end if;
  select coalesce(jsonb_agg(payload order by created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select v.id, v.created_at,
             public._enterprise_vote_payload(v.id, v_uid) as payload
        from public.enterprise_votes v
       where v.enterprise_id = v_eid
         and v.status <> 'cancelled'
         and (
           v_scope = 'all'
           or (v_scope = 'mine' and v.creator_profile_id = v_uid)
           or (v_scope = 'closed'
               and (v.status <> 'open' or v.closes_at <= now()))
           or (v_scope = 'pending'
               and v.status = 'open' and v.closes_at > now()
               and public._enterprise_vote_payload(v.id, v_uid)->>'can_vote' = 'true'
               and coalesce(public._enterprise_vote_payload(v.id, v_uid)->>'my_choice','') = '')
         )
       order by v.created_at desc
       limit greatest(1, least(coalesce(p_limit,100), 200))
    ) q;
  return jsonb_build_object('ok', true, 'votes', v_rows);
end;
$fn$;

revoke all on function public.list_enterprise_votes(text,integer)
  from public, anon, authenticated;
grant execute on function public.list_enterprise_votes(text,integer)
  to authenticated;

create or replace function public.list_pending_community_polls()
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_polls jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select active_enterprise_id into v_eid from public.profiles where id = v_uid;
  if v_eid is null then v_eid := public._identity_ensure_enterprise(v_uid); end if;
  if v_eid is null then raise exception 'no active company'; end if;
  select coalesce(jsonb_agg(
      public._community_poll_payload(p.id, v_uid) order by p.created_at desc
    ), '[]'::jsonb)
    into v_polls
    from public.community_polls p
   where p.enterprise_id = v_eid
     and p.status = 'open'
     and p.closes_at > now()
     and public._identity_is_member(p.enterprise_id, v_uid)
     and not exists (
       select 1 from public.community_poll_votes r
        where r.poll_id = p.id and r.voter_profile_id = v_uid
     );
  return jsonb_build_object('ok', true, 'polls', v_polls);
end;
$fn$;

revoke all on function public.list_pending_community_polls()
  from public, anon, authenticated;
grant execute on function public.list_pending_community_polls()
  to authenticated;

insert into public.app_migrations(version, name, notes)
values (
  'enterprise-votes-v1',
  'Enterprise votes',
  'Unified vote center: headcount and share-weighted formal votes'
)
on conflict (version) do update set notes = excluded.notes;
