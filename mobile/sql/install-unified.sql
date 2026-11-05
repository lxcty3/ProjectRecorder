-- ProjectRecorder 2.0 cloud installation
-- Run this entire file once in Supabase SQL Editor.

-- Part 1: shared knowledge community
-- ============================================================
-- Knowledge Planet community feed
--
-- Run this once in Supabase -> SQL Editor.
-- ASCII-only on purpose, matching the other mobile/sql files.
--
-- Every authenticated account can read every post and publish
-- a post. Identity fields are written by a SECURITY DEFINER
-- function from profiles, so the client cannot spoof a name.
-- ============================================================

create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null default '',
  author_role text not null default 'employee',
  topic text not null default 'share',
  content text not null,
  unlock_cost integer not null default 0 check (unlock_cost >= 0),
  is_required boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.community_posts
  add column if not exists unlock_cost integer not null default 0
    check (unlock_cost >= 0),
  add column if not exists is_required boolean not null default false;

create index if not exists idx_community_posts_created
  on public.community_posts(created_at desc);
create index if not exists idx_community_posts_author
  on public.community_posts(author_id, created_at desc);

alter table public.community_posts enable row level security;

-- All signed-in members share one planet.
drop policy if exists "community posts readable by members"
  on public.community_posts;
create policy "community posts readable by members"
  on public.community_posts for select to authenticated
  using (author_id = auth.uid() or is_required or unlock_cost = 0);

-- Direct writes are not allowed. Use the RPC below so author
-- fields come from the account profile rather than the client.
revoke insert, update, delete on public.community_posts from anon, authenticated;
revoke select on public.community_posts from anon;
grant select on public.community_posts to authenticated;


drop function if exists public.post_community_message(text, text);

create or replace function public.post_community_message(
  p_content text,
  p_topic text default 'share',
  p_unlock_cost integer default 0,
  p_is_required boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $post_community$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_role text;
  v_topic text := lower(trim(coalesce(p_topic, 'share')));
  v_content text := trim(coalesce(p_content, ''));
  v_unlock_cost integer := greatest(coalesce(p_unlock_cost, 0), 0);
  v_is_required boolean := coalesce(p_is_required, false);
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  select name, role into v_name, v_role
    from public.profiles
   where id = v_uid and coalesce(active, true) = true;

  if v_name is null then
    raise exception 'profile not found';
  end if;

  if char_length(v_content) < 1 then
    raise exception 'message is empty';
  end if;
  if char_length(v_content) > 2000 then
    raise exception 'message is too long';
  end if;
  if char_length(v_topic) < 1 or char_length(v_topic) > 24 then
    v_topic := 'share';
  end if;

  insert into public.community_posts
    (author_id, author_name, author_role, topic, content,
     unlock_cost, is_required)
  values
    (v_uid, v_name, coalesce(v_role, 'employee'), v_topic, v_content,
     v_unlock_cost, v_is_required)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$post_community$;

revoke all on function public.post_community_message(text, text, integer, boolean) from public;
grant execute on function public.post_community_message(text, text, integer, boolean)
  to authenticated;


create or replace function public.delete_my_community_message(p_post_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $delete_community$
declare
  v_uid uuid := auth.uid();
  v_deleted integer;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;

  delete from public.community_posts
   where id = p_post_id and author_id = v_uid;

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$delete_community$;

revoke all on function public.delete_my_community_message(uuid) from public;
grant execute on function public.delete_my_community_message(uuid)
  to authenticated;


-- Realtime is optional. The clients also poll every few seconds,
-- so posting still works if the publication is not configured.
do $realtime$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
      from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'community_posts'
  ) then
    alter publication supabase_realtime add table public.community_posts;
  end if;
end;
$realtime$;

-- Part 2: unified projects, tasks, merit, rewards, leave and knowledge
-- ============================================================
-- Unified ProjectRecorder platform
--
-- Additive migration. Existing mobile tables and data are kept.
-- Run after the existing mobile/sql setup files.
-- ASCII-only on purpose.
-- ============================================================

-- ---------------------------------------------------------- identity/version
alter table public.profiles
  add column if not exists version integer not null default 1,
  add column if not exists deleted_at timestamptz;

-- ---------------------------------------------------------- cloud projects
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  boss_id     uuid not null references public.profiles(id) on delete cascade,
  name        text not null,
  owner       text not null default '',
  client      text not null default '',
  status      text not null default '???',
  priority    text not null default '?',
  start_date  date,
  due_date    date,
  budget      numeric not null default 0,
  cost        numeric not null default 0,
  progress    integer not null default 0,
  note        text not null default '',
  version     integer not null default 1,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists projects_boss_idx
  on public.projects(boss_id, updated_at desc);

create table if not exists public.project_steps (
  id          uuid primary key default gen_random_uuid(),
  boss_id     uuid not null references public.profiles(id) on delete cascade,
  project_id  uuid not null references public.projects(id) on delete cascade,
  seq         integer not null default 0,
  name        text not null,
  owner       text not null default '',
  status      text not null default '???',
  start_date  date,
  due_date    date,
  progress    integer not null default 0,
  note        text not null default '',
  version     integer not null default 1,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists project_steps_project_idx
  on public.project_steps(project_id, seq);

-- ---------------------------------------------------------- task/worklog links
alter table public.tasks
  add column if not exists project_id uuid references public.projects(id) on delete set null,
  add column if not exists step_id uuid references public.project_steps(id) on delete set null,
  add column if not exists version integer not null default 1,
  add column if not exists archived_at timestamptz,
  add column if not exists auto_settle_at timestamptz;

alter table public.worklogs
  add column if not exists project_id uuid references public.projects(id) on delete set null,
  add column if not exists step_id uuid references public.project_steps(id) on delete set null,
  add column if not exists version integer not null default 1,
  add column if not exists approval_status text not null default 'pending',
  add column if not exists approved_by uuid references public.profiles(id) on delete set null,
  add column if not exists approved_at timestamptz,
  add column if not exists idempotency_key text;

create unique index if not exists worklogs_idempotency_idx
  on public.worklogs(boss_id, idempotency_key)
  where idempotency_key is not null and idempotency_key <> '';

-- ---------------------------------------------------------- merit settlement
-- ---------------------------------------------------------- task grading
alter table public.tasks
  add column if not exists est_merit integer,
  add column if not exists grade text,
  add column if not exists merit_awarded integer,
  add column if not exists graded_at timestamptz,
  add column if not exists graded_by uuid references public.profiles(id) on delete set null;

alter table public.merit_ledger
  add column if not exists status text not null default 'posted',
  add column if not exists settled_at timestamptz,
  add column if not exists version integer not null default 1;

-- ---------------------------------------------------------- rewards/leave
alter table public.rewards
  add column if not exists stock integer,
  add column if not exists version integer not null default 1,
  add column if not exists archived_at timestamptz;

alter table public.redemptions
  add column if not exists reserved_at timestamptz default now(),
  add column if not exists version integer not null default 1;

alter table public.leave_requests
  add column if not exists from_half boolean not null default false,
  add column if not exists to_half boolean not null default false,
  add column if not exists days numeric not null default 0,
  add column if not exists version integer not null default 1,
  add column if not exists archived_at timestamptz;
-- ---------------------------------------------------------- private knowledge
create table if not exists public.knowledge_items (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  boss_id      uuid references public.profiles(id) on delete set null,
  title        text not null,
  content      text not null default '',
  zone         text not null default 'actual',
  kind         text not null default 'explicit',
  source       text not null default '',
  tags         text not null default '',
  project_id   uuid references public.projects(id) on delete set null,
  importance   integer not null default 3 check (importance between 1 and 5),
  status       text not null default 'settled',
  next_review  date,
  version      integer not null default 1,
  archived_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists knowledge_items_owner_idx
  on public.knowledge_items(owner_id, updated_at desc);

create table if not exists public.knowledge_links (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  from_id     uuid not null references public.knowledge_items(id) on delete cascade,
  to_id       uuid not null references public.knowledge_items(id) on delete cascade,
  relation    text not null default 'related',
  note        text not null default '',
  version     integer not null default 1,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  unique(owner_id, from_id, to_id),
  check(from_id <> to_id)
);

create table if not exists public.knowledge_reflections (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.profiles(id) on delete cascade,
  knowledge_id uuid not null references public.knowledge_items(id) on delete cascade,
  prompt       text not null default '',
  content      text not null default '',
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------- audit/calendar
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  boss_id     uuid references public.profiles(id) on delete set null,
  actor_id    uuid references public.profiles(id) on delete set null,
  table_name  text not null,
  row_id      text not null,
  action      text not null,
  before_data jsonb,
  after_data  jsonb,
  reason      text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists audit_log_boss_idx
  on public.audit_log(boss_id, created_at desc);

create table if not exists public.holiday_calendar (
  id          uuid primary key default gen_random_uuid(),
  boss_id     uuid not null references public.profiles(id) on delete cascade,
  holiday     date not null,
  name        text not null default '',
  is_workday  boolean not null default false,
  created_at  timestamptz not null default now(),
  unique(boss_id, holiday)
);

-- ---------------------------------------------------------- RLS: projects
alter table public.projects enable row level security;
alter table public.project_steps enable row level security;
alter table public.knowledge_items enable row level security;
alter table public.knowledge_links enable row level security;
alter table public.knowledge_reflections enable row level security;
alter table public.audit_log enable row level security;
alter table public.holiday_calendar enable row level security;

drop policy if exists "team reads projects" on public.projects;
create policy "team reads projects" on public.projects
  for select to authenticated
  using (
    boss_id = auth.uid()
    or boss_id = (select boss_id from public.profiles where id = auth.uid())
  );

drop policy if exists "boss writes projects" on public.projects;
create policy "boss writes projects" on public.projects
  for all to authenticated
  using (boss_id = auth.uid()) with check (boss_id = auth.uid());

drop policy if exists "team reads project steps" on public.project_steps;
create policy "team reads project steps" on public.project_steps
  for select to authenticated
  using (
    boss_id = auth.uid()
    or boss_id = (select boss_id from public.profiles where id = auth.uid())
  );

drop policy if exists "boss writes project steps" on public.project_steps;
create policy "boss writes project steps" on public.project_steps
  for all to authenticated
  using (boss_id = auth.uid()) with check (boss_id = auth.uid());

drop policy if exists "owner reads knowledge" on public.knowledge_items;
create policy "owner reads knowledge" on public.knowledge_items
  for select to authenticated using (owner_id = auth.uid());
drop policy if exists "owner writes knowledge" on public.knowledge_items;
create policy "owner writes knowledge" on public.knowledge_items
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "owner reads knowledge links" on public.knowledge_links;
create policy "owner reads knowledge links" on public.knowledge_links
  for select to authenticated using (owner_id = auth.uid());
drop policy if exists "owner writes knowledge links" on public.knowledge_links;
create policy "owner writes knowledge links" on public.knowledge_links
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "owner reads knowledge reflections" on public.knowledge_reflections;
create policy "owner reads knowledge reflections" on public.knowledge_reflections
  for select to authenticated using (owner_id = auth.uid());
drop policy if exists "owner writes knowledge reflections" on public.knowledge_reflections;
create policy "owner writes knowledge reflections" on public.knowledge_reflections
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "team reads audit" on public.audit_log;
create policy "team reads audit" on public.audit_log
  for select to authenticated using (
    boss_id = auth.uid()
    or boss_id = (select boss_id from public.profiles where id = auth.uid())
  );
revoke insert, update, delete on public.audit_log from anon, authenticated;

drop policy if exists "team reads holidays" on public.holiday_calendar;
create policy "team reads holidays" on public.holiday_calendar
  for select to authenticated using (
    boss_id = auth.uid()
    or boss_id = (select boss_id from public.profiles where id = auth.uid())
  );
drop policy if exists "boss writes holidays" on public.holiday_calendar;
create policy "boss writes holidays" on public.holiday_calendar
  for all to authenticated
  using (boss_id = auth.uid()) with check (boss_id = auth.uid());
-- ---------------------------------------------------------- versioned writes
create or replace function public.save_project(
  p_id uuid, p_version integer, p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid := p_id;
  v_row public.projects%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_id is null then
    insert into public.projects(
      boss_id,name,owner,client,status,priority,start_date,due_date,
      budget,cost,progress,note
    ) values (
      v_uid,trim(coalesce(p_data->>'name','')),
      coalesce(p_data->>'owner',''),coalesce(p_data->>'client',''),
      coalesce(p_data->>'status',U&'\8FDB\884C\4E2D'),
      coalesce(p_data->>'priority',U&'\4E2D'),
      nullif(p_data->>'start_date','')::date,
      nullif(p_data->>'due_date','')::date,
      coalesce((p_data->>'budget')::numeric,0),
      coalesce((p_data->>'cost')::numeric,0),
      least(100,greatest(0,coalesce((p_data->>'progress')::integer,0))),
      coalesce(p_data->>'note','')
    ) returning * into v_row;
  else
    update public.projects set
      name=coalesce(p_data->>'name',name),
      owner=coalesce(p_data->>'owner',owner),
      client=coalesce(p_data->>'client',client),
      status=coalesce(p_data->>'status',status),
      priority=coalesce(p_data->>'priority',priority),
      start_date=coalesce(nullif(p_data->>'start_date','')::date,start_date),
      due_date=coalesce(nullif(p_data->>'due_date','')::date,due_date),
      budget=coalesce((p_data->>'budget')::numeric,budget),
      cost=coalesce((p_data->>'cost')::numeric,cost),
      progress=least(100,greatest(0,coalesce((p_data->>'progress')::integer,progress))),
      note=coalesce(p_data->>'note',note),
      version=version+1,updated_at=now()
    where id=v_id and boss_id=v_uid
      and version=coalesce(p_version,version)
    returning * into v_row;
    if not found then raise exception 'version conflict or project not yours'; end if;
  end if;
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.save_project_step(
  p_id uuid, p_project uuid, p_version integer, p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id uuid := p_id;
  v_row public.project_steps%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists(select 1 from public.projects where id=p_project and boss_id=v_uid) then
    raise exception 'project not yours';
  end if;
  if v_id is null then
    insert into public.project_steps(
      boss_id,project_id,seq,name,owner,status,start_date,due_date,progress,note
    ) values (
      v_uid,p_project,coalesce((p_data->>'seq')::integer,0),
      trim(coalesce(p_data->>'name','')),coalesce(p_data->>'owner',''),
      coalesce(p_data->>'status',U&'\672A\5F00\59CB'),
      nullif(p_data->>'start_date','')::date,
      nullif(p_data->>'due_date','')::date,
      least(100,greatest(0,coalesce((p_data->>'progress')::integer,0))),
      coalesce(p_data->>'note','')
    ) returning * into v_row;
  else
    update public.project_steps set
      seq=coalesce((p_data->>'seq')::integer,seq),
      name=coalesce(p_data->>'name',name),
      owner=coalesce(p_data->>'owner',owner),
      status=coalesce(p_data->>'status',status),
      start_date=coalesce(nullif(p_data->>'start_date','')::date,start_date),
      due_date=coalesce(nullif(p_data->>'due_date','')::date,due_date),
      progress=least(100,greatest(0,coalesce((p_data->>'progress')::integer,progress))),
      note=coalesce(p_data->>'note',note),
      version=version+1,updated_at=now()
    where id=v_id and project_id=p_project and boss_id=v_uid
      and version=coalesce(p_version,version)
    returning * into v_row;
    if not found then raise exception 'version conflict or step not yours'; end if;
  end if;
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.save_knowledge_item(
  p_id uuid, p_version integer, p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_boss uuid;
  v_id uuid := p_id;
  v_row public.knowledge_items%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select coalesce(boss_id,id) into v_boss from public.profiles where id=v_uid;
  if v_id is null then
    insert into public.knowledge_items(
      owner_id,boss_id,title,content,zone,kind,source,tags,
      project_id,importance,status,next_review
    ) values (
      v_uid,v_boss,trim(coalesce(p_data->>'title','')),
      coalesce(p_data->>'content',''),coalesce(p_data->>'zone','actual'),
      coalesce(p_data->>'kind','explicit'),coalesce(p_data->>'source',''),
      coalesce(p_data->>'tags',''),nullif(p_data->>'project_id','')::uuid,
      least(5,greatest(1,coalesce((p_data->>'importance')::integer,3))),
      coalesce(p_data->>'status','settled'),
      nullif(p_data->>'next_review','')::date
    ) returning * into v_row;
  else
    update public.knowledge_items set
      title=coalesce(p_data->>'title',title),
      content=coalesce(p_data->>'content',content),
      zone=coalesce(p_data->>'zone',zone),
      kind=coalesce(p_data->>'kind',kind),
      source=coalesce(p_data->>'source',source),
      tags=coalesce(p_data->>'tags',tags),
      project_id=coalesce(nullif(p_data->>'project_id','')::uuid,project_id),
      importance=least(5,greatest(1,coalesce((p_data->>'importance')::integer,importance))),
      status=coalesce(p_data->>'status',status),
      next_review=coalesce(nullif(p_data->>'next_review','')::date,next_review),
      version=version+1,updated_at=now()
    where id=v_id and owner_id=v_uid
      and version=coalesce(p_version,version)
    returning * into v_row;
    if not found then raise exception 'version conflict or knowledge not yours'; end if;
  end if;
  return to_jsonb(v_row);
end;
$fn$;

revoke all on function public.save_project(uuid,integer,jsonb) from public;
revoke all on function public.save_project_step(uuid,uuid,integer,jsonb) from public;
revoke all on function public.save_knowledge_item(uuid,integer,jsonb) from public;
grant execute on function public.save_project(uuid,integer,jsonb) to authenticated;
grant execute on function public.save_project_step(uuid,uuid,integer,jsonb) to authenticated;
grant execute on function public.save_knowledge_item(uuid,integer,jsonb) to authenticated;
-- ---------------------------------------------------------- points/rewards
create unique index if not exists redemptions_one_pending_reward_idx
  on public.redemptions(profile_id, reward_id)
  where status = 'pending';

create or replace function public.merit_available(p_profile uuid default null)
returns integer
language sql stable security definer
set search_path = public, auth, pg_temp
as $fn$
  with me as (
    select coalesce(p_profile, auth.uid()) as id
  )
  select coalesce((
    select sum(amount) from public.merit_ledger
    where profile_id = (select id from me) and status = 'posted'
  ),0)::integer - coalesce((
    select sum(cost) from public.redemptions
    where profile_id = (select id from me) and status = 'pending'
  ),0)::integer;
$fn$;

create or replace function public.redeem_reward(p_reward uuid)
returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_reward public.rewards%rowtype;
  v_available integer;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_reward from public.rewards
   where id=p_reward and archived_at is null;
  if not found then raise exception 'no such reward'; end if;
  if not v_reward.active then raise exception 'reward is inactive'; end if;
  if v_reward.stock is not null and v_reward.stock <= 0 then
    raise exception 'out of stock';
  end if;
  if exists(
    select 1 from public.redemptions
    where profile_id=v_uid and reward_id=p_reward and status='pending'
  ) then raise exception 'already pending'; end if;

  v_available := public.merit_available(v_uid);
  if v_available < v_reward.cost then
    raise exception 'not enough points, available %', v_available;
  end if;

  insert into public.redemptions(boss_id,profile_id,reward_id,title,cost,reserved_at)
  values(v_reward.boss_id,v_uid,v_reward.id,v_reward.title,v_reward.cost,now())
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,'id',v_id,'cost',v_reward.cost,
    'available',v_available-v_reward.cost
  );
end;
$fn$;

create or replace function public.decide_redemption(
  p_redemption uuid, p_given boolean
)
returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_row public.redemptions%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.redemptions
   where id=p_redemption and boss_id=v_uid and status='pending';
  if not found then raise exception 'already decided or not yours'; end if;

  update public.redemptions
     set status=case when coalesce(p_given,false) then 'given' else 'rejected' end,
         decided_at=now(),version=version+1
   where id=v_row.id;

  if coalesce(p_given,false) then
    if not exists(
      select 1 from public.merit_ledger
      where kind='redeem' and source_id=v_row.id
    ) then
      insert into public.merit_ledger(
        boss_id,profile_id,amount,kind,reason,source_id,status
      ) values(
        v_row.boss_id,v_row.profile_id,-v_row.cost,'redeem','',v_row.id,'posted'
      );
    end if;
    update public.rewards
       set stock=case when stock is null then null else greatest(0,stock-1) end
     where id=v_row.reward_id;
  end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

-- ---------------------------------------------------------- leave
create or replace function public.request_leave(
  p_from date,p_to date,p_reason text,p_from_half boolean,p_to_half boolean
)
returns jsonb
language plpgsql security definer
set search_path = public, auth, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_boss uuid;
  v_days numeric := 0;
  v_id uuid;
  d date;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid leave dates';
  end if;
  select coalesce(boss_id,id) into v_boss from public.profiles where id=v_uid;
  if exists(
    select 1 from public.leave_requests
    where profile_id=v_uid and status='pending'
  ) then raise exception 'already asked, waiting for a decision'; end if;

  for d in select generate_series(p_from,p_to,interval '1 day')::date loop
    if extract(isodow from d) < 6 then v_days := v_days + 1; end if;
    if exists(
      select 1 from public.holiday_calendar
      where boss_id=v_boss and holiday=d and not is_workday
    ) then v_days := v_days - 1; end if;
  end loop;
  if p_from=p_to and p_from_half and p_to_half then
    v_days := 0.5;
  else
    if p_from_half then v_days := v_days - 0.5; end if;
    if p_to_half then v_days := v_days - 0.5; end if;
  end if;
  v_days := greatest(0,v_days);

  insert into public.leave_requests(
    boss_id,profile_id,from_date,to_date,reason,from_half,to_half,days
  ) values(
    v_boss,v_uid,p_from,p_to,coalesce(p_reason,''),
    coalesce(p_from_half,false),coalesce(p_to_half,false),v_days
  ) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id,'days',v_days);
end;
$fn$;

drop function if exists public.request_leave(date,date,text);

create or replace function public.request_leave(p_from date,p_to date,p_reason text)
returns jsonb language sql security definer
set search_path=public,auth,pg_temp
as $fn$ select public.request_leave(p_from,p_to,p_reason,false,false); $fn$;

create or replace function public.decide_leave(
  p_leave uuid,p_approved boolean,p_note text default ''
)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update public.leave_requests
     set status=case when coalesce(p_approved,false) then 'approved' else 'rejected' end,
         decided_at=now(),decision_note=coalesce(p_note,''),version=version+1
   where id=p_leave and boss_id=v_uid and status='pending';
  if not found then raise exception 'already decided or not yours'; end if;
  return jsonb_build_object('ok',true);
end;
$fn$;

revoke all on function public.merit_available(uuid) from public;
revoke all on function public.redeem_reward(uuid) from public;
revoke all on function public.decide_redemption(uuid,boolean) from public;
revoke all on function public.request_leave(date,date,text) from public;
revoke all on function public.request_leave(date,date,text,boolean,boolean) from public;
revoke all on function public.decide_leave(uuid,boolean,text) from public;
grant execute on function public.merit_available(uuid) to authenticated;
grant execute on function public.redeem_reward(uuid) to authenticated;
grant execute on function public.decide_redemption(uuid,boolean) to authenticated;
grant execute on function public.request_leave(date,date,text) to authenticated;
grant execute on function public.request_leave(date,date,text,boolean,boolean) to authenticated;
grant execute on function public.decide_leave(uuid,boolean,text) to authenticated;
-- ---------------------------------------------------------- work settlement
create or replace function public.end_work()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.work_sessions%rowtype;
  v_hours numeric;
  v_pending integer;
  v_today date:=(now() at time zone 'Asia/Shanghai')::date;
  v_capped boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.work_sessions
   where profile_id=v_uid and ended_at is null
   order by started_at desc limit 1;
  if not found then raise exception 'not working'; end if;
  v_hours:=round(extract(epoch from(now()-v_row.started_at))/3600.0,2);
  if v_hours>24 then v_hours:=24;v_capped:=true;end if;
  if v_hours<0.005 then v_hours:=0;end if;

  update public.work_sessions
     set ended_at=now(),hours=v_hours
   where id=v_row.id;

  if v_hours>0 then
    insert into public.worklogs(
      boss_id,employee_id,task_id,project_id,step_id,work_date,hours,
      content,source,approval_status,idempotency_key
    )
    select v_row.boss_id,v_uid,v_row.task_id,t.project_id,t.step_id,
           v_today,v_hours,'','timer','pending',
           'timer:'||v_row.id::text
      from public.tasks t where t.id=v_row.task_id
    union all
    select v_row.boss_id,v_uid,v_row.task_id,null,null,
           v_today,v_hours,'','timer','pending',
           'timer:'||v_row.id::text
     where not exists(select 1 from public.tasks where id=v_row.task_id);
    v_pending:=floor(v_hours*10)::integer;
  else
    v_pending:=0;
  end if;

  return jsonb_build_object(
    'ok',true,'hours',v_hours,'recorded',v_hours>0,'capped',v_capped,
    'merit',0,'pending_merit',v_pending,
    'balance',public.merit_available(v_uid)
  );
end;
$fn$;

create or replace function public.start_work(p_task uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_boss uuid;
  v_open public.work_sessions%rowtype;
  v_hours numeric;
  v_id uuid;
  v_started timestamptz;
  v_today date:=(now() at time zone 'Asia/Shanghai')::date;
  v_closed boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select coalesce(boss_id,id) into v_boss from public.profiles where id=v_uid;
  select * into v_open from public.work_sessions
   where profile_id=v_uid and ended_at is null order by started_at desc limit 1;
  if found then
    v_hours:=round(extract(epoch from(now()-v_open.started_at))/3600.0,2);
    if v_hours<=24 then raise exception 'already working'; end if;
    v_hours:=24;
    update public.work_sessions set ended_at=now(),hours=v_hours where id=v_open.id;
    insert into public.worklogs(
      boss_id,employee_id,task_id,work_date,hours,content,source,
      approval_status,idempotency_key
    ) values(
      v_open.boss_id,v_uid,v_open.task_id,v_today,v_hours,'',
      'timer','pending','timer:'||v_open.id::text
    ) on conflict do nothing;
    v_closed:=true;
  end if;
  insert into public.work_sessions(boss_id,profile_id,task_id)
  values(v_boss,v_uid,p_task) returning id,started_at into v_id,v_started;
  return jsonb_build_object('ok',true,'id',v_id,'started_at',v_started,'closed_stale',v_closed);
end;
$fn$;

create or replace function public._settle_task(
  p_task uuid,p_grade text,p_auto boolean default false
)
returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_task public.tasks%rowtype;
  v_hours numeric:=0;
  v_base integer;
  v_mult numeric;
  v_target integer;
  v_existing integer:=0;
  v_delta integer;
begin
  select * into v_task from public.tasks where id=p_task;
  if not found then raise exception 'no such task'; end if;
  if v_task.grade is not null then raise exception 'already graded'; end if;
  if not exists(
    select 1 from public.task_acceptance a
     where a.task_id=p_task and a.status='accepted'
  ) then
    raise exception 'task acceptance required before grading';
  end if;

  select coalesce(sum(hours),0) into v_hours
    from public.work_sessions where task_id=p_task and ended_at is not null;
  if v_hours=0 then
    select coalesce(sum(extract(epoch from(finished_at-started_at))/3600.0),0)
      into v_hours from public.task_logs
     where task_id=p_task and started_at is not null;
  end if;
  if v_hours=0 then
    select coalesce(sum(hours),0) into v_hours
      from public.worklogs where task_id=p_task;
  end if;
  if v_hours=0 then v_hours:=coalesce(v_task.est_hours,0); end if;
  v_hours:=least(greatest(v_hours,0),24);
  v_base:=floor(v_hours*10)::integer;
  v_mult:=case p_grade when 'S' then 1.2 when 'A' then 1.0 when 'B' then 0.8 else 0 end;
  v_target:=round(v_base*v_mult)::integer;

  select coalesce(sum(amount),0) into v_existing
    from public.merit_ledger
   where profile_id=v_task.employee_id and status='posted'
     and (source_id=p_task or source_id in(
       select id from public.work_sessions where task_id=p_task
     ));
  v_delta:=v_target-v_existing;

  if v_delta<>0 then
    insert into public.merit_ledger(
      boss_id,profile_id,amount,kind,reason,source_id,status,settled_at
    ) values(
      v_task.boss_id,v_task.employee_id,v_delta,'grade','',p_task,'posted',now()
    );
  end if;

  update public.tasks set
    grade=p_grade,merit_awarded=v_target,graded_at=now(),
    graded_by=case when p_auto then null else auth.uid() end,
    auto_settle_at=case when p_auto then now() else auto_settle_at end,
    version=version+1,updated_at=now()
  where id=p_task;
  return v_target;
end;
$fn$;

create or replace function public.grade_task(p_task uuid,p_grade text)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_grade text:=upper(trim(coalesce(p_grade,'')));
  v_amount integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_grade not in('S','A','B','C') then raise exception 'invalid grade'; end if;
  select * into v_task from public.tasks where id=p_task;
  if not found then raise exception 'no such task'; end if;
  if not public._execution_can_review_task(
    public._execution_task_enterprise(p_task),v_uid,p_task
  ) then raise exception 'tasks.grade authority required'; end if;
  if not exists(select 1 from public.task_logs where task_id=p_task) then
    raise exception 'task is not finished yet';
  end if;
  v_amount:=public._settle_task(p_task,v_grade,false);
  return jsonb_build_object('ok',true,'grade',v_grade,'amount',v_amount,
    'balance',public.merit_available(v_task.employee_id));
end;
$fn$;

create or replace function public.settle_due_grades()
returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_boss uuid;
  v_task uuid;
  v_count integer:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select coalesce(boss_id,id) into v_boss from public.profiles where id=v_uid;
  for v_task in
    select t.id from public.tasks t
     where t.boss_id=v_boss and t.grade is null
       and exists(select 1 from public.task_logs l where l.task_id=t.id)
       and exists(select 1 from public.task_acceptance a
                   where a.task_id=t.id and a.status='accepted')
       and coalesce(t.auto_settle_at,t.updated_at) <= now()-interval '7 days'
  loop
    begin
      perform public._settle_task(v_task,'A',true);
      v_count:=v_count+1;
    exception when others then null;
    end;
  end loop;
  return v_count;
end;
$fn$;

create or replace function public.approve_worklog(p_worklog uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.worklogs%rowtype;
  v_points integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.worklogs
   where id=p_worklog and boss_id=v_uid and approval_status='pending';
  if not found then raise exception 'already approved or not yours'; end if;
  v_points:=floor(least(greatest(v_row.hours,0),24)*10)::integer;
  update public.worklogs set approval_status='approved',approved_by=v_uid,
    approved_at=now(),version=version+1 where id=v_row.id;
  if v_points<>0 and not exists(
    select 1 from public.merit_ledger where source_id=v_row.id and kind='hours'
  ) then
    insert into public.merit_ledger(
      boss_id,profile_id,amount,kind,reason,source_id,status,settled_at
    ) values(
      v_row.boss_id,v_row.employee_id,v_points,'hours','',v_row.id,'posted',now()
    );
  end if;
  return jsonb_build_object('ok',true,'points',v_points);
end;
$fn$;

revoke all on function public._settle_task(uuid,text,boolean) from public;
revoke all on function public.settle_due_grades() from public;
revoke all on function public.approve_worklog(uuid) from public;
grant execute on function public.settle_due_grades() to authenticated;
grant execute on function public.approve_worklog(uuid) to authenticated;

-- Phase 1 governance is not included in this unified installer.
-- Run mobile/sql/enterprise-identity.sql, then mobile/sql/community.sql,
-- then mobile/sql/enterprise-governance-v2.sql separately.

-- ============================================================
-- Phase 2A decision center and unified approvals
-- ============================================================
-- The base unified installer can be run before enterprise governance.
-- Phase 2A is therefore guarded: when its prerequisites are absent it
-- emits a notice, and the same block applies when this file is re-run
-- after the Phase 1 and task-extension migrations. The standalone
-- mobile/sql/decision-approvals-v1.sql remains the canonical migration.
do $decision_installer$
begin
  if to_regclass('public.enterprises') is null
     or to_regclass('public.enterprise_role_motions') is null
     or to_regclass('public.worklogs') is null
     or to_regclass('public.task_requests') is null
     or to_regprocedure('public._identity_bootstrap(uuid)') is null
     or to_regprocedure('public.cast_enterprise_role_vote(uuid,text)') is null
  then
    raise notice 'Phase 2A skipped: run enterprise-identity.sql, enterprise-governance-v2.sql, and task-accept-extension.sql first.';
    return;
  end if;
  execute $decision_phase2a$-- ============================================================
-- Project Recorder - Phase 2A decision center and unified approvals
--
-- Deployment order:
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   unified-platform.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--
-- All business tables stay private. Clients read and write through the
-- SECURITY DEFINER RPCs at the end of this file.
-- ============================================================

-- ------------------------------------------------------------ decision queue
create table if not exists public.decision_items (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  source_type text not null
    check (source_type in ('task','project','worklog','approval',
                           'identity_motion','change','governance',
                           'finance','risk','manual')),
  source_id uuid,
  title text not null,
  detail text not null default '',
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  impact_days integer not null default 0 check (impact_days >= 0),
  impact_amount numeric not null default 0 check (impact_amount >= 0),
  waiting_since timestamptz not null default now(),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  status text not null default 'open'
    check (status in ('open','acknowledged','assigned','deferred',
                      'resolved','dismissed')),
  resolution text not null default '',
  due_at timestamptz not null default (now() + interval '3 days'),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, source_type, source_id)
);

create index if not exists decision_items_queue_idx
  on public.decision_items(enterprise_id, status, due_at, risk);

create table if not exists public.decision_events (
  id bigint generated always as identity primary key,
  decision_id uuid not null
    references public.decision_items(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  note text not null default '',
  idempotency_key text not null default '',
  created_at timestamptz not null default now()
);

create unique index if not exists decision_event_idempotency_idx
  on public.decision_events(decision_id, idempotency_key)
  where idempotency_key <> '';

-- ------------------------------------------------------------ approval inbox
create table if not exists public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  kind text not null
    check (kind in ('leave','worklog','expense','purchase','reward',
                    'task_extension','identity_motion')),
  source_id uuid not null,
  requester_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  title text not null,
  detail text not null default '',
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  amount numeric not null default 0 check (amount >= 0),
  impact_days integer not null default 0 check (impact_days >= 0),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  required_level text not null default 'manager'
    check (required_level in ('manager','executive')),
  required_permission text not null,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','returned','cancelled')),
  idempotency_key text not null default '',
  decision_note text not null default '',
  due_at timestamptz not null default (now() + interval '2 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, kind, source_id)
);

create unique index if not exists approval_idempotency_idx
  on public.approval_requests(enterprise_id, idempotency_key)
  where idempotency_key <> '';

create index if not exists approval_inbox_idx
  on public.approval_requests(enterprise_id, status, due_at, risk);

create table if not exists public.approval_events (
  id bigint generated always as identity primary key,
  approval_id uuid not null
    references public.approval_requests(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  note text not null default '',
  idempotency_key text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists approval_event_idempotency_idx
  on public.approval_events(approval_id, idempotency_key)
  where idempotency_key <> '';

alter table public.decision_items enable row level security;
alter table public.decision_events enable row level security;
alter table public.approval_requests enable row level security;
alter table public.approval_events enable row level security;

revoke all on table public.decision_items from public;
revoke all on table public.decision_items from anon;
revoke all on table public.decision_items from authenticated;
revoke all on table public.decision_events from public;
revoke all on table public.decision_events from anon;
revoke all on table public.decision_events from authenticated;
revoke all on table public.approval_requests from public;
revoke all on table public.approval_requests from anon;
revoke all on table public.approval_requests from authenticated;
revoke all on table public.approval_events from public;
revoke all on table public.approval_events from anon;
revoke all on table public.approval_events from authenticated;

-- ------------------------------------------------------------ pure helpers
create or replace function public._decision_risk(p_risk text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v text:=lower(btrim(coalesce(p_risk,'healthy')));
begin
  if v in ('severe','critical') then return 'severe'; end if;
  if v in ('risk','high') then return 'risk'; end if;
  if v in ('attention','medium','') then return 'attention'; end if;
  if v='healthy' or v='low' then return 'healthy'; end if;
  return 'attention';
end;
$fn$;

create or replace function public._decision_risk_weight(p_risk text)
returns integer
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return case public._decision_risk(p_risk)
    when 'severe' then 50
    when 'risk' then 35
    when 'attention' then 20
    else 0
  end;
end;
$fn$;

create or replace function public._decision_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permission text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  v_permissions:=public._identity_role_permissions(p_eid,p_uid);
  return coalesce(v_permissions ? p_permission,false);
end;
$fn$;

create or replace function public._decision_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  v_permissions:=public._identity_role_permissions(p_eid,p_uid);
  return coalesce(
    v_permissions ?| array[
      'company.manage','projects.view_all','projects.manage',
      'people.view_all','people.manage','worklogs.approve',
      'tasks.assign','tasks.grade','finance.view','finance.manage',
      'reports.view','audit.read','rewards.manage','leave.approve',
      'identity.manage_templates','identity.manage_shares',
      'governance.manage','governance.vote'
    ]::text[],
    false
  );
end;
$fn$;

create or replace function public._decision_is_executive(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if exists(
    select 1 from public.enterprises e
     where e.id=p_eid and e.owner_profile_id=p_uid
  ) then
    return true;
  end if;
  return exists(
    select 1
      from public.enterprise_members m
      join public.enterprise_role_catalog r on r.key=m.role_key
     where m.enterprise_id=p_eid
       and m.profile_id=p_uid
       and m.status='active'
       and r.rank>=75
  );
end;
$fn$;

create or replace function public._decision_approval_permission(p_kind text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return case lower(coalesce(p_kind,''))
    when 'leave' then 'leave.approve'
    when 'worklog' then 'worklogs.approve'
    when 'expense' then 'finance.manage'
    when 'purchase' then 'finance.manage'
    when 'reward' then 'rewards.manage'
    when 'task_extension' then 'tasks.grade'
    when 'identity_motion' then 'governance.vote'
    else ''
  end;
end;
$fn$;

create or replace function public._decision_required_level(
  p_amount numeric,
  p_risk text
) returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if public._decision_risk(p_risk) in ('severe','risk')
     or coalesce(p_amount,0)>=50000 then
    return 'executive';
  end if;
  return 'manager';
end;
$fn$;

create or replace function public._decision_approval_can_act(
  p_eid uuid,
  p_kind text,
  p_action text,
  p_uid uuid,
  p_requester uuid,
  p_owner uuid,
  p_amount numeric,
  p_risk text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_action text:=lower(coalesce(p_action,''));
  v_kind text:=lower(coalesce(p_kind,''));
  v_required text:=public._decision_approval_permission(p_kind);
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if v_action='cancelled' then
    if v_kind='identity_motion' then
      return p_uid in (p_requester,p_owner);
    end if;
    return p_uid in (p_requester,p_owner)
      or public._decision_has_permission(p_eid,p_uid,v_required);
  end if;
  if v_action not in ('approved','rejected','returned') then
    return false;
  end if;
  if v_kind='identity_motion' then
    if v_action='returned' then return false; end if;
    return (
      public._decision_has_permission(p_eid,p_uid,'governance.vote')
      or public._decision_has_permission(p_eid,p_uid,'governance.manage')
    ) and public._identity_shares(p_eid,p_uid)>0;
  end if;
  if v_required='' then return false; end if;
  if not public._decision_has_permission(p_eid,p_uid,v_required) then
    return false;
  end if;
  if public._decision_required_level(p_amount,p_risk)='executive'
     and not public._decision_is_executive(p_eid,p_uid) then
    return false;
  end if;
  return true;
end;
$fn$;

create or replace function public._decision_actions(
  p_eid uuid,
  p_uid uuid,
  p_status text,
  p_owner uuid
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_open boolean:=coalesce(p_status,'open') in
  ('open','acknowledged','assigned','deferred');
begin
  if not v_open then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'acknowledge',true,
    'assign',true,
    'defer',true,
    'resolve',true,
    'dismiss',true
  );
end;
$fn$;

create or replace function public._approval_actions(
  p_eid uuid,
  p_uid uuid,
  p_kind text,
  p_status text,
  p_requester uuid,
  p_owner uuid,
  p_amount numeric,
  p_risk text
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if coalesce(p_status,'pending')<>'pending' then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'approve',public._decision_approval_can_act(
      p_eid,p_kind,'approved',p_uid,p_requester,p_owner,p_amount,p_risk),
    'reject',public._decision_approval_can_act(
      p_eid,p_kind,'rejected',p_uid,p_requester,p_owner,p_amount,p_risk),
    'return',public._decision_approval_can_act(
      p_eid,p_kind,'returned',p_uid,p_requester,p_owner,p_amount,p_risk),
    'cancel',public._decision_approval_can_act(
      p_eid,p_kind,'cancelled',p_uid,p_requester,p_owner,p_amount,p_risk)
  );
end;
$fn$;

-- ------------------------------------------------------------ approval source sync
alter table public.task_requests drop constraint if exists task_requests_status_check;
alter table public.task_requests
  add constraint task_requests_status_check
  check (status in ('pending','approved','rejected','returned','cancelled'));

create or replace function public._decision_upsert_approval(
  p_eid uuid,
  p_kind text,
  p_source uuid,
  p_requester uuid,
  p_owner uuid,
  p_title text,
  p_detail text,
  p_evidence jsonb,
  p_amount numeric,
  p_impact_days integer,
  p_risk text,
  p_due_at timestamptz,
  p_status text,
  p_created_at timestamptz
) returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_id uuid;
  v_risk text:=public._decision_risk(p_risk);
  v_permission text:=public._decision_approval_permission(p_kind);
begin
  insert into public.approval_requests(
    enterprise_id,kind,source_id,requester_profile_id,owner_profile_id,
    title,detail,evidence,amount,impact_days,risk,required_level,
    required_permission,status,idempotency_key,due_at,created_at,updated_at
  ) values(
    p_eid,p_kind,p_source,p_requester,p_owner,
    coalesce(nullif(btrim(p_title),''),p_kind),
    coalesce(p_detail,''),
    coalesce(p_evidence,'[]'::jsonb),
    greatest(coalesce(p_amount,0),0),
    greatest(coalesce(p_impact_days,0),0),
    v_risk,
    public._decision_required_level(p_amount,p_risk),
    v_permission,
    p_status,
    p_kind||':'||p_source::text,
    coalesce(p_due_at,now()+interval '2 days'),
    coalesce(p_created_at,now()),
    now()
  )
  on conflict (enterprise_id,kind,source_id) do update set
    requester_profile_id=excluded.requester_profile_id,
    owner_profile_id=excluded.owner_profile_id,
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    amount=excluded.amount,
    impact_days=excluded.impact_days,
    risk=excluded.risk,
    required_level=excluded.required_level,
    required_permission=excluded.required_permission,
    status=excluded.status,
    due_at=excluded.due_at,
    updated_at=now()
  returning id into v_id;
  return v_id;
end;
$fn$;

create or replace function public._decision_sync_leave()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_days integer:=greatest(0,ceil(coalesce(NEW.days,0))::integer);
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when v_days>=10 then 'severe'
    when v_days>=4 then 'risk'
    else 'attention'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'leave',NEW.id,NEW.profile_id,NEW.boss_id,
    'Leave '||NEW.from_date::text||' to '||NEW.to_date::text,
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','leave_request','id',NEW.id,'from_date',NEW.from_date,
      'to_date',NEW.to_date,'days',NEW.days,'status',NEW.status)),
    v_days,v_days,v_risk,
    NEW.created_at+interval '2 days',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_worklog()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_status text:=case lower(coalesce(NEW.approval_status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when coalesce(NEW.hours,0)>16 then 'risk'
    when coalesce(NEW.hours,0)>12 then 'attention'
    else 'healthy'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'worklog',NEW.id,NEW.employee_id,NEW.boss_id,
    'Worklog '||NEW.work_date::text,
    coalesce(NEW.content,''),
    jsonb_build_array(jsonb_build_object(
      'type','worklog','id',NEW.id,'task_id',NEW.task_id,
      'work_date',NEW.work_date,'hours',NEW.hours,
      'status',NEW.approval_status)),
    coalesce(NEW.hours,0)*10,0,v_risk,
    NEW.work_date::timestamptz+interval '1 day',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_redemption()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'given' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text:=case
    when coalesce(NEW.cost,0)>=50000 then 'severe'
    when coalesce(NEW.cost,0)>=5000 then 'risk'
    when coalesce(NEW.cost,0)>=1000 then 'attention'
    else 'healthy'
  end;
begin
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'reward',NEW.id,NEW.profile_id,NEW.boss_id,
    'Reward: '||NEW.title,
    'Reward redemption',
    jsonb_build_array(jsonb_build_object(
      'type','redemption','id',NEW.id,'reward_id',NEW.reward_id,
      'cost',NEW.cost,'status',NEW.status)),
    NEW.cost,0,v_risk,
    NEW.created_at+interval '2 days',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_task_extension()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_plan_date date;
  v_task_title text:='Task';
  v_days integer:=0;
  v_status text:=case lower(coalesce(NEW.status,'pending'))
    when 'approved' then 'approved'
    when 'rejected' then 'rejected'
    when 'returned' then 'returned'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
  v_risk text;
begin
  select t.plan_date,t.title into v_plan_date,v_task_title
    from public.tasks t where t.id=NEW.task_id;
  v_days:=greatest(0,coalesce(NEW.to_date-v_plan_date,0));
  v_risk:=case
    when v_days>=8 then 'severe'
    when v_days>=3 then 'risk'
    else 'attention'
  end;
  perform public._decision_upsert_approval(
    public._identity_bootstrap(NEW.boss_id),
    'task_extension',NEW.id,NEW.employee_id,NEW.boss_id,
    'Task extension: '||coalesce(v_task_title,'Task'),
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','task_request','id',NEW.id,'task_id',NEW.task_id,
      'plan_date',v_plan_date,'to_date',NEW.to_date,'status',NEW.status)),
    v_days,v_days,v_risk,
    NEW.created_at+interval '1 day',v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

create or replace function public._decision_sync_identity_motion()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_owner uuid;
  v_target text;
  v_status text:=case lower(coalesce(NEW.status,'open'))
    when 'passed' then 'approved'
    when 'rejected' then 'rejected'
    when 'cancelled' then 'cancelled'
    else 'pending'
  end;
begin
  select e.owner_profile_id into v_owner
    from public.enterprises e where e.id=NEW.enterprise_id;
  select p.name into v_target
    from public.profiles p where p.id=NEW.target_profile_id;
  perform public._decision_upsert_approval(
    NEW.enterprise_id,
    'identity_motion',NEW.id,NEW.proposer_profile_id,v_owner,
    'Identity motion: '||NEW.kind||' '||coalesce(v_target,'member'),
    coalesce(NEW.reason,''),
    jsonb_build_array(jsonb_build_object(
      'type','identity_motion','id',NEW.id,'motion_kind',NEW.kind,
      'target_profile_id',NEW.target_profile_id,
      'proposed_role_key',NEW.proposed_role_key,
      'motion_class',NEW.motion_class,'status',NEW.status,
      'share_snapshot',NEW.share_snapshot)),
    0,0,'severe',NEW.closes_at,v_status,NEW.created_at
  );
  return NEW;
end;
$fn$;

drop trigger if exists trg_decision_sync_leave on public.leave_requests;
create trigger trg_decision_sync_leave
  after insert or update on public.leave_requests
  for each row execute function public._decision_sync_leave();

drop trigger if exists trg_decision_sync_worklog on public.worklogs;
create trigger trg_decision_sync_worklog
  after insert or update on public.worklogs
  for each row execute function public._decision_sync_worklog();

drop trigger if exists trg_decision_sync_redemption on public.redemptions;
create trigger trg_decision_sync_redemption
  after insert or update on public.redemptions
  for each row execute function public._decision_sync_redemption();

drop trigger if exists trg_decision_sync_task_extension on public.task_requests;
create trigger trg_decision_sync_task_extension
  after insert or update on public.task_requests
  for each row execute function public._decision_sync_task_extension();

drop trigger if exists trg_decision_sync_identity_motion
  on public.enterprise_role_motions;
create trigger trg_decision_sync_identity_motion
  after insert or update on public.enterprise_role_motions
  for each row execute function public._decision_sync_identity_motion();

-- Backfill rows created before this migration.
select public._decision_upsert_approval(
  public._identity_bootstrap(l.boss_id),'leave',l.id,l.profile_id,l.boss_id,
  'Leave '||l.from_date::text||' to '||l.to_date::text,
  coalesce(l.reason,''),
  jsonb_build_array(jsonb_build_object('type','leave_request','id',l.id)),
  greatest(0,ceil(coalesce(l.days,0))::integer),
  greatest(0,ceil(coalesce(l.days,0))::integer),
  case when l.days>=10 then 'severe'
       when l.days>=4 then 'risk' else 'attention' end,
  l.created_at+interval '2 days',
  case lower(coalesce(l.status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  l.created_at
)
from public.leave_requests l;

select public._decision_upsert_approval(
  public._identity_bootstrap(w.boss_id),'worklog',w.id,w.employee_id,w.boss_id,
  'Worklog '||w.work_date::text,coalesce(w.content,''),
  jsonb_build_array(jsonb_build_object('type','worklog','id',w.id)),
  coalesce(w.hours,0)*10,0,
  case when coalesce(w.hours,0)>16 then 'risk'
       when coalesce(w.hours,0)>12 then 'attention' else 'healthy' end,
  w.work_date::timestamptz+interval '1 day',
  case lower(coalesce(w.approval_status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  w.created_at
)
from public.worklogs w;

select public._decision_upsert_approval(
  public._identity_bootstrap(r.boss_id),'reward',r.id,r.profile_id,r.boss_id,
  'Reward: '||r.title,'Reward redemption',
  jsonb_build_array(jsonb_build_object('type','redemption','id',r.id)),
  r.cost,0,
  case when r.cost>=50000 then 'severe'
       when r.cost>=5000 then 'risk'
       when r.cost>=1000 then 'attention' else 'healthy' end,
  r.created_at+interval '2 days',
  case lower(coalesce(r.status,'pending'))
    when 'approved' then 'approved' when 'given' then 'approved'
    when 'rejected' then 'rejected' when 'returned' then 'returned'
    when 'cancelled' then 'cancelled' else 'pending' end,
  r.created_at
)
from public.redemptions r;

select public._decision_upsert_approval(
  public._identity_bootstrap(q.boss_id),'task_extension',q.id,q.employee_id,q.boss_id,
  'Task extension: '||coalesce(t.title,'Task'),coalesce(q.reason,''),
  jsonb_build_array(jsonb_build_object('type','task_request','id',q.id)),
  greatest(0,coalesce(q.to_date-t.plan_date,0)),
  greatest(0,coalesce(q.to_date-t.plan_date,0)),
  case when coalesce(q.to_date-t.plan_date,0)>=8 then 'severe'
       when coalesce(q.to_date-t.plan_date,0)>=3 then 'risk'
       else 'attention' end,
  q.created_at+interval '1 day',
  case lower(coalesce(q.status,'pending'))
    when 'approved' then 'approved' when 'rejected' then 'rejected'
    when 'returned' then 'returned' when 'cancelled' then 'cancelled'
    else 'pending' end,
  q.created_at
)
from public.task_requests q
left join public.tasks t on t.id=q.task_id;

select public._decision_upsert_approval(
  m.enterprise_id,'identity_motion',m.id,m.proposer_profile_id,e.owner_profile_id,
  'Identity motion: '||m.kind,
  coalesce(m.reason,''),
  jsonb_build_array(jsonb_build_object(
    'type','identity_motion','id',m.id,'motion_class',m.motion_class,
    'share_snapshot',m.share_snapshot)),
  0,0,'severe',m.closes_at,
  case lower(coalesce(m.status,'open'))
    when 'passed' then 'approved' when 'rejected' then 'rejected'
    when 'cancelled' then 'cancelled' else 'pending' end,
  m.created_at
)
from public.enterprise_role_motions m
join public.enterprises e on e.id=m.enterprise_id;

-- ------------------------------------------------------------ decision generation
create or replace function public._decision_refresh(
  p_eid uuid,
  p_uid uuid
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  -- Revalidate source records before rendering the queue. Manual dismissal and
  -- resolution are retained, while source completion closes generated items.
  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then
           'Source approval is no longer pending' else d.resolution end,
         version=d.version+1,
         updated_at=now()
   where d.enterprise_id=p_eid
     and d.source_type='approval'
     and d.status in ('open','acknowledged','assigned','deferred')
     and exists(
       select 1 from public.approval_requests a
        where a.id=d.source_id and a.status<>'pending');

  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then
           'Task now has completion evidence' else d.resolution end,
         version=d.version+1,
         updated_at=now()
   where d.enterprise_id=p_eid
     and d.source_type='task'
     and d.status in ('open','acknowledged','assigned','deferred')
     and exists(select 1 from public.task_logs l where l.task_id=d.source_id);

  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    a.enterprise_id,'approval',a.id,
    'Approval: '||a.title,a.detail,a.evidence,a.risk,
    a.impact_days,a.amount,a.created_at,a.owner_profile_id,'open','',
    a.due_at,a.created_at,now()
  from public.approval_requests a
  where a.enterprise_id=p_eid
    and a.status='pending'
    and (
      a.required_level='executive'
      or a.risk in ('severe','risk')
      or a.impact_days>=3
      or a.due_at<=now()+interval '1 day'
    )
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    risk=excluded.risk,
    impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,
    owner_profile_id=excluded.owner_profile_id,
    due_at=excluded.due_at,
    updated_at=now();

  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    public._identity_bootstrap(t.boss_id),'task',t.id,
    'Overdue task: '||t.title,
    coalesce(t.detail,''),
    jsonb_build_array(jsonb_build_object(
      'type','task','id',t.id,'plan_date',t.plan_date,
      'accept_status',t.accept_status,'est_hours',t.est_hours)),
    case when current_date-t.plan_date>=5 then 'severe'
         when current_date-t.plan_date>=2 then 'risk'
         else 'attention' end,
    greatest(0,current_date-t.plan_date),0,
    t.plan_date::timestamptz,t.employee_id,'open','',
    t.plan_date::timestamptz,t.plan_date::timestamptz,now()
  from public.tasks t
  where t.boss_id=(select e.owner_profile_id
                    from public.enterprises e where e.id=p_eid)
    and t.plan_date<current_date
    and not exists(select 1 from public.task_logs l where l.task_id=t.id)
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,
    detail=excluded.detail,
    evidence=excluded.evidence,
    risk=excluded.risk,
    impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,
    owner_profile_id=excluded.owner_profile_id,
    due_at=excluded.due_at,
    updated_at=now();
end;
$fn$;

create or replace function public.get_decision_center()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._decision_has_management(v_eid,v_uid) then
    raise exception 'management permission required';
  end if;

  perform public._decision_refresh(v_eid,v_uid);

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'decisions',(
      select coalesce(jsonb_agg(
        to_jsonb(d)||jsonb_build_object(
          'owner_name',coalesce(p.name,''),
          'actions',public._decision_actions(
            v_eid,v_uid,d.status,d.owner_profile_id)
        ) order by
          (d.impact_days*4+d.impact_amount/10000
           +public._decision_risk_weight(d.risk)) desc,
          d.due_at,d.created_at
      ),'[]'::jsonb)
      from public.decision_items d
      left join public.profiles p on p.id=d.owner_profile_id
      where d.enterprise_id=v_eid
        and d.status in ('open','acknowledged','assigned','deferred')
    ),
    'approvals',(
      select coalesce(jsonb_agg(
        to_jsonb(a)||jsonb_build_object(
          'requester_name',coalesce(rp.name,''),
          'owner_name',coalesce(op.name,''),
          'actions',public._approval_actions(
            v_eid,v_uid,a.kind,a.status,a.requester_profile_id,
            a.owner_profile_id,a.amount,a.risk)
        ) order by
          (a.impact_days*4+a.amount/10000
           +public._decision_risk_weight(a.risk)) desc,
          a.due_at,a.created_at
      ),'[]'::jsonb)
      from public.approval_requests a
      left join public.profiles rp on rp.id=a.requester_profile_id
      left join public.profiles op on op.id=a.owner_profile_id
      where a.enterprise_id=v_eid and a.status='pending'
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',m.profile_id,'name',p.name,'role_key',m.role_key
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
    )
  );
end;
$fn$;

-- ------------------------------------------------------------ decision actions
create or replace function public.act_on_decision(
  p_decision uuid,
  p_action text,
  p_owner uuid default null,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.decision_items%rowtype;
  v_action text:=lower(btrim(coalesce(p_action,'')));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_note text:=btrim(coalesce(p_note,''));
  v_existing_action text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_key='' then raise exception 'idempotency key required'; end if;
  select * into v_row from public.decision_items
   where id=p_decision for update;
  if not found then raise exception 'decision not found'; end if;
  if not public._decision_has_management(v_row.enterprise_id,v_uid) then
    raise exception 'management permission required';
  end if;

  select action into v_existing_action
    from public.decision_events
   where decision_id=p_decision and idempotency_key=v_key
   order by id desc limit 1;
  if found then
    if v_existing_action<>v_action then
      raise exception 'idempotency key already used for another action';
    end if;
    return jsonb_build_object(
      'ok',true,'status',v_row.status,'duplicate',true);
  end if;

  if v_action not in ('acknowledged','assigned','deferred',
                      'resolved','dismissed') then
    raise exception 'invalid action';
  end if;
  if v_row.status not in ('open','acknowledged','assigned','deferred') then
    if v_row.status=v_action then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'decision already closed';
  end if;
  if v_action='assigned' then
    if p_owner is null and v_row.owner_profile_id is null then
      raise exception 'owner required';
    end if;
    if p_owner is not null and not public._identity_is_member(
      v_row.enterprise_id,p_owner
    ) then
      raise exception 'owner must be an active enterprise member';
    end if;
  end if;
  if v_action in ('deferred','dismissed') and v_note='' then
    raise exception 'note required';
  end if;

  update public.decision_items set
    status=v_action,
    owner_profile_id=case when v_action='assigned'
      then coalesce(p_owner,owner_profile_id) else owner_profile_id end,
    resolution=case when v_action in ('resolved','dismissed')
      then v_note else resolution end,
    version=version+1,
    updated_at=now()
  where id=p_decision;

  insert into public.decision_events(
    decision_id,actor_profile_id,action,note,idempotency_key
  ) values(p_decision,v_uid,v_action,v_note,v_key);

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'decision.'||v_action,
    coalesce(p_owner,v_row.owner_profile_id),
    jsonb_build_object('decision_id',p_decision,'note',v_note,
                       'idempotency_key',v_key)
  );

  return jsonb_build_object(
    'ok',true,'status',v_action,'duplicate',false);
end;
$fn$;

-- ------------------------------------------------------------ approval actions
create or replace function public.act_on_approval(
  p_approval uuid,
  p_action text,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.approval_requests%rowtype;
  v_action text:=lower(btrim(coalesce(p_action,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_required text;
  v_existing_action text;
  v_worklog public.worklogs%rowtype;
  v_redemption public.redemptions%rowtype;
  v_request public.task_requests%rowtype;
  v_task public.tasks%rowtype;
  v_points integer:=0;
  v_vote jsonb;
  v_motion_status text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_key='' then raise exception 'idempotency key required'; end if;
  select * into v_row from public.approval_requests
   where id=p_approval for update;
  if not found then raise exception 'approval not found'; end if;

  select action into v_existing_action
    from public.approval_events
   where approval_id=p_approval and idempotency_key=v_key
   order by id desc limit 1;
  if found then
    if v_existing_action<>v_action
       and not (v_row.kind='identity_motion'
                and v_existing_action=case v_action
                  when 'approved' then 'vote_yes'
                  when 'rejected' then 'vote_no'
                  else '' end) then
      raise exception 'idempotency key already used for another action';
    end if;
    return jsonb_build_object(
      'ok',true,'status',v_row.status,'duplicate',true);
  end if;

  if v_action not in ('approved','rejected','returned','cancelled') then
    raise exception 'invalid action';
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_action then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'approval already decided';
  end if;
  if not public._identity_is_member(v_row.enterprise_id,v_uid) then
    raise exception 'approval permission required';
  end if;

  if v_row.kind='identity_motion' then
    if v_action='returned' then
      raise exception 'identity motions are decided by shareholder vote';
    end if;
    if v_action='cancelled' then
      if v_uid not in (v_row.requester_profile_id,v_row.owner_profile_id) then
        raise exception 'approval permission required';
      end if;
      perform public.cancel_enterprise_role_vote(v_row.source_id);
      insert into public.approval_events(
        approval_id,actor_profile_id,action,note,idempotency_key,metadata
      ) values(
        p_approval,v_uid,'cancelled',v_note,v_key,
        jsonb_build_object('motion_id',v_row.source_id));
      insert into public.enterprise_identity_audit(
        enterprise_id,actor_profile_id,action,target_profile_id,details
      ) values(
        v_row.enterprise_id,v_uid,'approval.cancelled',null,
        jsonb_build_object('approval_id',p_approval,'kind',v_row.kind,
                           'note',v_note,'idempotency_key',v_key));
      return jsonb_build_object(
        'ok',true,'status','cancelled','duplicate',false);
    end if;
    if not (
      public._decision_has_permission(
        v_row.enterprise_id,v_uid,'governance.vote')
      or public._decision_has_permission(
        v_row.enterprise_id,v_uid,'governance.manage')
    ) or public._identity_shares(v_row.enterprise_id,v_uid)<=0 then
      raise exception 'only shareholders may vote';
    end if;

    v_vote:=public.cast_enterprise_role_vote(
      v_row.source_id,
      case v_action when 'approved' then 'yes' else 'no' end
    );
    select status into v_motion_status
      from public.enterprise_role_motions where id=v_row.source_id;
    insert into public.approval_events(
      approval_id,actor_profile_id,action,note,idempotency_key,metadata
    ) values(
      p_approval,v_uid,
      case v_action when 'approved' then 'vote_yes' else 'vote_no' end,
      v_note,v_key,
      jsonb_build_object('vote',v_vote,'motion_status',v_motion_status));
    insert into public.enterprise_identity_audit(
      enterprise_id,actor_profile_id,action,target_profile_id,details
    ) values(
      v_row.enterprise_id,v_uid,'approval.vote',v_row.requester_profile_id,
      jsonb_build_object('approval_id',p_approval,'motion_id',v_row.source_id,
                         'choice',case v_action when 'approved' then 'yes'
                           else 'no' end,'note',v_note,
                         'idempotency_key',v_key));
    select status into v_motion_status
      from public.approval_requests where id=p_approval;
    return jsonb_build_object(
      'ok',true,'status',v_motion_status,'duplicate',false,
      'vote',v_vote);
  end if;

  v_required:=public._decision_approval_permission(v_row.kind);
  if v_required='' or not public._decision_has_permission(
    v_row.enterprise_id,v_uid,v_required
  ) then
    raise exception 'approval permission required';
  end if;
  if public._decision_required_level(v_row.amount,v_row.risk)='executive'
     and not public._decision_is_executive(v_row.enterprise_id,v_uid) then
    raise exception 'executive approval required';
  end if;

  if v_row.kind='leave' then
    update public.leave_requests set
      status=v_action,
      decision_note=v_note,
      decided_at=now(),
      version=version+1
    where id=v_row.source_id;
  elsif v_row.kind='worklog' then
    select * into v_worklog from public.worklogs
     where id=v_row.source_id for update;
    if not found then raise exception 'worklog not found'; end if;
    update public.worklogs set
      approval_status=v_action,
      approved_by=case when v_action='approved' then v_uid
                       else approved_by end,
      approved_at=case when v_action='approved' then now()
                       else approved_at end,
      version=version+1
    where id=v_worklog.id;
    if v_action='approved' then
      v_points:=floor(least(greatest(v_worklog.hours,0),24)*10)::integer;
      if v_points<>0 and not exists(
        select 1 from public.merit_ledger
         where source_id=v_worklog.id and kind='hours'
      ) then
        insert into public.merit_ledger(
          boss_id,profile_id,amount,kind,reason,source_id,status,settled_at
        ) values(
          v_worklog.boss_id,v_worklog.employee_id,v_points,'hours','',
          v_worklog.id,'posted',now()
        );
      end if;
    end if;
  elsif v_row.kind='reward' then
    select * into v_redemption from public.redemptions
     where id=v_row.source_id for update;
    if not found then raise exception 'redemption not found'; end if;
    update public.redemptions set
      status=case when v_action='approved' then 'given' else v_action end,
      decided_at=now(),
      version=version+1
    where id=v_redemption.id;
    if v_action='approved' then
      if not exists(
        select 1 from public.merit_ledger
         where kind='redeem' and source_id=v_redemption.id
      ) then
        insert into public.merit_ledger(
          boss_id,profile_id,amount,kind,reason,source_id,status
        ) values(
          v_redemption.boss_id,v_redemption.profile_id,
          -v_redemption.cost,'redeem','',v_redemption.id,'posted'
        );
      end if;
      update public.rewards set
        stock=case when stock is null then null
                   else greatest(0,stock-1) end
      where id=v_redemption.reward_id;
    end if;
  elsif v_row.kind='task_extension' then
    select * into v_request from public.task_requests
     where id=v_row.source_id for update;
    if not found then raise exception 'task request not found'; end if;
    select * into v_task from public.tasks
     where id=v_request.task_id for update;
    if not found then raise exception 'task not found'; end if;
    update public.task_requests set
      status=v_action,
      decision_note=v_note,
      decided_at=now()
    where id=v_request.id;
    if v_action='approved' then
      update public.tasks set
        plan_date=v_request.to_date,
        updated_at=now()
      where id=v_task.id;
      insert into public.task_events(
        id,boss_id,employee_id,task_id,kind,title,work_date
      ) values(
        gen_random_uuid(),v_task.boss_id,v_task.employee_id,v_task.id,
        'extend_ok',v_task.title,v_request.to_date
      );
    elsif v_action='rejected' then
      insert into public.task_events(
        id,boss_id,employee_id,task_id,kind,title
      ) values(
        gen_random_uuid(),v_task.boss_id,v_task.employee_id,v_task.id,
        'extend_no',v_task.title
      );
    end if;
  end if;

  update public.approval_requests set
    status=v_action,
    decision_note=v_note,
    updated_at=now()
  where id=p_approval;

  insert into public.approval_events(
    approval_id,actor_profile_id,action,note,idempotency_key,metadata
  ) values(
    p_approval,v_uid,v_action,v_note,v_key,
    jsonb_build_object('kind',v_row.kind,'source_id',v_row.source_id)
  );

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'approval.'||v_action,
    v_row.requester_profile_id,
    jsonb_build_object('approval_id',p_approval,'kind',v_row.kind,
                       'source_id',v_row.source_id,'note',v_note,
                       'idempotency_key',v_key)
  );

  return jsonb_build_object(
    'ok',true,'status',v_action,'duplicate',false);
end;
$fn$;

-- ------------------------------------------------------------ least privilege
revoke all on function public._decision_risk(text) from public;
revoke all on function public._decision_risk(text) from anon;
revoke all on function public._decision_risk(text) from authenticated;
revoke all on function public._decision_risk_weight(text) from public;
revoke all on function public._decision_risk_weight(text) from anon;
revoke all on function public._decision_risk_weight(text) from authenticated;
revoke all on function public._decision_has_permission(uuid,uuid,text) from public;
revoke all on function public._decision_has_permission(uuid,uuid,text) from anon;
revoke all on function public._decision_has_permission(uuid,uuid,text) from authenticated;
revoke all on function public._decision_has_management(uuid,uuid) from public;
revoke all on function public._decision_has_management(uuid,uuid) from anon;
revoke all on function public._decision_has_management(uuid,uuid) from authenticated;
revoke all on function public._decision_is_executive(uuid,uuid) from public;
revoke all on function public._decision_is_executive(uuid,uuid) from anon;
revoke all on function public._decision_is_executive(uuid,uuid) from authenticated;
revoke all on function public._decision_approval_permission(text) from public;
revoke all on function public._decision_approval_permission(text) from anon;
revoke all on function public._decision_approval_permission(text) from authenticated;
revoke all on function public._decision_required_level(numeric,text) from public;
revoke all on function public._decision_required_level(numeric,text) from anon;
revoke all on function public._decision_required_level(numeric,text) from authenticated;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from public;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from anon;
revoke all on function public._decision_approval_can_act(
  uuid,text,text,uuid,uuid,uuid,numeric,text) from authenticated;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from public;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from anon;
revoke all on function public._decision_actions(uuid,uuid,text,uuid) from authenticated;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from public;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from anon;
revoke all on function public._approval_actions(
  uuid,uuid,text,text,uuid,uuid,numeric,text) from authenticated;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from public;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from anon;
revoke all on function public._decision_upsert_approval(
  uuid,text,uuid,uuid,uuid,text,text,jsonb,numeric,integer,text,
  timestamptz,text,timestamptz) from authenticated;
revoke all on function public._decision_refresh(uuid,uuid) from public;
revoke all on function public._decision_refresh(uuid,uuid) from anon;
revoke all on function public._decision_refresh(uuid,uuid) from authenticated;

revoke all on function public.get_decision_center() from public;
revoke all on function public.get_decision_center() from anon;
revoke all on function public.get_decision_center() from authenticated;
grant execute on function public.get_decision_center() to authenticated;

revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from public;
revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from anon;
revoke all on function public.act_on_decision(uuid,text,uuid,text,text)
  from authenticated;
grant execute on function public.act_on_decision(uuid,text,uuid,text,text)
  to authenticated;

revoke all on function public.act_on_approval(uuid,text,text,text)
  from public;
revoke all on function public.act_on_approval(uuid,text,text,text)
  from anon;
revoke all on function public.act_on_approval(uuid,text,text,text)
  from authenticated;
grant execute on function public.act_on_approval(uuid,text,text,text)
  to authenticated;
$decision_phase2a$;
end;
$decision_installer$;

-- ============================================================
-- Phase 3: execution tracking, acceptance, dependencies,
-- handoffs, and change control.
--
-- Canonical source: mobile/sql/execution-tracking-v1.sql
-- This guarded block applies after Phase 2A and before Phase 2B,
-- because operations performance aggregates task acceptance.
-- Re-running the unified installer is safe.
-- ============================================================
do $execution_installer$
begin
  if to_regclass('public.tasks') is null
     or to_regclass('public.projects') is null
     or to_regclass('public.enterprises') is null
     or to_regclass('public.task_logs') is null
     or to_regclass('public.decision_items') is null then
    raise notice 'Phase 3 skipped: run Phase 1, task extension, and decision approval migrations first.';
    return;
  end if;

  execute $execution_phase3$
-- ============================================================
-- Project Recorder - Phase 3 execution tracking
--
-- Deployment order:
--   unified-platform.sql
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--   execution-tracking-v1.sql
--   operations-economics-v1.sql
--
-- All business tables are private. Clients read and write through the
-- SECURITY DEFINER RPCs at the end of this file.
-- ============================================================

-- ---------------------------------------------------------- acceptance
create table if not exists public.task_acceptance (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  criteria text not null check (char_length(btrim(criteria)) > 0),
  evidence text not null check (char_length(btrim(evidence)) > 0),
  submitter_id uuid not null references public.profiles(id),
  reviewer_id uuid not null references public.profiles(id),
  status text not null default 'pending'
    check (status in ('pending','accepted','rework','cancelled')),
  review_note text not null default '',
  version integer not null default 1 check (version > 0),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------- dependencies
create table if not exists public.task_dependencies (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  depends_on_task_id uuid not null references public.tasks(id) on delete cascade,
  lag_days integer not null default 0 check (lag_days >= 0),
  required boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key (task_id, depends_on_task_id),
  check (task_id<>depends_on_task_id)
);

-- ---------------------------------------------------------- handoffs
create table if not exists public.task_handoffs (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  from_profile_id uuid not null references public.profiles(id),
  to_profile_id uuid not null references public.profiles(id),
  from_department text not null default '',
  to_department text not null default '',
  artifact text not null check (char_length(btrim(artifact)) > 0),
  note text not null default '',
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected')),
  decision_note text not null default '',
  decided_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  decided_at timestamptz,
  version integer not null default 1 check (version > 0),
  check (from_profile_id <> to_profile_id)
);

-- ---------------------------------------------------------- changes
create table if not exists public.change_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  requester_id uuid not null references public.profiles(id),
  title text not null check (char_length(btrim(title)) > 0),
  scope text not null check (char_length(btrim(scope)) > 0),
  reason text not null check (char_length(btrim(reason)) > 0),
  urgency text not null check (char_length(btrim(urgency)) > 0),
  schedule_impact_days integer not null default 0
    check (schedule_impact_days >= 0),
  cost_impact numeric not null default 0 check (cost_impact >= 0),
  resource_impact text not null
    check (char_length(btrim(resource_impact)) > 0),
  risk text not null default 'healthy'
    check (risk in ('severe','risk','attention','healthy')),
  cross_department boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','returned')),
  approver_id uuid references public.profiles(id),
  decision_note text not null default '',
  decision_item_id uuid references public.decision_items(id) on delete set null,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create index if not exists task_dependencies_upstream_idx
  on public.task_dependencies(enterprise_id, depends_on_task_id);
create index if not exists task_handoffs_recipient_idx
  on public.task_handoffs(enterprise_id, to_profile_id, status);
create index if not exists change_requests_project_idx
  on public.change_requests(enterprise_id, project_id, status, created_at desc);

-- ---------------------------------------------------------- immutable audit
create table if not exists public.execution_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  entity_type text not null,
  entity_id text not null,
  action text not null,
  before_data jsonb not null default '{}'::jsonb,
  after_data jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists execution_audit_entity_idx
  on public.execution_audit(enterprise_id, entity_type, entity_id, created_at desc);

create table if not exists public.execution_security_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid references public.enterprises(id) on delete set null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  entity_type text not null default '',
  entity_id text not null default '',
  reason text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists execution_security_audit_actor_idx
  on public.execution_security_audit(enterprise_id, actor_profile_id, created_at desc);

-- ---------------------------------------------------------- RLS / least privilege
alter table public.task_acceptance enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.task_handoffs enable row level security;
alter table public.change_requests enable row level security;
alter table public.execution_audit enable row level security;
alter table public.execution_security_audit enable row level security;

revoke all on table public.task_acceptance from public, anon, authenticated;
revoke all on table public.task_dependencies from public, anon, authenticated;
revoke all on table public.task_handoffs from public, anon, authenticated;
revoke all on table public.change_requests from public, anon, authenticated;
revoke all on table public.execution_audit from public, anon, authenticated;
revoke all on table public.execution_security_audit from public, anon, authenticated;
revoke all on sequence public.execution_audit_id_seq from public, anon, authenticated;
revoke all on sequence public.execution_security_audit_id_seq from public, anon, authenticated;

-- Direct writes are denied. SECURITY DEFINER RPCs are the only write path.
create or replace function public._execution_risk(p_risk text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_risk text:=lower(btrim(coalesce(p_risk,'healthy')));
begin
  if v_risk in ('severe','critical','high','serious',
                U&'\4E25\91CD',U&'\9AD8\98CE\9669') then
    return 'severe';
  end if;
  if v_risk in ('risk','medium','warning',U&'\98CE\9669') then
    return 'risk';
  end if;
  if v_risk in ('attention','low',U&'\5173\6CE8') then
    return 'attention';
  end if;
  if v_risk in ('healthy','',U&'\5065\5EB7') then
    return 'healthy';
  end if;
  return 'attention';
end;
$fn$;

create or replace function public._execution_urgency(p_urgency text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_urgency text:=lower(btrim(coalesce(p_urgency,'')));
begin
  if v_urgency in ('critical','emergency','severe',U&'\4E25\91CD') then
    return 'critical';
  end if;
  if v_urgency in ('urgent',U&'\7D27\6025') then return 'urgent'; end if;
  if v_urgency in ('high',U&'\9AD8') then return 'high'; end if;
  if v_urgency in ('normal','',U&'\666E\901A') then return 'normal'; end if;
  return v_urgency;
end;
$fn$;

create or replace function public._execution_change_requires_approval(
  amount numeric,
  schedule_impact_days integer,
  risk text,
  cross_department boolean,
  urgency text
) returns boolean
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return coalesce(amount,0) >= 50000
    or coalesce(schedule_impact_days,0) > 3
    or public._execution_risk(risk) in ('severe','risk')
    or coalesce(cross_department,false)
    or public._execution_urgency(urgency) in
      ('high','urgent','critical','emergency');
end;
$fn$;

create or replace function public._execution_denied(
  p_eid uuid,
  p_uid uuid,
  p_operation text,
  p_entity_type text,
  p_entity_id text,
  p_reason text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.execution_security_audit(
    enterprise_id,actor_profile_id,operation,entity_type,entity_id,reason,payload
  ) values(
    p_eid,p_uid,btrim(coalesce(p_operation,'')),coalesce(p_entity_type,''),
    coalesce(p_entity_id,''),btrim(coalesce(p_reason,'')),
    coalesce(p_payload,'{}'::jsonb)
  );
  return jsonb_build_object(
    'ok',false,'code','permission_denied',
    'error',coalesce(nullif(btrim(p_operation),''),'operation')
      || ': ' || coalesce(nullif(btrim(p_reason),''),'permission denied')
  );
end;
$fn$;

create or replace function public._execution_success(
  p_eid uuid,
  p_uid uuid,
  p_entity_type text,
  p_entity_id text,
  p_action text,
  p_before jsonb,
  p_after jsonb,
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.execution_audit(
    enterprise_id,actor_profile_id,entity_type,entity_id,action,
    before_data,after_data,metadata
  ) values(
    p_eid,p_uid,coalesce(p_entity_type,''),coalesce(p_entity_id,''),
    coalesce(p_action,''),coalesce(p_before,'{}'::jsonb),
    coalesce(p_after,'{}'::jsonb),coalesce(p_metadata,'{}'::jsonb)
  );
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_eid,p_uid,'execution.'||coalesce(p_action,'changed'),null,
    jsonb_build_object(
      'entity_type',p_entity_type,'entity_id',p_entity_id,
      'before',coalesce(p_before,'{}'::jsonb),
      'after',coalesce(p_after,'{}'::jsonb),
      'metadata',coalesce(p_metadata,'{}'::jsonb)
    )
  );
end;
$fn$;

create or replace function public._execution_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permission text
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return public._decision_has_permission(p_eid,p_uid,p_permission);
end;
$fn$;

create or replace function public._execution_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  return public._decision_has_management(p_eid,p_uid);
end;
$fn$;

create or replace function public._execution_role_key(p_eid uuid,p_uid uuid)
returns text
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce((
    select m.role_key from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
     limit 1
  ),'');
$fn$;

create or replace function public._execution_is_read_only_role(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._execution_role_key(p_eid,p_uid) in ('auditor','supervisor');
$fn$;

create or replace function public._execution_has_project_permission(
  p_eid uuid,
  p_uid uuid,
  p_project uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_scope text;
  v_conditions jsonb;
  v_project_ids jsonb;
  v_project_boss uuid;
  v_actor_department text;
  v_target_department text;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._execution_is_read_only_role(p_eid,p_uid) then return false; end if;
  if exists(
    select 1 from public.enterprises e
     where e.id=p_eid and e.owner_profile_id=p_uid
  ) then return true; end if;
  if p_project is not null then
    select p.boss_id into v_project_boss
      from public.projects p where p.id=p_project;
    if v_project_boss=p_uid then return true; end if;
    select m.department into v_actor_department
      from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active';
    select m.department into v_target_department
      from public.tasks t
      join public.enterprise_members m
        on m.enterprise_id=p_eid and m.profile_id=t.employee_id
       and m.status='active'
     where t.project_id=p_project
     limit 1;
  end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then continue; end if;
    v_scope:=coalesce(v_grant->>'scope','self');
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    if v_scope='company' then return true; end if;
    if p_project is null then continue; end if;
    v_project_ids:=case when jsonb_typeof(v_conditions->'project_ids')='array'
      then v_conditions->'project_ids' else '[]'::jsonb end;
    if v_project_ids ? p_project::text
       or coalesce(v_conditions->>'project_id','')=p_project::text then
      return true;
    end if;
    if v_scope='project'
       and not (v_conditions ? 'project_ids')
       and not (v_conditions ? 'project_id') then
      return true;
    end if;
    if v_scope in ('team','department')
       and v_actor_department is not null
       and v_actor_department=v_target_department then
      return true;
    end if;
    if v_scope='self' and exists(
      select 1 from public.tasks t
       where t.project_id=p_project and t.employee_id=p_uid
    ) then return true; end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._execution_can_submit_task(
  p_eid uuid,
  p_uid uuid,
  p_task uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_task public.tasks%rowtype;
begin
  if p_uid is null or public._execution_is_read_only_role(p_eid,p_uid) then
    return false;
  end if;
  select * into v_task from public.tasks where id=p_task;
  if not found then return false; end if;
  if p_uid in (v_task.boss_id,v_task.employee_id) then return true; end if;
  return public._execution_has_project_permission(
    p_eid,p_uid,v_task.project_id,array['tasks.assign']::text[]);
end;
$fn$;

create or replace function public._execution_can_review_task(
  p_eid uuid,
  p_uid uuid,
  p_task uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_task public.tasks%rowtype;
begin
  if p_uid is null or public._execution_is_read_only_role(p_eid,p_uid) then
    return false;
  end if;
  select * into v_task from public.tasks where id=p_task;
  if not found then return false; end if;
  return public._execution_has_project_permission(
    p_eid,p_uid,v_task.project_id,array['tasks.grade']::text[]);
end;
$fn$;

create or replace function public._execution_can_manage_task(
  p_eid uuid,
  p_uid uuid,
  p_task uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_task public.tasks%rowtype;
begin
  if p_uid is null or public._execution_is_read_only_role(p_eid,p_uid) then
    return false;
  end if;
  select * into v_task from public.tasks where id=p_task;
  if not found then return false; end if;
  return public._execution_has_project_permission(
    p_eid,p_uid,v_task.project_id,
    array['tasks.assign','projects.manage']::text[]);
end;
$fn$;

create or replace function public._execution_can_handoff_task(
  p_eid uuid,
  p_uid uuid,
  p_task uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_task public.tasks%rowtype;
begin
  if p_uid is null or public._execution_is_read_only_role(p_eid,p_uid) then
    return false;
  end if;
  select * into v_task from public.tasks where id=p_task;
  if not found then return false; end if;
  if p_uid in (v_task.boss_id,v_task.employee_id) then return true; end if;
  return public._execution_has_project_permission(
    p_eid,p_uid,v_task.project_id,
    array['tasks.assign','people.manage']::text[]);
end;
$fn$;

create or replace function public._execution_can_manage_change(
  p_eid uuid,
  p_uid uuid,
  p_project uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._execution_has_project_permission(
    p_eid,p_uid,p_project,array['projects.manage']::text[]);
$fn$;

create or replace function public._execution_task_enterprise(p_task uuid)
returns uuid
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_boss uuid;
begin
  select boss_id into v_boss from public.tasks where id=p_task;
  if v_boss is null then return null; end if;
  return public._identity_bootstrap(v_boss);
end;
$fn$;

create or replace function public._execution_guard_task_log()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_task public.tasks%rowtype;
  v_eid uuid;
begin
  select * into v_task from public.tasks where id=new.task_id;
  if not found then raise exception 'task not found'; end if;
  if new.employee_id is distinct from v_task.employee_id then
    raise exception 'task log employee must match assignee';
  end if;
  if coalesce(v_task.accept_status,'pending')<>'accepted' then
    raise exception 'assignment must be accepted before completion';
  end if;
  v_eid:=public._execution_task_enterprise(new.task_id);
  if v_eid is null or not public._execution_can_submit_task(
    v_eid,new.employee_id,new.task_id
  ) then
    raise exception 'read-only role cannot create completion evidence';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_execution_task_log_guard on public.task_logs;
create trigger trg_execution_task_log_guard
  before insert or update of task_id,employee_id on public.task_logs
  for each row execute function public._execution_guard_task_log();

create or replace function public._execution_dependency_cycle(
  p_eid uuid,
  p_task uuid,
  p_depends_on uuid
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if p_task=p_depends_on then return true; end if;
  return exists(
    with recursive chain(task_id,path) as (
      select d.depends_on_task_id,array[p_depends_on,d.depends_on_task_id]
        from public.task_dependencies d
       where d.enterprise_id=p_eid and d.task_id=p_depends_on
      union all
      select d.depends_on_task_id,chain.path||d.depends_on_task_id
        from chain
        join public.task_dependencies d
          on d.enterprise_id=p_eid and d.task_id=chain.task_id
       where not d.depends_on_task_id=any(chain.path)
    )
    select 1 from chain where task_id=p_task
  );
end;
$fn$;

create or replace function public._execution_downstream(
  p_eid uuid,
  p_task uuid,
  p_delay_days integer
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_delay integer:=greatest(coalesce(p_delay_days,0),0);
begin
  if v_delay<=0 then return '[]'::jsonb; end if;
  return (
    with recursive affected(task_id,delay_days,path) as (
      select d.task_id,v_delay+d.lag_days,array[p_task,d.task_id]
        from public.task_dependencies d
       where d.enterprise_id=p_eid and d.depends_on_task_id=p_task
         and coalesce(d.required,true)=true
      union all
      select d.task_id,affected.delay_days+d.lag_days,
             affected.path||d.task_id
        from affected
        join public.task_dependencies d
          on d.enterprise_id=p_eid and d.depends_on_task_id=affected.task_id
       where d.required=true
         and not d.task_id=any(affected.path)
    ), best as (
      select task_id,max(delay_days) as delay_days
        from affected group by task_id
    )
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'task_id',b.task_id,
        'title',t.title,
        'employee_id',t.employee_id,
        'employee_name',p.name,
        'project_id',t.project_id,
        'plan_date',t.plan_date,
        'projected_date',t.plan_date+b.delay_days,
        'delay_days',b.delay_days,
        'required',true
      ) order by b.delay_days,b.task_id
    ),'[]'::jsonb)
    from best b
    join public.tasks t on t.id=b.task_id
    left join public.profiles p on p.id=t.employee_id
  );
end;
$fn$;

-- ---------------------------------------------------------- acceptance RPCs
create or replace function public.submit_task_acceptance(
  p_task uuid,
  p_criteria text,
  p_evidence text,
  p_reviewer uuid,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_eid uuid;
  v_old public.task_acceptance%rowtype;
  v_before jsonb:='{}'::jsonb;
  v_criteria text:=btrim(coalesce(p_criteria,''));
  v_evidence text:=btrim(coalesce(p_evidence,''));
  v_note text:=btrim(coalesce(p_note,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null then raise exception 'task enterprise not found'; end if;
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'submit_task_acceptance','task',p_task::text,
      'active enterprise member required');
  end if;
  if not public._execution_can_submit_task(v_eid,v_uid,p_task) then
    return public._execution_denied(
      v_eid,v_uid,'submit_task_acceptance','task',p_task::text,
      'assignee or tasks.assign authority required');
  end if;
  if coalesce(v_task.accept_status,'pending')<>'accepted' then
    raise exception 'assignment must be accepted before acceptance submission';
  end if;
  if not exists(select 1 from public.task_logs l where l.task_id=p_task) then
    raise exception 'task completion log required before acceptance';
  end if;
  if v_criteria='' then raise exception 'acceptance criteria required'; end if;
  if v_evidence='' then raise exception 'evidence required'; end if;
  if p_reviewer is null or p_reviewer=v_uid then
    raise exception 'independent reviewer required';
  end if;
  if not public._identity_is_member(v_eid,p_reviewer) then
    raise exception 'reviewer must be an active enterprise member';
  end if;
  if not public._execution_can_review_task(v_eid,p_reviewer,p_task) then
    raise exception 'reviewer requires tasks.grade authority';
  end if;
  select * into v_old from public.task_acceptance
   where task_id=p_task for update;
  if found then
    v_before:=to_jsonb(v_old);
    if v_old.status='accepted' then
      raise exception 'accepted record is final';
    end if;
  end if;
  insert into public.task_acceptance(
    task_id,enterprise_id,criteria,evidence,submitter_id,reviewer_id,
    status,review_note,version,submitted_at,reviewed_at,updated_at
  ) values(
    p_task,v_eid,v_criteria,v_evidence,v_uid,p_reviewer,
    'pending',v_note,1,now(),null,now()
  )
  on conflict(task_id) do update set
    criteria=excluded.criteria,
    evidence=excluded.evidence,
    submitter_id=excluded.submitter_id,
    reviewer_id=excluded.reviewer_id,
    status='pending',
    review_note=excluded.review_note,
    version=public.task_acceptance.version+1,
    submitted_at=now(),
    reviewed_at=null,
    updated_at=now();
  select * into v_old from public.task_acceptance where task_id=p_task;
  perform public._execution_success(
    v_eid,v_uid,'task_acceptance',p_task::text,'acceptance.submitted',
    v_before,to_jsonb(v_old),
    jsonb_build_object('criteria',v_criteria,'reviewer_id',p_reviewer));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'status','pending',
    'reviewer_id',p_reviewer,'evidence',v_evidence);
end;
$fn$;

create or replace function public.review_task_acceptance(
  p_task uuid,
  p_decision text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.task_acceptance%rowtype;
  v_before jsonb;
  v_removed integer:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('accepted','rework') then
    raise exception 'decision must be accepted or rework';
  end if;
  select * into v_row from public.task_acceptance
   where task_id=p_task for update;
  if not found then raise exception 'acceptance record not found'; end if;
  if not public._execution_can_review_task(
    v_row.enterprise_id,v_uid,p_task
  ) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'review_task_acceptance',
      'task_acceptance',p_task::text,
      'tasks.grade authority required');
  end if;
  if v_row.reviewer_id=v_row.submitter_id then
    raise exception 'independent reviewer required';
  end if;
  if btrim(v_row.criteria)='' then raise exception 'acceptance criteria required'; end if;
  if btrim(v_row.evidence)='' then raise exception 'evidence required'; end if;
  if v_row.status='accepted' then
    if v_decision='accepted' then
      return jsonb_build_object('ok',true,'status','accepted','duplicate',true);
    end if;
    raise exception 'accepted record is final';
  end if;
  if v_row.status<>'pending' then
    raise exception 'task is not pending acceptance';
  end if;
  if v_decision='rework' and v_note='' then
    raise exception 'rework note required';
  end if;
  if not exists(
    select 1 from public.tasks t
     where t.id=p_task and coalesce(t.accept_status,'pending')='accepted'
  ) then
    raise exception 'assignment must be accepted before acceptance review';
  end if;
  if not exists(select 1 from public.task_logs l where l.task_id=p_task) then
    raise exception 'task completion log required before final acceptance';
  end if;
  v_before:=to_jsonb(v_row);
  if v_decision='rework' then
    delete from public.task_logs where task_id=p_task;
    get diagnostics v_removed = row_count;
    insert into public.task_events(
      id,boss_id,employee_id,task_id,kind,title
    )
    select gen_random_uuid(),t.boss_id,t.employee_id,t.id,'undone',t.title
      from public.tasks t where t.id=p_task;
  end if;
  update public.task_acceptance set
    status=v_decision,
    review_note=v_note,
    reviewed_at=now(),
    version=version+1,
    updated_at=now()
  where task_id=p_task
  returning * into v_row;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'task_acceptance',p_task::text,
    'acceptance.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object(
      'note',v_note,'final_complete',v_decision='accepted',
      'reopened',v_decision='rework'));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'status',v_decision,
    'final_complete',v_decision='accepted','duplicate',false,
    'reopened',v_decision='rework',
    'completion_logs_removed',v_removed);
end;
$fn$;

-- ---------------------------------------------------------- dependency RPC
create or replace function public.upsert_task_dependency(
  p_task uuid,
  p_depends_on uuid,
  p_lag_days integer default 0,
  p_required boolean default true
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_dep public.tasks%rowtype;
  v_eid uuid;
  v_lag integer:=greatest(coalesce(p_lag_days,0),0);
  v_before jsonb:='{}'::jsonb;
  v_after jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  select * into v_dep from public.tasks where id=p_depends_on for update;
  if not found then raise exception 'dependency task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null or v_eid is distinct from
       public._execution_task_enterprise(p_depends_on) then
    raise exception 'tasks must belong to the same enterprise';
  end if;
  if not public._execution_can_manage_task(v_eid,v_uid,p_task) then
    return public._execution_denied(
      v_eid,v_uid,'upsert_task_dependency','task',p_task::text,
      'tasks.assign or projects.manage authority required');
  end if;
  if p_task=p_depends_on then
    raise exception 'dependency cycle detected';
  end if;
  if public._execution_dependency_cycle(v_eid,p_task,p_depends_on) then
    insert into public.execution_security_audit(
      enterprise_id,actor_profile_id,operation,entity_type,entity_id,reason,payload
    ) values(
      v_eid,v_uid,'upsert_task_dependency','task',p_task::text,
      'dependency cycle detected',
      jsonb_build_object('depends_on_task_id',p_depends_on)
    );
    return jsonb_build_object(
      'ok',false,'code','dependency_cycle',
      'error','upsert_task_dependency: dependency cycle detected');
  end if;
  select to_jsonb(d) into v_before from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on;
  insert into public.task_dependencies(
    enterprise_id,task_id,depends_on_task_id,lag_days,required,created_by
  ) values(v_eid,p_task,p_depends_on,v_lag,coalesce(p_required,true),v_uid)
  on conflict(task_id,depends_on_task_id) do update set
    lag_days=excluded.lag_days,
    required=excluded.required;
  select to_jsonb(d) into v_after from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on;
  perform public._execution_success(
    v_eid,v_uid,'task_dependency',p_task::text||':'||p_depends_on::text,
    'dependency.saved',coalesce(v_before,'{}'::jsonb),v_after,
    jsonb_build_object('lag_days',v_lag,'required',coalesce(p_required,true)));
  return jsonb_build_object(
    'ok',true,'task_id',p_task,'depends_on_task_id',p_depends_on,
    'lag_days',v_lag,'required',coalesce(p_required,true),
    'downstream_impact',public._execution_downstream(v_eid,p_depends_on,v_lag));
end;
$fn$;

create or replace function public.delete_task_dependency(
  p_task uuid,
  p_depends_on uuid
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null or v_eid is distinct from
       public._execution_task_enterprise(p_depends_on) then
    raise exception 'tasks must belong to the same enterprise';
  end if;
  if not public._execution_can_manage_task(v_eid,v_uid,p_task) then
    return public._execution_denied(
      v_eid,v_uid,'delete_task_dependency','task',p_task::text,
      'tasks.assign or projects.manage authority required');
  end if;
  select to_jsonb(d) into v_before from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on
   for update;
  if v_before is null then
    return jsonb_build_object(
      'ok',true,'duplicate',true,'task_id',p_task,
      'depends_on_task_id',p_depends_on);
  end if;
  delete from public.task_dependencies d
   where d.task_id=p_task and d.depends_on_task_id=p_depends_on;
  perform public._execution_success(
    v_eid,v_uid,'task_dependency',p_task::text||':'||p_depends_on::text,
    'dependency.deleted',v_before,'{}'::jsonb,'{}'::jsonb);
  return jsonb_build_object(
    'ok',true,'duplicate',false,'task_id',p_task,
    'depends_on_task_id',p_depends_on);
end;
$fn$;

-- ---------------------------------------------------------- handoff RPCs
create or replace function public.create_task_handoff(
  p_task uuid,
  p_to uuid,
  p_artifact text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_task public.tasks%rowtype;
  v_eid uuid;
  v_artifact text:=btrim(coalesce(p_artifact,''));
  v_note text:=btrim(coalesce(p_note,''));
  v_from_dept text:='';
  v_to_dept text:='';
  v_row public.task_handoffs%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_task from public.tasks where id=p_task for update;
  if not found then raise exception 'task not found'; end if;
  v_eid:=public._execution_task_enterprise(p_task);
  if v_eid is null then raise exception 'task enterprise not found'; end if;
  if not public._execution_can_handoff_task(v_eid,v_uid,p_task) then
    return public._execution_denied(
      v_eid,v_uid,'create_task_handoff','task',p_task::text,
      'task participant, tasks.assign, or people.manage authority required');
  end if;
  if p_to is null or p_to=v_uid then
    raise exception 'handoff recipient must be another profile';
  end if;
  if not public._identity_is_member(v_eid,p_to) then
    raise exception 'handoff recipient must be an active enterprise member';
  end if;
  if v_artifact='' then raise exception 'handoff artifact required'; end if;
  select coalesce(department,'') into v_from_dept
    from public.enterprise_members
   where enterprise_id=v_eid and profile_id=v_uid and status='active'
   limit 1;
  select coalesce(department,'') into v_to_dept
    from public.enterprise_members
   where enterprise_id=v_eid and profile_id=p_to and status='active'
   limit 1;
  insert into public.task_handoffs(
    enterprise_id,task_id,from_profile_id,to_profile_id,
    from_department,to_department,artifact,note,status
  ) values(
    v_eid,p_task,v_uid,p_to,coalesce(v_from_dept,''),coalesce(v_to_dept,''),
    v_artifact,v_note,'pending'
  ) returning * into v_row;
  perform public._execution_success(
    v_eid,v_uid,'task_handoff',v_row.id::text,'handoff.created',
    '{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('recipient',p_to));
  return jsonb_build_object(
    'ok',true,'handoff_id',v_row.id,'status','pending',
    'to_profile_id',p_to,'artifact',v_artifact);
end;
$fn$;

create or replace function public.accept_task_handoff(
  p_handoff uuid,
  p_decision text,
  p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.task_handoffs%rowtype;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('accepted','rejected') then
    raise exception 'decision must be accepted or rejected';
  end if;
  select * into v_row from public.task_handoffs where id=p_handoff for update;
  if not found then raise exception 'handoff not found'; end if;
  if public._execution_is_read_only_role(v_row.enterprise_id,v_uid) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'accept_task_handoff','task_handoff',
      p_handoff::text,'read-only role cannot decide handoffs');
  end if;
  if v_row.to_profile_id<>v_uid then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'accept_task_handoff','task_handoff',
      p_handoff::text,'only the handoff recipient can decide');
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_decision then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true);
    end if;
    raise exception 'handoff already decided';
  end if;
  if v_decision='rejected' and v_note='' then
    raise exception 'rejection note required';
  end if;
  v_before:=to_jsonb(v_row);
  update public.task_handoffs set
    status=v_decision,
    decision_note=v_note,
    decided_by=v_uid,
    accepted_at=case when v_decision='accepted' then now() else accepted_at end,
    decided_at=now(),
    version=version+1
  where id=p_handoff
  returning * into v_row;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'task_handoff',p_handoff::text,
    'handoff.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object('note',v_note));
  return jsonb_build_object(
    'ok',true,'handoff_id',p_handoff,'status',v_decision,
    'duplicate',false);
end;
$fn$;

-- ---------------------------------------------------------- change control
create or replace function public.create_change_request(
  p_project uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_project public.projects%rowtype;
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_scope text:=btrim(coalesce(v_data->>'scope',''));
  v_reason text:=btrim(coalesce(v_data->>'reason',''));
  v_urgency text:=public._execution_urgency(v_data->>'urgency');
  v_resource text:=btrim(coalesce(v_data->>'resource_impact',''));
  v_schedule integer;
  v_cost numeric;
  v_risk text:=public._execution_risk(v_data->>'risk');
  v_cross boolean:=coalesce((v_data->>'cross_department')::boolean,false);
  v_high boolean:=false;
  v_row public.change_requests%rowtype;
  v_decision_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_project from public.projects where id=p_project for update;
  if not found then raise exception 'project not found'; end if;
  v_eid:=public._identity_bootstrap(v_project.boss_id);
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'create_change_request','project',p_project::text,
      'active enterprise member required');
  end if;
  if not public._execution_can_manage_change(v_eid,v_uid,p_project) then
    return public._execution_denied(
      v_eid,v_uid,'create_change_request','project',p_project::text,
      'projects.manage authority required');
  end if;
  if v_title='' then v_title:=left(v_scope,120); end if;
  if v_scope='' or v_reason='' or v_urgency='' or v_resource=''
     or not (v_data ? 'schedule_impact_days')
     or not (v_data ? 'cost_impact') then
    raise exception 'scope, reason, urgency, schedule, cost, and resource impact are required';
  end if;
  v_schedule:=greatest(coalesce((v_data->>'schedule_impact_days')::integer,0),0);
  v_cost:=greatest(coalesce((v_data->>'cost_impact')::numeric,0),0);
  v_high:=public._execution_change_requires_approval(
    v_cost,v_schedule,v_risk,v_cross,v_urgency);
  insert into public.change_requests(
    enterprise_id,project_id,requester_id,title,scope,reason,urgency,
    schedule_impact_days,cost_impact,resource_impact,risk,cross_department,
    status
  ) values(
    v_eid,p_project,v_uid,v_title,v_scope,v_reason,v_urgency,
    v_schedule,v_cost,v_resource,v_risk,v_cross,'pending'
  ) returning * into v_row;
  if v_high then
    insert into public.decision_items(
      enterprise_id,source_type,source_id,title,detail,evidence,risk,
      impact_days,impact_amount,owner_profile_id,status,due_at
    ) values(
      v_eid,'change',v_row.id,v_title,v_reason,
      jsonb_build_array(jsonb_build_object(
        'type','change_request','id',v_row.id,'project_id',p_project,
        'scope',v_scope,'urgency',v_urgency,
        'schedule_impact_days',v_schedule,'cost_impact',v_cost,
        'resource_impact',v_resource,'cross_department',v_cross)),
      v_risk,v_schedule,v_cost,v_project.boss_id,'open',
      now()+case when v_urgency in ('urgent','critical','emergency')
        then interval '1 day' else interval '3 days' end
    )
    on conflict(enterprise_id,source_type,source_id) do update set
      title=excluded.title,detail=excluded.detail,evidence=excluded.evidence,
      risk=excluded.risk,impact_days=excluded.impact_days,
      impact_amount=excluded.impact_amount,owner_profile_id=excluded.owner_profile_id,
      updated_at=now()
    returning id into v_decision_id;
    update public.change_requests set decision_item_id=v_decision_id
      where id=v_row.id returning * into v_row;
  end if;
  perform public._execution_success(
    v_eid,v_uid,'change_request',v_row.id::text,'change.created',
    '{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('high_impact',v_high,'decision_item_id',v_decision_id));
  return jsonb_build_object(
    'ok',true,'change_id',v_row.id,'status','pending',
    'high_impact',v_high,'decision_item_id',v_decision_id,
    'plan_mutated',false);
end;
$fn$;

create or replace function public.decide_change_request(
  p_change uuid,
  p_decision text,
  p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_note text:=btrim(coalesce(p_note,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_row public.change_requests%rowtype;
  v_before jsonb;
  v_high boolean;
  v_event_action text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_decision not in ('approved','rejected','returned') then
    raise exception 'decision must be approved, rejected, or returned';
  end if;
  select * into v_row from public.change_requests
   where id=p_change for update;
  if not found then raise exception 'change request not found'; end if;
  if not public._execution_can_manage_change(
    v_row.enterprise_id,v_uid,v_row.project_id
  ) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'decide_change_request',
      'change_request',p_change::text,'projects.manage authority required');
  end if;
  v_high:=public._execution_change_requires_approval(
    v_row.cost_impact,v_row.schedule_impact_days,v_row.risk,
    v_row.cross_department,v_row.urgency);
  if v_high and not public._decision_is_executive(v_row.enterprise_id,v_uid) then
    return public._execution_denied(
      v_row.enterprise_id,v_uid,'decide_change_request',
      'change_request',p_change::text,
      'executive approval required for high impact change');
  end if;
  if v_row.status<>'pending' then
    if v_row.status=v_decision then
      return jsonb_build_object(
        'ok',true,'status',v_row.status,'duplicate',true,
        'plan_mutated',false);
    end if;
    raise exception 'change request already decided';
  end if;
  if v_decision in ('rejected','returned') and v_note='' then
    raise exception 'decision note required';
  end if;
  v_before:=to_jsonb(v_row);
  update public.change_requests set
    status=v_decision,
    approver_id=v_uid,
    decision_note=v_note,
    decided_at=now(),
    version=version+1
  where id=p_change
  returning * into v_row;
  if v_row.decision_item_id is not null then
    v_event_action:=case v_decision
      when 'approved' then 'resolved'
      when 'rejected' then 'dismissed'
      else 'deferred' end;
    update public.decision_items set
      status=v_event_action,
      resolution=v_note,
      owner_profile_id=coalesce(owner_profile_id,v_uid),
      version=version+1,
      updated_at=now()
    where id=v_row.decision_item_id and status in
      ('open','acknowledged','assigned','deferred');
    insert into public.decision_events(
      decision_id,actor_profile_id,action,note,idempotency_key
    ) values(
      v_row.decision_item_id,v_uid,v_event_action,v_note,
      coalesce(nullif(v_key,''),'change:'||p_change::text||':'||v_row.version::text)
    );
  end if;
  perform public._execution_success(
    v_row.enterprise_id,v_uid,'change_request',p_change::text,
    'change.'||v_decision,v_before,to_jsonb(v_row),
    jsonb_build_object(
      'note',v_note,'high_impact',v_high,
      'decision_item_id',v_row.decision_item_id,'plan_mutated',false));
  return jsonb_build_object(
    'ok',true,'change_id',p_change,'status',v_decision,
    'high_impact',v_high,'duplicate',false,'plan_mutated',false);
end;
$fn$;

create or replace function public._execution_sync_change_from_decision()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_status text;
  v_change public.change_requests%rowtype;
begin
  if new.source_type<>'change' then return new; end if;
  select * into v_change from public.change_requests
   where id=new.source_id and decision_item_id=new.id;
  if found and auth.uid() is not null then
    if not public._execution_can_manage_change(
      new.enterprise_id,auth.uid(),v_change.project_id
    ) then
      raise exception 'projects.manage authority required';
    end if;
    if public._execution_change_requires_approval(
      v_change.cost_impact,v_change.schedule_impact_days,v_change.risk,
      v_change.cross_department,v_change.urgency
    ) and not public._decision_is_executive(new.enterprise_id,auth.uid()) then
      raise exception 'executive approval required for high impact change';
    end if;
  end if;
  v_status:=case new.status
    when 'resolved' then 'approved'
    when 'dismissed' then 'rejected'
    when 'deferred' then 'returned'
    else 'pending' end;
  update public.change_requests c set
    status=v_status,
    approver_id=case when v_status in ('approved','rejected')
      then coalesce(auth.uid(),c.approver_id) else c.approver_id end,
    decision_note=case when btrim(coalesce(new.resolution,''))<>''
      then new.resolution else c.decision_note end,
    decided_at=case when v_status in ('approved','rejected','returned')
      then now() else c.decided_at end,
    version=c.version+1
  where c.id=new.source_id
    and c.decision_item_id=new.id
    and c.status is distinct from v_status;
  return new;
end;
$fn$;

drop trigger if exists trg_execution_sync_change_from_decision
  on public.decision_items;
create trigger trg_execution_sync_change_from_decision
  after update of status,resolution on public.decision_items
  for each row execute function public._execution_sync_change_from_decision();

-- ---------------------------------------------------------- board query
create or replace function public.get_execution_board(
  p_enterprise uuid default null
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=p_enterprise;
  v_management boolean;
  v_read_only boolean;
  v_can_accept boolean;
  v_can_dependencies boolean;
  v_can_handoff boolean;
  v_can_changes boolean;
  v_acceptance jsonb:='[]'::jsonb;
  v_dependencies jsonb:='[]'::jsonb;
  v_handoffs jsonb:='[]'::jsonb;
  v_changes jsonb:='[]'::jsonb;
  v_tasks jsonb:='[]'::jsonb;
  v_projects jsonb:='[]'::jsonb;
  v_members jsonb:='[]'::jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    select e.id into v_eid
      from public.enterprises e
     where e.owner_profile_id=v_uid
     order by e.created_at
     limit 1;
    if v_eid is null then
      select m.enterprise_id into v_eid
        from public.enterprise_members m
       where m.profile_id=v_uid and m.status='active'
       order by m.created_at
       limit 1;
    end if;
  end if;
  if v_eid is null then
    return public._execution_denied(
      null,v_uid,'get_execution_board','enterprise','',
      'active enterprise membership required');
  end if;
  if not public._identity_is_member(v_eid,v_uid) then
    return public._execution_denied(
      v_eid,v_uid,'get_execution_board','enterprise',v_eid::text,
      'active enterprise membership required');
  end if;
  v_management:=public._execution_has_management(v_eid,v_uid);
  v_read_only:=public._execution_is_read_only_role(v_eid,v_uid);
  v_can_accept:=public._execution_has_permission(v_eid,v_uid,'tasks.grade');
  v_can_dependencies:=public._execution_has_permission(
    v_eid,v_uid,'tasks.assign')
    or public._execution_has_permission(v_eid,v_uid,'projects.manage');
  v_can_handoff:=public._execution_has_permission(v_eid,v_uid,'tasks.assign')
    or public._execution_has_permission(v_eid,v_uid,'people.manage');
  v_can_changes:=public._execution_has_permission(
    v_eid,v_uid,'projects.manage');

  select coalesce(jsonb_agg(acceptance.row order by acceptance.sort_at desc),'[]'::jsonb)
    into v_acceptance
    from (
      select jsonb_build_object(
        'task_id',a.task_id,
        'title',t.title,
        'project_id',t.project_id,
        'plan_date',t.plan_date,
        'criteria',a.criteria,
        'evidence',a.evidence,
        'submitter_id',a.submitter_id,
        'submitter_name',sp.name,
        'reviewer_id',a.reviewer_id,
        'reviewer_name',rp.name,
        'status',a.status,
        'review_note',a.review_note,
        'version',a.version,
        'submitted_at',a.submitted_at,
        'reviewed_at',a.reviewed_at,
        'actions',jsonb_build_object(
          'accept',a.status='pending'
            and public._execution_can_review_task(v_eid,v_uid,a.task_id),
          'rework',a.status='pending'
            and public._execution_can_review_task(v_eid,v_uid,a.task_id))
      ) row,
      a.submitted_at sort_at
      from public.task_acceptance a
      join public.tasks t on t.id=a.task_id
      left join public.profiles sp on sp.id=a.submitter_id
      left join public.profiles rp on rp.id=a.reviewer_id
      where a.enterprise_id=v_eid
        and (v_management or a.reviewer_id=v_uid or a.submitter_id=v_uid
             or t.boss_id=v_uid or t.employee_id=v_uid)
      order by a.submitted_at desc
      limit 100
    ) acceptance;

  select coalesce(jsonb_agg(handoffs.row order by handoffs.sort_at desc),'[]'::jsonb)
    into v_handoffs
    from (
      select jsonb_build_object(
        'id',h.id,
        'task_id',h.task_id,
        'title',t.title,
        'artifact',h.artifact,
        'note',h.note,
        'from_profile_id',h.from_profile_id,
        'from_name',fp.name,
        'to_profile_id',h.to_profile_id,
        'to_name',tp.name,
        'from_department',h.from_department,
        'to_department',h.to_department,
        'status',h.status,
        'decision_note',h.decision_note,
        'created_at',h.created_at,
        'accepted_at',h.accepted_at,
        'decided_at',h.decided_at,
        'version',h.version,
        'actions',jsonb_build_object(
          'accept',h.status='pending' and not v_read_only
            and h.to_profile_id=v_uid,
          'reject',h.status='pending' and not v_read_only
            and h.to_profile_id=v_uid)
      ) row,
      h.created_at sort_at
      from public.task_handoffs h
      join public.tasks t on t.id=h.task_id
      left join public.profiles fp on fp.id=h.from_profile_id
      left join public.profiles tp on tp.id=h.to_profile_id
      where h.enterprise_id=v_eid
        and (v_management or h.from_profile_id=v_uid or h.to_profile_id=v_uid)
      order by h.created_at desc
      limit 100
    ) handoffs;

  select coalesce(jsonb_agg(changes.row order by changes.sort_at desc),'[]'::jsonb)
    into v_changes
    from (
      select jsonb_build_object(
        'id',c.id,
        'project_id',c.project_id,
        'project_name',pr.name,
        'requester_id',c.requester_id,
        'requester_name',rp.name,
        'title',c.title,
        'scope',c.scope,
        'reason',c.reason,
        'urgency',c.urgency,
        'schedule_impact_days',c.schedule_impact_days,
        'cost_impact',c.cost_impact,
        'resource_impact',c.resource_impact,
        'risk',c.risk,
        'cross_department',c.cross_department,
        'status',c.status,
        'approver_id',c.approver_id,
        'decision_note',c.decision_note,
        'decision_item_id',c.decision_item_id,
        'version',c.version,
        'created_at',c.created_at,
        'decided_at',c.decided_at,
        'high_impact',high_impact,
        'plan_mutated',false,
        'actions',jsonb_build_object(
          'approve',c.status='pending' and can_decide,
          'reject',c.status='pending' and can_decide,
          'return',c.status='pending' and can_decide)
      ) row,
      c.created_at sort_at
      from (
        select c.*,
          public._execution_change_requires_approval(
            c.cost_impact,c.schedule_impact_days,c.risk,
            c.cross_department,c.urgency) high_impact,
          public._execution_can_manage_change(v_eid,v_uid,c.project_id)
            and (
              not public._execution_change_requires_approval(
                c.cost_impact,c.schedule_impact_days,c.risk,
                c.cross_department,c.urgency)
              or public._decision_is_executive(v_eid,v_uid)
            ) can_decide
          from public.change_requests c
         where c.enterprise_id=v_eid
      ) c
      join public.projects pr on pr.id=c.project_id
      left join public.profiles rp on rp.id=c.requester_id
      where v_management or c.requester_id=v_uid
      order by c.created_at desc
      limit 100
    ) changes;

  select coalesce(
    jsonb_agg(dependencies.row order by dependencies.delayed_days desc,dependencies.task_id),'[]'::jsonb
  ) into v_dependencies
  from (
    select jsonb_build_object(
      'task_id',d.task_id,
      'depends_on_task_id',d.depends_on_task_id,
      'title',t.title,
      'depends_on_title',u.title,
      'employee_id',t.employee_id,
      'employee_name',ep.name,
      'upstream_employee_id',u.employee_id,
      'upstream_employee_name',up.name,
      'project_id',t.project_id,
      'lag_days',d.lag_days,
      'required',d.required,
      'upstream_status',coalesce(a.status,'not_submitted'),
      'upstream_due_date',u.plan_date,
      'delayed_days',x.delayed_days,
      'blocked',coalesce(d.required,true) and x.delayed_days>0,
      'affected_tasks',public._execution_downstream(
        v_eid,d.depends_on_task_id,
        case when coalesce(d.required,true) then x.delayed_days else 0 end),
      'actions',jsonb_build_object(
        'remove',public._execution_can_manage_task(v_eid,v_uid,d.task_id))
    ) row,
    x.delayed_days,
    d.task_id
    from public.task_dependencies d
    join public.tasks t on t.id=d.task_id
    join public.tasks u on u.id=d.depends_on_task_id
    left join public.task_acceptance a on a.task_id=d.depends_on_task_id
    left join public.profiles ep on ep.id=t.employee_id
    left join public.profiles up on up.id=u.employee_id
    cross join lateral (
      select case
        when coalesce(a.status,'not_submitted')<>'accepted'
         and u.plan_date<current_date
        then current_date-u.plan_date else 0 end as delayed_days
    ) x
    where d.enterprise_id=v_eid
      and (v_management or t.boss_id=v_uid or t.employee_id=v_uid)
    order by x.delayed_days desc,d.task_id
    limit 200
  ) dependencies;

  select coalesce(jsonb_agg(tasks.row order by tasks.plan_date,tasks.title),'[]'::jsonb)
    into v_tasks
    from (
      select jsonb_build_object(
        'id',t.id,'title',t.title,'project_id',t.project_id,
        'employee_id',t.employee_id,'employee_name',ep.name,
        'plan_date',t.plan_date,
        'assignment_status',coalesce(t.accept_status,'pending'),
        'acceptance_status',coalesce(a.status,'not_submitted'),
        'criteria',a.criteria,'evidence',a.evidence,
        'reviewer_id',a.reviewer_id,
        'actions',jsonb_build_object(
          'submit_acceptance',coalesce(t.accept_status,'pending')='accepted'
            and coalesce(a.status,'not_submitted')<>'accepted'
            and exists(select 1 from public.task_logs l where l.task_id=t.id)
            and public._execution_can_submit_task(v_eid,v_uid,t.id),
          'handoff',public._execution_can_handoff_task(v_eid,v_uid,t.id),
          'dependency',public._execution_can_manage_task(v_eid,v_uid,t.id))
      ) row,
      t.plan_date,t.title
      from public.tasks t
      left join public.profiles ep on ep.id=t.employee_id
      left join public.task_acceptance a on a.task_id=t.id
      where public._execution_task_enterprise(t.id)=v_eid
        and (v_management or t.boss_id=v_uid or t.employee_id=v_uid)
      order by t.plan_date,t.title
      limit 500
    ) tasks;

  select coalesce(jsonb_agg(projects.row order by projects.name),'[]'::jsonb)
    into v_projects
    from (
      select jsonb_build_object(
        'id',pr.id,'name',pr.name,'due_date',pr.due_date,
        'status',pr.status
      ) row,
      pr.name
      from public.projects pr
      where exists(
        select 1 from public.enterprise_members m
         where m.enterprise_id=v_eid and m.profile_id=pr.boss_id
           and m.status='active'
      ) and (v_management or pr.boss_id=v_uid)
      order by pr.name
      limit 500
    ) projects;

  select coalesce(jsonb_agg(members.row order by members.name),'[]'::jsonb)
    into v_members
    from (
      select jsonb_build_object(
        'id',m.profile_id,'name',p.name,'department',m.department,
        'role_key',m.role_key
      ) row,
      p.name
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
      order by p.name
      limit 500
    ) members;

  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'acceptance',v_acceptance,
    'dependencies',v_dependencies,
    'handoffs',v_handoffs,
    'changes',v_changes,
    'tasks',v_tasks,
    'projects',v_projects,
    'members',v_members,
    'access',jsonb_build_object(
      'management',v_management,
      'read_only',v_read_only,
      'can_submit_acceptance',not v_read_only and exists(
        select 1 from public.tasks t
         where public._execution_task_enterprise(t.id)=v_eid
           and public._execution_can_submit_task(v_eid,v_uid,t.id)
           and coalesce(t.accept_status,'pending')='accepted'
           and exists(select 1 from public.task_logs l where l.task_id=t.id)),
      'can_review_acceptance',v_can_accept,
      'can_manage_dependencies',v_can_dependencies,
      'can_create_handoff',v_can_handoff or exists(
        select 1 from public.tasks t
         where public._execution_task_enterprise(t.id)=v_eid
           and public._execution_can_handoff_task(v_eid,v_uid,t.id)),
      'can_manage_changes',v_can_changes),
    'generated_at',now());
end;
$fn$;

-- ---------------------------------------------------------- least privilege
revoke all on function public._execution_risk(text) from public, anon, authenticated;
revoke all on function public._execution_urgency(text) from public, anon, authenticated;
revoke all on function public._execution_change_requires_approval(numeric,integer,text,boolean,text)
  from public, anon, authenticated;
revoke all on function public._execution_role_key(uuid,uuid) from public, anon, authenticated;
revoke all on function public._execution_is_read_only_role(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_has_project_permission(uuid,uuid,uuid,text[])
  from public, anon, authenticated;
revoke all on function public._execution_can_submit_task(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_can_review_task(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_can_manage_task(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_can_handoff_task(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_can_manage_change(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_guard_task_log()
  from public, anon, authenticated;
revoke all on function public._execution_sync_change_from_decision()
  from public, anon, authenticated;
revoke all on function public._execution_denied(uuid,uuid,text,text,text,text,jsonb)
  from public, anon, authenticated;
revoke all on function public._execution_success(
  uuid,uuid,text,text,text,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public._execution_has_permission(uuid,uuid,text)
  from public, anon, authenticated;
revoke all on function public._execution_has_management(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_task_enterprise(uuid)
  from public, anon, authenticated;
revoke all on function public._execution_dependency_cycle(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public._execution_downstream(uuid,uuid,integer)
  from public, anon, authenticated;

revoke all on function public.get_execution_board(uuid)
  from public, anon, authenticated;
grant execute on function public.get_execution_board(uuid) to authenticated;

revoke all on function public.submit_task_acceptance(uuid,text,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.submit_task_acceptance(uuid,text,text,uuid,text)
  to authenticated;

revoke all on function public.review_task_acceptance(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.review_task_acceptance(uuid,text,text)
  to authenticated;

revoke all on function public.upsert_task_dependency(uuid,uuid,integer,boolean)
  from public, anon, authenticated;
grant execute on function public.upsert_task_dependency(uuid,uuid,integer,boolean)
  to authenticated;

revoke all on function public.delete_task_dependency(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.delete_task_dependency(uuid,uuid)
  to authenticated;

revoke all on function public.create_task_handoff(uuid,uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.create_task_handoff(uuid,uuid,text,text)
  to authenticated;

revoke all on function public.accept_task_handoff(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.accept_task_handoff(uuid,text,text)
  to authenticated;

revoke all on function public.create_change_request(uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.create_change_request(uuid,jsonb)
  to authenticated;

revoke all on function public.decide_change_request(uuid,text,text,text)
  from public, anon, authenticated;
grant execute on function public.decide_change_request(uuid,text,text,text)
  to authenticated;
$execution_phase3$;
end;
$execution_installer$;

-- ============================================================
-- Phase 2B: operations economics, skills, worklog dimensions,
-- and performance evidence.
--
-- Canonical source: mobile/sql/operations-economics-v1.sql
-- This guarded block applies after Phase 3 because performance
-- aggregation consumes task_acceptance. Re-running is safe.
-- ============================================================
do $operations_installer$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.projects') is null
     or to_regclass('public.worklogs') is null
     or to_regclass('public.enterprises') is null
     or to_regclass('public.enterprise_identity_audit') is null
     or to_regclass('public.decision_items') is null
     or to_regclass('public.task_acceptance') is null then
    raise notice 'Phase 2B skipped: run Phase 1, task extension, decision approval, and execution tracking migrations first.';
    return;
  end if;

  execute $operations_phase2b$
-- ============================================================
-- Project Recorder - Phase 2B operations economics
--
-- Deployment order:
--   unified-platform.sql
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
--   execution-tracking-v1.sql
--   operations-economics-v1.sql
--
-- This migration is additive and ASCII-only. Business tables stay
-- private. Clients use the SECURITY DEFINER RPCs at the end.
-- ============================================================

-- ------------------------------------------------------------ economics
create table if not exists public.project_economics (
  project_id uuid primary key references public.projects(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  contract_amount numeric(18,2) not null default 0 check (contract_amount >= 0),
  invoiced_amount numeric(18,2) not null default 0 check (invoiced_amount >= 0),
  collected_amount numeric(18,2) not null default 0 check (collected_amount >= 0),
  outsourced_committed numeric(18,2) not null default 0
    check (outsourced_committed >= 0),
  outsourced_paid numeric(18,2) not null default 0
    check (outsourced_paid >= 0),
  labor_cost numeric(18,2) not null default 0 check (labor_cost >= 0),
  estimated_completion_cost numeric(18,2) not null default 0
    check (estimated_completion_cost >= 0),
  other_cost numeric(18,2) not null default 0 check (other_cost >= 0),
  invoice_due_date date,
  payment_terms text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.project_economics
  add column if not exists invoice_due_date date,
  add column if not exists payment_terms text not null default '';

create index if not exists project_economics_enterprise_idx
  on public.project_economics(enterprise_id, updated_at desc);

-- ------------------------------------------------------------ skills
create table if not exists public.profile_skills (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  skill text not null,
  level integer not null default 1 check (level between 1 and 5),
  certified boolean not null default false,
  certification text not null default '',
  available_hours numeric(8,2) not null default 0
    check (available_hours >= 0),
  valid_until date,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (enterprise_id, profile_id, skill)
);

create index if not exists profile_skills_enterprise_skill_idx
  on public.profile_skills(enterprise_id, skill, valid_until);

-- Explicit demand makes the future capacity gap auditable instead of
-- inferring a skill requirement the existing task model does not store.
create table if not exists public.capacity_demands (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  skill text not null,
  required_hours numeric(10,2) not null check (required_hours > 0),
  needed_from date not null default current_date,
  needed_until date not null default (current_date + 28),
  project_id uuid references public.projects(id) on delete set null,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  note text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (needed_until >= needed_from)
);

create index if not exists capacity_demands_window_idx
  on public.capacity_demands(enterprise_id, needed_from, needed_until, skill);

-- ------------------------------------------------------------ performance
create table if not exists public.performance_evidence (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  period text not null,
  on_time_rate numeric(6,4) not null default 0
    check (on_time_rate between 0 and 1),
  first_pass_rate numeric(6,4) not null default 0
    check (first_pass_rate between 0 and 1),
  rework_rate numeric(6,4) not null default 0
    check (rework_rate between 0 and 1),
  collaboration_score numeric(6,2) not null default 0
    check (collaboration_score between 0 and 5),
  complexity_score numeric(6,2) not null default 0
    check (complexity_score between 0 and 5),
  business_contribution numeric(6,2) not null default 0
    check (business_contribution between 0 and 5),
  customer_evaluation jsonb not null default '{}'::jsonb
    check (jsonb_typeof(customer_evaluation)='object'),
  evidence jsonb not null default '[]'::jsonb
    check (jsonb_typeof(evidence) in ('array','object')),
  employee_statement text not null default '',
  status text not null default 'draft'
    check (status in ('draft','submitted','reviewed')),
  score numeric(5,1) not null default 0 check (score between 0 and 100),
  reviewer_note text not null default '',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (enterprise_id, profile_id, period)
);

alter table public.performance_evidence
  add column if not exists customer_evaluation jsonb not null default '{}'::jsonb
    check (jsonb_typeof(customer_evaluation)='object');

create index if not exists performance_evidence_enterprise_idx
  on public.performance_evidence(enterprise_id, period, profile_id);

-- ------------------------------------------------------------ timesheet dimensions
create table if not exists public.worklog_dimensions (
  worklog_id uuid primary key references public.worklogs(id) on delete cascade,
  billable boolean not null default true,
  overtime boolean not null default false,
  work_kind text not null default 'project'
    check (work_kind in ('project','presales','internal')),
  rework boolean not null default false,
  waiting boolean not null default false,
  travel boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Existing history receives the same defaults as new worklogs.
insert into public.worklog_dimensions(worklog_id)
select id from public.worklogs
on conflict (worklog_id) do nothing;

-- Unauthorized attempts are stored separately so a denied RPC can return
-- a payload after the audit row is committed. Business audit rows live in
-- enterprise_identity_audit and may roll back with the rejected operation.
create table if not exists public.operations_security_audit (
  id bigint generated always as identity primary key,
  enterprise_id uuid references public.enterprises(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  target_id text not null default '',
  reason text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists operations_security_audit_enterprise_idx
  on public.operations_security_audit(enterprise_id, created_at desc);

-- ------------------------------------------------------------ RLS / least privilege
alter table public.project_economics enable row level security;
alter table public.profile_skills enable row level security;
alter table public.capacity_demands enable row level security;
alter table public.performance_evidence enable row level security;
alter table public.worklog_dimensions enable row level security;
alter table public.operations_security_audit enable row level security;

revoke all on table public.project_economics from public;
revoke all on table public.project_economics from anon;
revoke all on table public.project_economics from authenticated;
revoke all on table public.profile_skills from public;
revoke all on table public.profile_skills from anon;
revoke all on table public.profile_skills from authenticated;
revoke all on table public.capacity_demands from public;
revoke all on table public.capacity_demands from anon;
revoke all on table public.capacity_demands from authenticated;
revoke all on table public.performance_evidence from public;
revoke all on table public.performance_evidence from anon;
revoke all on table public.performance_evidence from authenticated;
revoke all on table public.worklog_dimensions from public;
revoke all on table public.worklog_dimensions from anon;
revoke all on table public.worklog_dimensions from authenticated;
revoke all on table public.operations_security_audit from public;
revoke all on table public.operations_security_audit from anon;
revoke all on table public.operations_security_audit from authenticated;

-- ------------------------------------------------------------ helpers
create or replace function public._operations_number(
  p_data jsonb,
  p_key text,
  p_default numeric default 0
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select greatest(
    coalesce(nullif(btrim(coalesce(p_data->>p_key,'')),'')::numeric,p_default),
    0
  );
$fn$;

create or replace function public._operations_assert_nonnegative(
  p_data jsonb,
  p_keys text[]
) returns void
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_key text;
begin
  foreach v_key in array p_keys loop
    if p_data ? v_key
       and btrim(coalesce(p_data->>v_key,'')) <> ''
       and (p_data->>v_key)::numeric < 0 then
      raise exception 'negative value not allowed: %', v_key;
    end if;
  end loop;
end;
$fn$;

create or replace function public._operations_is_owner(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(
    select 1 from public.enterprises e
     where e.id=p_eid and e.owner_profile_id=p_uid
  );
$fn$;

create or replace function public._operations_has_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_permissions jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  v_permissions:=public._identity_role_permissions(p_eid,p_uid);
  return coalesce(v_permissions ?| p_permissions,false);
end;
$fn$;

create or replace function public._operations_has_company_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if (v_grant->>'permission_key')=any(p_permissions)
       and (v_grant->>'scope')='company' then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_has_scoped_permission(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[],
  p_scopes text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if (v_grant->>'permission_key')=any(p_permissions)
       and coalesce(v_grant->>'scope','self')=any(p_scopes) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_can_access_project(
  p_eid uuid,
  p_uid uuid,
  p_project uuid,
  p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_project_ids jsonb;
  v_scope text;
  v_actor public.profiles%rowtype;
  v_actor_department text;
begin
  if p_uid is null or p_project is null
     or not public._identity_is_member(p_eid,p_uid) then
    return false;
  end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  select * into v_actor from public.profiles where id=p_uid;
  select em.department into v_actor_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_uid and em.status='active';
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_scope:=coalesce(v_grant->>'scope','self');
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    if v_scope='company' then return true; end if;
    v_project_ids:=case when jsonb_typeof(v_conditions->'project_ids')='array'
      then v_conditions->'project_ids' else '[]'::jsonb end;
    if v_project_ids ? p_project::text
       or coalesce(v_conditions->>'project_id','')=p_project::text then
      return true;
    end if;
    if exists(
      select 1 from public.projects p
       where p.id=p_project
         and lower(btrim(coalesce(p.owner,''))) in (
           lower(btrim(coalesce(v_actor.name,''))),
           lower(btrim(coalesce(v_actor.code,'')))
         )
    ) then
      return true;
    end if;
    if v_scope='self' and exists(
      select 1 from public.tasks t
       where t.project_id=p_project and t.employee_id=p_uid
      union all
      select 1 from public.worklogs w
       where w.project_id=p_project and w.employee_id=p_uid
    ) then
      return true;
    end if;
    if v_scope in ('team','department') and exists(
      select 1
        from public.tasks t
        join public.enterprise_members em
          on em.enterprise_id=p_eid and em.profile_id=t.employee_id
         and em.status='active'
       where t.project_id=p_project
         and em.department=coalesce(v_actor_department,'')
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_can_access_profile(
  p_eid uuid,
  p_uid uuid,
  p_profile uuid,
  p_permissions text[],
  p_allow_self boolean default true
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_profile_ids jsonb;
  v_scope text;
  v_actor_department text;
  v_target_department text;
begin
  if p_uid is null or p_profile is null
     or not public._identity_is_member(p_eid,p_profile) then
    return false;
  end if;
  if p_allow_self and p_uid=p_profile then return true; end if;
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  select em.department into v_actor_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_uid and em.status='active';
  select em.department into v_target_department
    from public.enterprise_members em
   where em.enterprise_id=p_eid and em.profile_id=p_profile and em.status='active';
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_scope:=coalesce(v_grant->>'scope','self');
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    if v_scope='company' then return true; end if;
    v_profile_ids:=case when jsonb_typeof(v_conditions->'profile_ids')='array'
      then v_conditions->'profile_ids' else '[]'::jsonb end;
    if v_profile_ids ? p_profile::text
       or coalesce(v_conditions->>'profile_id','')=p_profile::text then
      return true;
    end if;
    if v_scope in ('team','department')
       and coalesce(v_conditions->>'department','')=coalesce(v_target_department,'')
       and v_target_department is not null then
      return true;
    end if;
    if v_scope in ('team','department')
       and not (v_conditions ? 'department')
       and v_actor_department is not null
       and v_actor_department=v_target_department then
      return true;
    end if;
    if v_scope='self' and p_uid=p_profile then return true; end if;
    if v_scope='project' and exists(
      select 1 from public.tasks t
       where t.employee_id=p_profile
         and public._operations_can_access_project(
           p_eid,p_uid,t.project_id,
           array['projects.manage','projects.view_all']::text[]
         )
    ) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._operations_amount_allowed(
  p_eid uuid,
  p_uid uuid,
  p_permissions text[],
  p_amount numeric
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_grant jsonb;
  v_conditions jsonb;
  v_limit numeric;
  v_found boolean:=false;
begin
  if public._operations_is_owner(p_eid,p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permission_grants(p_eid,p_uid)
    )
  loop
    if not ((v_grant->>'permission_key')=any(p_permissions)) then
      continue;
    end if;
    v_found:=true;
    v_conditions:=coalesce(v_grant->'conditions','{}'::jsonb);
    v_limit:=coalesce(
      nullif(v_conditions->>'amount_limit','')::numeric,
      nullif(v_conditions->>'max_amount','')::numeric
    );
    if v_limit is null or coalesce(p_amount,0)<=v_limit then
      return true;
    end if;
  end loop;
  return v_found and false;
end;
$fn$;

create or replace function public._operations_has_management(
  p_eid uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._operations_has_permission(
    p_eid,p_uid,array[
      'company.manage','projects.view_all','projects.manage',
      'people.view_all','people.manage','worklogs.approve',
      'tasks.assign','tasks.grade','finance.view','finance.manage',
      'reports.view','audit.read','rewards.manage','leave.approve',
      'identity.manage_templates','identity.manage_shares',
      'governance.manage','governance.vote'
    ]::text[]
  );
$fn$;

create or replace function public._operations_project_enterprise(
  p_project uuid
) returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select e.id
    from public.projects p
    join public.enterprises e on e.owner_profile_id=p.boss_id
   where p.id=p_project;
$fn$;

create or replace function public._operations_performance_score(
  p_on_time numeric,
  p_first_pass numeric,
  p_rework numeric,
  p_collaboration numeric,
  p_complexity numeric,
  p_business_contribution numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select round(least(greatest(
    least(greatest(coalesce(p_on_time,0),0),1)*30
    +least(greatest(coalesce(p_first_pass,0),0),1)*25
    +(1-least(greatest(coalesce(p_rework,0),0),1))*15
    +least(greatest(coalesce(p_collaboration,0),0),5)/5*10
    +least(greatest(coalesce(p_complexity,0),0),5)/5*12
    +least(greatest(coalesce(p_business_contribution,0),0),5)/5*8,
    0),100),1);
$fn$;

create or replace function public._operations_performance_score(
  p_on_time numeric,
  p_first_pass numeric,
  p_rework numeric,
  p_collaboration numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._operations_performance_score(
    p_on_time,p_first_pass,p_rework,p_collaboration,0,0
  );
$fn$;

create or replace function public._operations_evidence_items(
  p_evidence jsonb
) returns jsonb
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select case
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='array'
      then coalesce(p_evidence,'[]'::jsonb)
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='object'
      and jsonb_typeof(p_evidence->'items')='array'
      then p_evidence->'items'
    when jsonb_typeof(coalesce(p_evidence,'[]'::jsonb))='object'
      then jsonb_build_array(p_evidence)
    else '[]'::jsonb end;
$fn$;

create or replace function public._operations_validate_evidence(
  p_eid uuid,
  p_profile uuid,
  p_evidence jsonb
) returns void
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_item jsonb;
  v_type text;
  v_id_text text;
  v_id uuid;
begin
  if jsonb_typeof(p_evidence) not in ('array','object') then
    raise exception 'evidence must be an array or object';
  end if;
  for v_item in
    select value from jsonb_array_elements(
      public._operations_evidence_items(p_evidence)
    )
  loop
    if jsonb_typeof(v_item)<>'object' then
      raise exception 'evidence entries must be objects';
    end if;
    v_type:=lower(btrim(coalesce(v_item->>'type',v_item->>'source_type','')));
    v_id_text:=coalesce(nullif(v_item->>'id',''),nullif(v_item->>'source_id',''));
    if v_type not in ('task','worklog','approval') then
      raise exception 'unsupported evidence type: %', v_type;
    end if;
    if v_id_text is null then
      raise exception 'evidence source id required';
    end if;
    v_id:=v_id_text::uuid;
    if v_type='task' and not exists(
      select 1 from public.tasks t
       join public.enterprises e on e.owner_profile_id=t.boss_id
       where t.id=v_id and t.employee_id=p_profile and e.id=p_eid
    ) then
      raise exception 'evidence task must belong to the employee';
    end if;
    if v_type='worklog' and not exists(
      select 1 from public.worklogs w
       join public.enterprises e on e.owner_profile_id=w.boss_id
       where w.id=v_id and w.employee_id=p_profile and e.id=p_eid
    ) then
      raise exception 'evidence worklog must belong to the employee';
    end if;
    if v_type='approval' and not exists(
      select 1 from public.approval_requests a
       where a.id=v_id and a.requester_profile_id=p_profile
         and a.enterprise_id=p_eid
    ) then
      raise exception 'evidence approval must belong to the employee';
    end if;
  end loop;
end;
$fn$;

create or replace function public._operations_evidence_details(
  p_eid uuid,
  p_evidence jsonb
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_item jsonb;
  v_type text;
  v_id_text text;
  v_id uuid;
  v_label text;
  v_status text;
  v_result jsonb:='[]'::jsonb;
begin
  for v_item in
    select value from jsonb_array_elements(
      public._operations_evidence_items(p_evidence)
    )
  loop
    v_type:=lower(coalesce(v_item->>'type',v_item->>'source_type',''));
    v_id_text:=coalesce(nullif(v_item->>'id',''),nullif(v_item->>'source_id',''));
    v_label:='';v_status:='';
    if v_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then
      v_id:=v_id_text::uuid;
      if v_type='task' then
        select t.title,coalesce(t.accept_status,'') into v_label,v_status
          from public.tasks t where t.id=v_id;
      elsif v_type='worklog' then
        select w.content,coalesce(w.approval_status,'') into v_label,v_status
          from public.worklogs w where w.id=v_id;
      elsif v_type='approval' then
        select a.title,a.status into v_label,v_status
          from public.approval_requests a where a.id=v_id;
      end if;
    end if;
    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'type',v_type,'source_id',v_id_text,'id',v_id_text,
      'label',coalesce(nullif(v_label,''),'Source not found'),
      'status',v_status,'href',v_type||':'||coalesce(v_id_text,'')
    ));
  end loop;
  return v_result;
end;
$fn$;

create or replace function public._operations_denied(
  p_eid uuid,
  p_uid uuid,
  p_operation text,
  p_target text,
  p_reason text,
  p_details jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.operations_security_audit(
    enterprise_id,actor_profile_id,operation,target_id,reason,details
  ) values(
    p_eid,p_uid,btrim(coalesce(p_operation,'')),coalesce(p_target,''),
    btrim(coalesce(p_reason,'permission denied')),coalesce(p_details,'{}'::jsonb)
  );
  return jsonb_build_object(
    'ok',false,'code','permission_denied',
    'error',btrim(coalesce(p_reason,'permission denied'))
  );
end;
$fn$;

create or replace function public._operations_validate_project_economics()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  if not exists(
    select 1
      from public.projects p
      join public.enterprises e on e.owner_profile_id=p.boss_id
     where p.id=NEW.project_id and e.id=NEW.enterprise_id
  ) then
    raise exception 'project and enterprise do not match';
  end if;
  return NEW;
end;
$fn$;

drop trigger if exists trg_operations_project_economics_validate
  on public.project_economics;
create trigger trg_operations_project_economics_validate
before insert or update on public.project_economics
for each row execute function public._operations_validate_project_economics();

create or replace function public._operations_worklog_defaults()
returns trigger
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_eid uuid;
begin
  insert into public.worklog_dimensions(worklog_id)
  values(NEW.id)
  on conflict (worklog_id) do nothing;

  v_eid:=public._identity_bootstrap(NEW.boss_id);
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,auth.uid(),'operations.worklog.defaults',NEW.employee_id,
    jsonb_build_object('worklog_id',NEW.id)
  );
  return NEW;
end;
$fn$;

drop trigger if exists trg_operations_worklog_defaults on public.worklogs;
create trigger trg_operations_worklog_defaults
after insert on public.worklogs
for each row execute function public._operations_worklog_defaults();

revoke all on function public._operations_number(jsonb,text,numeric) from public;
revoke all on function public._operations_number(jsonb,text,numeric) from anon;
revoke all on function public._operations_number(jsonb,text,numeric) from authenticated;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from public;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from anon;
revoke all on function public._operations_assert_nonnegative(jsonb,text[]) from authenticated;
revoke all on function public._operations_is_owner(uuid,uuid) from public;
revoke all on function public._operations_is_owner(uuid,uuid) from anon;
revoke all on function public._operations_is_owner(uuid,uuid) from authenticated;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from public;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from anon;
revoke all on function public._operations_has_permission(uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from public;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from anon;
revoke all on function public._operations_has_company_permission(uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from public;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from anon;
revoke all on function public._operations_has_scoped_permission(uuid,uuid,text[],text[]) from authenticated;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from public;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from anon;
revoke all on function public._operations_can_access_project(uuid,uuid,uuid,text[]) from authenticated;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from public;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from anon;
revoke all on function public._operations_can_access_profile(uuid,uuid,uuid,text[],boolean) from authenticated;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from public;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from anon;
revoke all on function public._operations_amount_allowed(uuid,uuid,text[],numeric) from authenticated;
revoke all on function public._operations_has_management(uuid,uuid) from public;
revoke all on function public._operations_has_management(uuid,uuid) from anon;
revoke all on function public._operations_has_management(uuid,uuid) from authenticated;
revoke all on function public._operations_project_enterprise(uuid) from public;
revoke all on function public._operations_project_enterprise(uuid) from anon;
revoke all on function public._operations_project_enterprise(uuid) from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric,numeric,numeric) from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric) from authenticated;
revoke all on function public._operations_evidence_items(jsonb) from public;
revoke all on function public._operations_evidence_items(jsonb) from anon;
revoke all on function public._operations_evidence_items(jsonb) from authenticated;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from public;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from anon;
revoke all on function public._operations_validate_evidence(uuid,uuid,jsonb) from authenticated;
revoke all on function public._operations_evidence_details(uuid,jsonb) from public;
revoke all on function public._operations_evidence_details(uuid,jsonb) from anon;
revoke all on function public._operations_evidence_details(uuid,jsonb) from authenticated;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from public;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from anon;
revoke all on function public._operations_denied(uuid,uuid,text,text,text,jsonb) from authenticated;
revoke all on function public._operations_validate_project_economics() from public;
revoke all on function public._operations_validate_project_economics() from anon;
revoke all on function public._operations_validate_project_economics() from authenticated;
revoke all on function public._operations_worklog_defaults() from public;
revoke all on function public._operations_worklog_defaults() from anon;
revoke all on function public._operations_worklog_defaults() from authenticated;
-- ------------------------------------------------------------ project economics RPC
create or replace function public.upsert_project_economics(
  p_project uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_project_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_row public.project_economics%rowtype;
  v_projected numeric;
  v_contract numeric;
  v_amount numeric;
  v_amount_key text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  v_project_eid:=public._operations_project_enterprise(p_project);
  if v_project_eid is null then raise exception 'project not found'; end if;
  if v_project_eid<>v_eid then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'cross-enterprise project access denied',
      jsonb_build_object(
        'project_id',p_project,'project_enterprise_id',v_project_eid,
        'actor_enterprise_id',v_eid
      )
    );
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'finance or project management permission required',
      jsonb_build_object('project_id',p_project)
    );
  end if;
  if not public._operations_can_access_project(
    v_eid,v_uid,p_project,
    array['finance.manage','projects.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'project scope does not allow this operation',
      jsonb_build_object('project_id',p_project)
    );
  end if;

  v_contract:=case when v_data ? 'contract_amount'
    then public._operations_number(v_data,'contract_amount')
    else coalesce((
      select pe.contract_amount from public.project_economics pe
       where pe.project_id=p_project
    ),0) end;
  if not public._operations_amount_allowed(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[],v_contract
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_project_economics',p_project::text,
      'project amount exceeds permission condition',
      jsonb_build_object('project_id',p_project,'contract_amount',v_contract)
    );
  end if;

  perform public._operations_assert_nonnegative(
    v_data,
    array[
      'contract_amount','invoiced_amount','collected_amount',
      'outsourced_committed','outsourced_paid','labor_cost',
      'estimated_completion_cost','other_cost'
    ]::text[]
  );

  foreach v_amount_key in array array[
    'contract_amount','invoiced_amount','collected_amount',
    'outsourced_committed','outsourced_paid','labor_cost',
    'estimated_completion_cost','other_cost'
  ]::text[]
  loop
    if v_data ? v_amount_key then
      v_amount:=public._operations_number(v_data,v_amount_key);
      if not public._operations_amount_allowed(
        v_eid,v_uid,
        array['finance.manage','projects.manage']::text[],v_amount
      ) then
        return public._operations_denied(
          v_eid,v_uid,'upsert_project_economics',p_project::text,
          'monetary field exceeds permission condition',
          jsonb_build_object(
            'project_id',p_project,'field',v_amount_key,
            'amount',v_amount
          )
        );
      end if;
    end if;
  end loop;

  insert into public.project_economics as pe(
    project_id,enterprise_id,contract_amount,invoiced_amount,collected_amount,
    outsourced_committed,outsourced_paid,labor_cost,
    estimated_completion_cost,other_cost,invoice_due_date,payment_terms,
    updated_by,updated_at
  ) values(
    p_project,v_eid,
    public._operations_number(v_data,'contract_amount'),
    public._operations_number(v_data,'invoiced_amount'),
    public._operations_number(v_data,'collected_amount'),
    public._operations_number(v_data,'outsourced_committed'),
    public._operations_number(v_data,'outsourced_paid'),
    public._operations_number(v_data,'labor_cost'),
    public._operations_number(v_data,'estimated_completion_cost'),
    public._operations_number(v_data,'other_cost'),
    nullif(v_data->>'invoice_due_date','')::date,
    coalesce(v_data->>'payment_terms',''),
    v_uid,now()
  )
  on conflict (project_id) do update set
    contract_amount=case when v_data ? 'contract_amount'
      then public._operations_number(v_data,'contract_amount')
      else pe.contract_amount end,
    invoiced_amount=case when v_data ? 'invoiced_amount'
      then public._operations_number(v_data,'invoiced_amount')
      else pe.invoiced_amount end,
    collected_amount=case when v_data ? 'collected_amount'
      then public._operations_number(v_data,'collected_amount')
      else pe.collected_amount end,
    outsourced_committed=case when v_data ? 'outsourced_committed'
      then public._operations_number(v_data,'outsourced_committed')
      else pe.outsourced_committed end,
    outsourced_paid=case when v_data ? 'outsourced_paid'
      then public._operations_number(v_data,'outsourced_paid')
      else pe.outsourced_paid end,
    labor_cost=case when v_data ? 'labor_cost'
      then public._operations_number(v_data,'labor_cost')
      else pe.labor_cost end,
    estimated_completion_cost=case when v_data ? 'estimated_completion_cost'
      then public._operations_number(v_data,'estimated_completion_cost')
      else pe.estimated_completion_cost end,
    other_cost=case when v_data ? 'other_cost'
      then public._operations_number(v_data,'other_cost')
      else pe.other_cost end,
    invoice_due_date=case when v_data ? 'invoice_due_date'
      then nullif(v_data->>'invoice_due_date','')::date
      else pe.invoice_due_date end,
    payment_terms=case when v_data ? 'payment_terms'
      then coalesce(v_data->>'payment_terms','')
      else pe.payment_terms end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  v_projected:=case when v_row.estimated_completion_cost>0
    then v_row.estimated_completion_cost
    else v_row.labor_cost+v_row.outsourced_committed+v_row.other_cost end;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.economics.updated',null,
    jsonb_build_object(
      'project_id',p_project,'contract_amount',v_row.contract_amount,
      'invoiced_amount',v_row.invoiced_amount,
      'collected_amount',v_row.collected_amount,
      'outsourced_committed',v_row.outsourced_committed,
      'outsourced_paid',v_row.outsourced_paid,
      'other_cost',v_row.other_cost,
      'labor_cost',v_row.labor_cost,
      'estimated_completion_cost',v_row.estimated_completion_cost,
      'invoice_due_date',v_row.invoice_due_date,
      'payment_terms',v_row.payment_terms
    )
  );

  return to_jsonb(v_row)||jsonb_build_object(
    'projected_completion_cost',v_projected,
    'projected_margin',v_row.contract_amount-v_projected,
    'projected_margin_percent',case when v_row.contract_amount>0
      then round((v_row.contract_amount-v_projected)/v_row.contract_amount*100,2)
      else 0 end,
    'collection_gap',greatest(v_row.contract_amount-v_row.collected_amount,0),
    'unpaid_invoice',greatest(v_row.invoiced_amount-v_row.collected_amount,0),
    'committed_amount',v_row.outsourced_committed
  );
end;
$fn$;

-- ------------------------------------------------------------ skill RPC
create or replace function public.upsert_profile_skill(
  p_profile uuid,
  p_skill text,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_skill text:=btrim(coalesce(p_skill,''));
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_level integer:=coalesce((v_data->>'level')::integer,1);
  v_available numeric;
  v_valid_until date;
  v_row public.profile_skills%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'profile must be an active enterprise member';
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['people.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_profile_skill',p_profile::text,
      'people.manage permission required',
      jsonb_build_object('profile_id',p_profile,'skill',v_skill)
    );
  end if;
  if not public._operations_can_access_profile(
    v_eid,v_uid,p_profile,array['people.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_profile_skill',p_profile::text,
      'people scope does not allow this profile',
      jsonb_build_object('profile_id',p_profile,'skill',v_skill)
    );
  end if;
  if v_skill='' then raise exception 'skill required'; end if;
  if v_level<1 or v_level>5 then raise exception 'level must be between 1 and 5'; end if;
  v_available:=public._operations_number(v_data,'available_hours');
  v_valid_until:=nullif(v_data->>'valid_until','')::date;

  insert into public.profile_skills as ps(
    enterprise_id,profile_id,skill,level,certified,certification,
    available_hours,valid_until,updated_by,updated_at
  ) values(
    v_eid,p_profile,v_skill,v_level,
    coalesce((v_data->>'certified')::boolean,false),
    coalesce(v_data->>'certification',''),v_available,v_valid_until,
    v_uid,now()
  )
  on conflict (enterprise_id,profile_id,skill) do update set
    level=case when v_data ? 'level' then v_level
      else ps.level end,
    certified=case when v_data ? 'certified'
      then coalesce((v_data->>'certified')::boolean,false)
      else ps.certified end,
    certification=case when v_data ? 'certification'
      then coalesce(v_data->>'certification','')
      else ps.certification end,
    available_hours=case when v_data ? 'available_hours' then v_available
      else ps.available_hours end,
    valid_until=case when v_data ? 'valid_until' then v_valid_until
      else ps.valid_until end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.skill.updated',p_profile,
    jsonb_build_object(
      'profile_id',p_profile,'skill',v_row.skill,'level',v_row.level,
      'certified',v_row.certified,'available_hours',v_row.available_hours,
      'valid_until',v_row.valid_until
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

-- ------------------------------------------------------------ capacity demand RPC
create or replace function public.upsert_capacity_demand(
  p_demand uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_existing public.capacity_demands%rowtype;
  v_id uuid:=p_demand;
  v_skill text:=nullif(btrim(coalesce(v_data->>'skill','')),'');
  v_required numeric:=case when v_data ? 'required_hours'
    then public._operations_number(v_data,'required_hours') else null end;
  v_from date:=case when v_data ? 'needed_from'
    then nullif(v_data->>'needed_from','')::date else null end;
  v_until date:=case when v_data ? 'needed_until'
    then nullif(v_data->>'needed_until','')::date else null end;
  v_project uuid:=case when v_data ? 'project_id'
    then nullif(v_data->>'project_id','')::uuid else null end;
  v_owner uuid:=case when v_data ? 'owner_profile_id'
    then nullif(v_data->>'owner_profile_id','')::uuid else null end;
  v_scope_project uuid;
  v_row public.capacity_demands%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_permission(
    v_eid,v_uid,array['projects.manage','people.manage','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
      'project or people management permission required',
      jsonb_build_object('demand_id',p_demand)
    );
  end if;

  if v_id is not null then
    select * into v_existing from public.capacity_demands
     where id=v_id and enterprise_id=v_eid for update;
    if not found then raise exception 'capacity demand not found'; end if;
    v_scope_project:=case when v_data ? 'project_id'
      then v_project else v_existing.project_id end;
  else
    v_scope_project:=v_project;
  end if;
  if v_scope_project is not null then
    if not public._operations_can_access_project(
      v_eid,v_uid,v_scope_project,
      array['projects.manage','people.manage','company.manage']::text[]
    ) then
      return public._operations_denied(
        v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
        'project scope does not allow this capacity demand',
        jsonb_build_object('demand_id',p_demand,'project_id',v_scope_project)
      );
    end if;
  elsif not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_capacity_demand',coalesce(p_demand::text,''),
      'company-wide people management permission required for unassigned demand',
      jsonb_build_object('demand_id',p_demand)
    );
  end if;

  if v_id is not null then
    v_skill:=coalesce(v_skill,v_existing.skill);
    v_required:=coalesce(v_required,v_existing.required_hours);
    v_from:=coalesce(v_from,v_existing.needed_from);
    v_until:=coalesce(v_until,v_existing.needed_until);
    v_project:=case when v_data ? 'project_id'
      then v_project else v_existing.project_id end;
    v_owner:=case when v_data ? 'owner_profile_id'
      then v_owner else v_existing.owner_profile_id end;
  else
    v_from:=coalesce(v_from,current_date);
    v_until:=coalesce(v_until,current_date+28);
  end if;

  if v_skill is null or v_skill='' then raise exception 'skill required'; end if;
  if v_required is null or v_required<=0 then
    raise exception 'required_hours must be positive';
  end if;
  if v_until<v_from then raise exception 'needed_until must not precede needed_from'; end if;
  if v_project is not null and public._operations_project_enterprise(v_project)<>v_eid then
    raise exception 'project not in enterprise';
  end if;
  if v_owner is not null and not public._identity_is_member(v_eid,v_owner) then
    raise exception 'owner must be an active enterprise member';
  end if;

  if v_id is null then
    insert into public.capacity_demands(
      enterprise_id,skill,required_hours,needed_from,needed_until,
      project_id,owner_profile_id,note,created_by,updated_by
    ) values(
      v_eid,v_skill,v_required,v_from,v_until,v_project,v_owner,
      coalesce(v_data->>'note',''),v_uid,v_uid
    ) returning * into v_row;
  else
    update public.capacity_demands set
      skill=case when v_data ? 'skill' then v_skill else skill end,
      required_hours=case when v_data ? 'required_hours' then v_required
        else required_hours end,
      needed_from=case when v_data ? 'needed_from' then v_from
        else needed_from end,
      needed_until=case when v_data ? 'needed_until' then v_until
        else needed_until end,
      project_id=case when v_data ? 'project_id' then v_project
        else project_id end,
      owner_profile_id=case when v_data ? 'owner_profile_id' then v_owner
        else owner_profile_id end,
      note=case when v_data ? 'note' then coalesce(v_data->>'note','')
        else note end,
      updated_by=v_uid,updated_at=now()
    where id=v_id and enterprise_id=v_eid
    returning * into v_row;
    if not found then raise exception 'capacity demand not found'; end if;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.capacity.updated',v_row.owner_profile_id,
    jsonb_build_object(
      'demand_id',v_row.id,'skill',v_row.skill,
      'required_hours',v_row.required_hours,'project_id',v_row.project_id,
      'needed_from',v_row.needed_from,'needed_until',v_row.needed_until
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

-- ------------------------------------------------------------ worklog dimensions RPC
create or replace function public.upsert_worklog_dimensions(
  p_worklog uuid,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_worklog public.worklogs%rowtype;
  v_eid uuid;
  v_kind text:=coalesce(v_data->>'work_kind','project');
  v_row public.worklog_dimensions%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_worklog from public.worklogs where id=p_worklog for update;
  if not found then raise exception 'worklog not found'; end if;
  v_eid:=public._identity_bootstrap(v_worklog.boss_id);
  if v_uid<>v_worklog.employee_id and not public._operations_can_access_profile(
    v_eid,v_uid,v_worklog.employee_id,
    array['worklogs.approve','people.manage','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_worklog_dimensions',p_worklog::text,
      'worklog permission required',
      jsonb_build_object('worklog_id',p_worklog,
                         'employee_id',v_worklog.employee_id)
    );
  end if;
  if v_kind not in ('project','presales','internal') then
    raise exception 'invalid work_kind';
  end if;

  insert into public.worklog_dimensions as wd(
    worklog_id,billable,overtime,work_kind,rework,waiting,travel,
    updated_by,updated_at
  ) values(
    p_worklog,
    coalesce((v_data->>'billable')::boolean,true),
    coalesce((v_data->>'overtime')::boolean,false),
    v_kind,
    coalesce((v_data->>'rework')::boolean,false),
    coalesce((v_data->>'waiting')::boolean,false),
    coalesce((v_data->>'travel')::boolean,false),
    v_uid,now()
  )
  on conflict (worklog_id) do update set
    billable=case when v_data ? 'billable'
      then coalesce((v_data->>'billable')::boolean,true)
      else wd.billable end,
    overtime=case when v_data ? 'overtime'
      then coalesce((v_data->>'overtime')::boolean,false)
      else wd.overtime end,
    work_kind=case when v_data ? 'work_kind'
      then v_kind else wd.work_kind end,
    rework=case when v_data ? 'rework'
      then coalesce((v_data->>'rework')::boolean,false)
      else wd.rework end,
    waiting=case when v_data ? 'waiting'
      then coalesce((v_data->>'waiting')::boolean,false)
      else wd.waiting end,
    travel=case when v_data ? 'travel'
      then coalesce((v_data->>'travel')::boolean,false)
      else wd.travel end,
    updated_by=v_uid,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.worklog.dimensions.updated',v_worklog.employee_id,
    jsonb_build_object(
      'worklog_id',p_worklog,'billable',v_row.billable,
      'overtime',v_row.overtime,'work_kind',v_row.work_kind,
      'rework',v_row.rework,'waiting',v_row.waiting,'travel',v_row.travel
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.get_worklog_dimensions(
  p_worklog uuid
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_worklog public.worklogs%rowtype;
  v_eid uuid;
  v_row public.worklog_dimensions%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_worklog from public.worklogs where id=p_worklog;
  if not found then raise exception 'worklog not found'; end if;
  v_eid:=public._identity_bootstrap(v_worklog.boss_id);
  if v_uid<>v_worklog.employee_id and not public._operations_can_access_profile(
    v_eid,v_uid,v_worklog.employee_id,
    array['worklogs.approve','people.manage','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'get_worklog_dimensions',p_worklog::text,
      'worklog permission required',
      jsonb_build_object('worklog_id',p_worklog)
    );
  end if;
  select * into v_row from public.worklog_dimensions where worklog_id=p_worklog;
  if not found then
    return jsonb_build_object(
      'worklog_id',p_worklog,'billable',true,'overtime',false,
      'work_kind','project','rework',false,'waiting',false,'travel',false
    );
  end if;
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.worklog_dimensions(
  p_worklog uuid,
  p_data jsonb
) returns jsonb
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  select public.upsert_worklog_dimensions(p_worklog,p_data);
$fn$;
-- ------------------------------------------------------------ performance evidence RPCs
create or replace function public.upsert_performance_evidence(
  p_profile uuid,
  p_period text,
  p_data jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_period text:=btrim(coalesce(p_period,''));
  v_on_time numeric:=coalesce((v_data->>'on_time_rate')::numeric,0);
  v_first_pass numeric:=coalesce((v_data->>'first_pass_rate')::numeric,0);
  v_rework numeric:=coalesce((v_data->>'rework_rate')::numeric,0);
  v_collaboration numeric:=coalesce((v_data->>'collaboration_score')::numeric,0);
  v_complexity numeric:=coalesce((v_data->>'complexity_score')::numeric,0);
  v_contribution numeric:=coalesce((v_data->>'business_contribution')::numeric,0);
  v_customer jsonb:=coalesce(v_data->'customer_evaluation','{}'::jsonb);
  v_customer_score numeric;
  v_evidence jsonb:=coalesce(v_data->'evidence','[]'::jsonb);
  v_row public.performance_evidence%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,p_profile) then
    raise exception 'profile must be an active enterprise member';
  end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','tasks.grade','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_performance_evidence',p_profile::text,
      'performance review permission required',
      jsonb_build_object('profile_id',p_profile,'period',v_period)
    );
  end if;
  if not public._operations_can_access_profile(
    v_eid,v_uid,p_profile,
    array['people.manage','tasks.grade','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_eid,v_uid,'upsert_performance_evidence',p_profile::text,
      'people scope does not allow this performance evidence',
      jsonb_build_object('profile_id',p_profile,'period',v_period)
    );
  end if;
  if v_period='' then raise exception 'period required'; end if;
  if v_on_time<0 or v_on_time>1 or v_first_pass<0 or v_first_pass>1
     or v_rework<0 or v_rework>1 then
    raise exception 'performance rates must be between 0 and 1';
  end if;
  if v_collaboration<0 or v_collaboration>5
     or v_complexity<0 or v_complexity>5
     or v_contribution<0 or v_contribution>5 then
    raise exception 'performance scores must be between 0 and 5';
  end if;
  if jsonb_typeof(v_customer)<>'object' then
    raise exception 'customer evaluation must be an object';
  end if;
  if v_customer ? 'score' then
    v_customer_score:=(v_customer->>'score')::numeric;
    if v_customer_score<0 or v_customer_score>5 then
      raise exception 'customer evaluation score must be between 0 and 5';
    end if;
  end if;
  perform public._operations_validate_evidence(v_eid,p_profile,v_evidence);
  if exists(
    select 1 from public.performance_evidence
     where enterprise_id=v_eid and profile_id=p_profile
       and period=v_period and status='reviewed'
  ) then
    raise exception 'reviewed performance evidence is immutable';
  end if;

  insert into public.performance_evidence as pe(
    enterprise_id,profile_id,period,on_time_rate,first_pass_rate,
    rework_rate,collaboration_score,complexity_score,business_contribution,
    customer_evaluation,evidence,status,score,created_at,updated_at
  ) values(
    v_eid,p_profile,v_period,v_on_time,v_first_pass,v_rework,
    v_collaboration,v_complexity,v_contribution,v_customer,v_evidence,
    'draft',0,now(),now()
  )
  on conflict (enterprise_id,profile_id,period) do update set
    on_time_rate=excluded.on_time_rate,
    first_pass_rate=excluded.first_pass_rate,
    rework_rate=excluded.rework_rate,
    collaboration_score=excluded.collaboration_score,
    complexity_score=excluded.complexity_score,
    business_contribution=excluded.business_contribution,
    customer_evaluation=excluded.customer_evaluation,
    evidence=excluded.evidence,
    status=case when pe.status='submitted'
      then 'submitted' else 'draft' end,
    score=0,updated_at=now()
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_eid,v_uid,'operations.performance.updated',p_profile,
    jsonb_build_object(
      'performance_id',v_row.id,'period',v_period,
      'status',v_row.status,'evidence',v_row.evidence,
      'customer_evaluation',v_row.customer_evaluation,
      'complexity_score',v_row.complexity_score,
      'business_contribution',v_row.business_contribution
    )
  );
  return to_jsonb(v_row);
end;
$fn$;

create or replace function public.get_my_performance_evidence()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  return jsonb_build_object(
    'enterprise_id',v_eid,
    'items',(
      select coalesce(jsonb_agg(
        to_jsonb(e)||jsonb_build_object(
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,
              e.rework_rate,e.collaboration_score,
              e.complexity_score,e.business_contribution)
          end,
          'evidence_details',public._operations_evidence_details(
            v_eid,e.evidence
          )
        ) order by e.period desc,e.updated_at desc
      ),'[]'::jsonb)
      from public.performance_evidence e
      where e.enterprise_id=v_eid and e.profile_id=v_uid
    )
  );
end;
$fn$;

create or replace function public.submit_performance_statement(
  p_evidence uuid,
  p_statement text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_statement text:=btrim(coalesce(p_statement,''));
  v_row public.performance_evidence%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.performance_evidence
   where id=p_evidence for update;
  if not found then raise exception 'performance evidence not found'; end if;
  if v_row.profile_id<>v_uid then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'submit_performance_statement',p_evidence::text,
      'performance evidence belongs to another member',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_row.status='reviewed' then
    raise exception 'reviewed performance evidence is immutable';
  end if;
  if v_statement='' then raise exception 'statement required'; end if;

  update public.performance_evidence set
    employee_statement=v_statement,status='submitted',updated_at=now()
  where id=p_evidence
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'operations.performance.statement',v_uid,
    jsonb_build_object('performance_id',p_evidence)
  );
  return to_jsonb(v_row)||jsonb_build_object(
    'score',public._operations_performance_score(
      v_row.on_time_rate,v_row.first_pass_rate,
      v_row.rework_rate,v_row.collaboration_score,
      v_row.complexity_score,v_row.business_contribution),
    'evidence_details',public._operations_evidence_details(
      v_row.enterprise_id,v_row.evidence)
  );
end;
$fn$;

create or replace function public.review_performance_evidence(
  p_evidence uuid,
  p_note text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_note text:=btrim(coalesce(p_note,''));
  v_row public.performance_evidence%rowtype;
  v_score numeric;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.performance_evidence
   where id=p_evidence for update;
  if not found then raise exception 'performance evidence not found'; end if;
  if not public._operations_has_permission(
    v_row.enterprise_id,v_uid,
    array['people.manage','tasks.grade','company.manage']::text[]
  ) then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'performance review permission required',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if not public._operations_can_access_profile(
    v_row.enterprise_id,v_uid,v_row.profile_id,
    array['people.manage','tasks.grade','company.manage']::text[],false
  ) then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'people scope does not allow this performance review',
      jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_row.profile_id=v_uid then
    return public._operations_denied(
      v_row.enterprise_id,v_uid,'review_performance_evidence',p_evidence::text,
      'self-review is not allowed',jsonb_build_object('performance_id',p_evidence)
    );
  end if;
  if v_note='' then raise exception 'review note required'; end if;
  if v_row.status='reviewed' then
    return to_jsonb(v_row)||jsonb_build_object(
      'duplicate',true,
      'evidence_details',public._operations_evidence_details(
        v_row.enterprise_id,v_row.evidence)
    );
  end if;

  v_score:=public._operations_performance_score(
    v_row.on_time_rate,v_row.first_pass_rate,
    v_row.rework_rate,v_row.collaboration_score,
    v_row.complexity_score,v_row.business_contribution
  );
  update public.performance_evidence set
    score=v_score,status='reviewed',reviewer_note=v_note,
    reviewed_by=v_uid,reviewed_at=now(),updated_at=now()
  where id=p_evidence
  returning * into v_row;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'operations.performance.reviewed',
    v_row.profile_id,
    jsonb_build_object(
      'performance_id',p_evidence,'period',v_row.period,
      'score',v_score,'note',v_note,
      'complexity_score',v_row.complexity_score,
      'business_contribution',v_row.business_contribution
    )
  );
  return to_jsonb(v_row)||jsonb_build_object(
    'duplicate',false,
    'evidence_details',public._operations_evidence_details(
      v_row.enterprise_id,v_row.evidence)
  );
end;
$fn$;
-- ------------------------------------------------------------ management dashboard
create or replace function public.get_operations_dashboard(
  p_weeks integer default 4
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_owner uuid;
  v_weeks integer:=least(greatest(coalesce(p_weeks,4),2),4);
  v_start date:=current_date;
  v_end date:=current_date+(least(greatest(coalesce(p_weeks,4),2),4)*7)-1;
  v_can_finance boolean:=false;
  v_can_people boolean:=false;
  v_can_projects boolean:=false;
  v_can_capacity boolean:=false;
  v_can_performance boolean:=false;
  v_can_worklogs boolean:=false;
  v_can_audit boolean:=false;
  v_capacity_blocked boolean:=false;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_management(v_eid,v_uid) then
    return public._operations_denied(
      v_eid,v_uid,'get_operations_dashboard','',
      'management permission required',jsonb_build_object('weeks',v_weeks)
    );
  end if;
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;

  v_can_finance:=public._operations_has_company_permission(
    v_eid,v_uid,array['finance.view','finance.manage']::text[]
  );
  v_can_people:=public._operations_has_scoped_permission(
    v_eid,v_uid,array['people.view_all','people.manage']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_projects:=public._operations_has_scoped_permission(
    v_eid,v_uid,array['projects.view_all','projects.manage']::text[],
    array['company','team','department','project','self']::text[]
  ) or v_can_finance;
  -- Gap math needs both demand and availability. A project-only manager
  -- cannot see people availability, so returning demand as shortage would
  -- manufacture a false capacity result.
  v_can_capacity:=v_can_people;
  v_capacity_blocked:=v_can_projects and not v_can_people;
  v_can_performance:=public._operations_has_scoped_permission(
    v_eid,v_uid,
    array['people.view_all','people.manage','tasks.grade']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_worklogs:=public._operations_has_scoped_permission(
    v_eid,v_uid,
    array['worklogs.approve','people.view_all','people.manage',
          'reports.view','finance.view','finance.manage']::text[],
    array['company','team','department','project']::text[]
  );
  v_can_audit:=public._operations_has_company_permission(
    v_eid,v_uid,array['audit.read']::text[]
  );

  -- Resolve finance items that are no longer overdue.
  update public.decision_items d
     set status='resolved',
         resolution=case when d.resolution='' then 'Collection is no longer overdue'
                         else d.resolution end,
         version=d.version+1,updated_at=now()
   where d.enterprise_id=v_eid and d.source_type='finance'
     and d.status in ('open','acknowledged','assigned','deferred')
     and not exists(
       select 1 from public.project_economics pe
        where pe.project_id=d.source_id
          and pe.invoice_due_date<current_date
          and pe.invoiced_amount>pe.collected_amount
     );

  -- Phase 2A owns the queue; Phase 2B feeds collection risks into it.
  insert into public.decision_items(
    enterprise_id,source_type,source_id,title,detail,evidence,risk,
    impact_days,impact_amount,waiting_since,owner_profile_id,status,resolution,
    due_at,created_at,updated_at
  )
  select
    v_eid,'finance',pe.project_id,
    'Overdue collection: '||p.name,
    'Invoice due '||pe.invoice_due_date::text||
      case when pe.payment_terms<>'' then ' ('||pe.payment_terms||')' else '' end,
    jsonb_build_array(jsonb_build_object(
      'type','finance','project_id',pe.project_id,
      'invoice_due_date',pe.invoice_due_date,
      'payment_terms',pe.payment_terms,
      'invoiced_amount',pe.invoiced_amount,
      'collected_amount',pe.collected_amount,
      'unpaid_invoice',greatest(pe.invoiced_amount-pe.collected_amount,0))),
    case when current_date-pe.invoice_due_date>=30 then 'severe'
         when current_date-pe.invoice_due_date>=7 then 'risk'
         else 'attention' end,
    greatest(current_date-pe.invoice_due_date,0),
    greatest(pe.invoiced_amount-pe.collected_amount,0),
    pe.invoice_due_date::timestamptz,
    v_owner,'open','',
    current_date::timestamptz+interval '1 day',now(),now()
  from public.project_economics pe
  join public.projects p on p.id=pe.project_id
  where v_can_finance
    and pe.enterprise_id=v_eid and p.boss_id=v_owner
    and pe.invoice_due_date<current_date
    and pe.invoiced_amount>pe.collected_amount
  on conflict (enterprise_id,source_type,source_id) do update set
    title=excluded.title,detail=excluded.detail,evidence=excluded.evidence,
    risk=excluded.risk,impact_days=excluded.impact_days,
    impact_amount=excluded.impact_amount,owner_profile_id=excluded.owner_profile_id,
    status='open',resolution='',due_at=excluded.due_at,updated_at=now();

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'management_only',true,
    'window_weeks',v_weeks,
    'period_start',v_start,
    'period_end',v_end,
    'access',jsonb_build_object(
      'can_projects',v_can_projects,
      'can_finance',v_can_finance,
      'can_people',v_can_people,
      'can_capacity',v_can_capacity,
      'capacity_requires_people_scope',v_capacity_blocked,
      'capacity_permission_message',case when v_capacity_blocked
        then 'Capacity gaps require people visibility scope; demand is hidden without it.'
        else '' end,
      'can_performance',v_can_performance,
      'can_worklogs',v_can_worklogs,
      'can_audit',v_can_audit,
      'can_manage_economics',public._operations_has_permission(
        v_eid,v_uid,array['finance.manage','projects.manage']::text[]),
      'can_manage_skills',public._operations_has_permission(
        v_eid,v_uid,array['people.manage']::text[]),
      'can_manage_capacity',v_can_capacity,
      'can_manage_performance',v_can_performance
    ),
    'projects',(
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'project_id',x.project_id,'name',x.name,'owner',x.owner,
          'status',x.status,
          'can_edit',public._operations_can_access_project(
            v_eid,v_uid,x.project_id,
            array['finance.manage','projects.manage']::text[])
        )
        ||case when v_can_finance then jsonb_build_object(
          'contract_amount',x.contract_amount,
          'invoiced_amount',x.invoiced_amount,
          'collected_amount',x.collected_amount,
          'outsourced_committed',x.outsourced_committed,
          'committed_amount',x.outsourced_committed,
          'outsourced_paid',x.outsourced_paid,
          'labor_cost',x.labor_cost,
          'other_cost',x.other_cost,
          'projected_completion_cost',x.projected_cost,
          'projected_cost',x.projected_cost,
          'projected_margin',x.projected_margin,
          'projected_margin_percent',case when x.contract_amount>0
            then round(x.projected_margin/x.contract_amount*100,2) else 0 end,
          'collection_gap',greatest(x.contract_amount-x.collected_amount,0),
          'invoice_gap',greatest(x.contract_amount-x.invoiced_amount,0),
          'unpaid_invoice',greatest(x.invoiced_amount-x.collected_amount,0),
          'invoice_due_date',x.invoice_due_date,
          'payment_terms',x.payment_terms,
          'overdue_days',case when x.invoice_due_date<current_date
            and x.invoiced_amount>x.collected_amount
            then current_date-x.invoice_due_date else 0 end,
          'overdue_amount',case when x.invoice_due_date<current_date
            and x.invoiced_amount>x.collected_amount
            then x.invoiced_amount-x.collected_amount else 0 end
        ) else '{}'::jsonb end
        order by x.name),'[]'::jsonb)
      from (
        select p.id project_id,p.name,p.owner,p.status,
          coalesce(pe.contract_amount,0) contract_amount,
          coalesce(pe.invoiced_amount,0) invoiced_amount,
          coalesce(pe.collected_amount,0) collected_amount,
          coalesce(pe.outsourced_committed,0) outsourced_committed,
          coalesce(pe.outsourced_paid,0) outsourced_paid,
          coalesce(pe.labor_cost,0) labor_cost,
          coalesce(pe.other_cost,0) other_cost,
          pe.invoice_due_date,coalesce(pe.payment_terms,'') payment_terms,
          case when coalesce(pe.estimated_completion_cost,0)>0
            then pe.estimated_completion_cost
            else coalesce(pe.labor_cost,0)
              +coalesce(pe.outsourced_committed,0)
              +coalesce(pe.other_cost,0) end projected_cost,
          coalesce(pe.contract_amount,0)
            -case when coalesce(pe.estimated_completion_cost,0)>0
              then pe.estimated_completion_cost
              else coalesce(pe.labor_cost,0)
                +coalesce(pe.outsourced_committed,0)
                +coalesce(pe.other_cost,0) end projected_margin
        from public.projects p
        left join public.project_economics pe on pe.project_id=p.id
        where p.boss_id=v_owner
          and public._operations_can_access_project(
            v_eid,v_uid,p.id,
            array['projects.view_all','projects.manage',
                  'finance.view','finance.manage']::text[])
      ) x
    ),
    'collection_alerts',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_id',p.id,'name',p.name,
        'invoice_due_date',pe.invoice_due_date,
        'payment_terms',pe.payment_terms,
        'overdue_days',current_date-pe.invoice_due_date,
        'overdue_amount',greatest(pe.invoiced_amount-pe.collected_amount,0),
        'risk',case when current_date-pe.invoice_due_date>=30 then 'severe'
          when current_date-pe.invoice_due_date>=7 then 'risk'
          else 'attention' end
      ) order by current_date-pe.invoice_due_date desc),'[]'::jsonb)
      from public.project_economics pe
      join public.projects p on p.id=pe.project_id
      where v_can_finance and pe.enterprise_id=v_eid
        and pe.invoice_due_date<current_date
        and pe.invoiced_amount>pe.collected_amount
    ),
    'skills',(
      select coalesce(jsonb_agg(to_jsonb(ps)||jsonb_build_object(
        'name',p.name,'source_id',ps.profile_id
      ) order by p.name,ps.skill),'[]'::jsonb)
      from public.profile_skills ps
      join public.profiles p on p.id=ps.profile_id
      where v_can_people and ps.enterprise_id=v_eid
        and public._operations_can_access_profile(
          v_eid,v_uid,ps.profile_id,
          array['people.view_all','people.manage']::text[],false)
    ),
    'capacity_demands',(
      select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object(
        'source_id',d.id,'project_name',coalesce(p.name,'')
      ) order by d.needed_from,d.skill),'[]'::jsonb)
      from public.capacity_demands d
      left join public.projects p on p.id=d.project_id
      where v_can_capacity and d.enterprise_id=v_eid
        and (
          (d.project_id is null and v_can_people)
          or (d.project_id is not null and public._operations_can_access_project(
            v_eid,v_uid,d.project_id,
            array['projects.view_all','projects.manage',
                  'people.view_all','people.manage']::text[]))
        )
    ),
    'capacity_gaps',(
      with demand as (
        select d.skill,sum(d.required_hours) required_hours
        from public.capacity_demands d
        where v_can_capacity and d.enterprise_id=v_eid
          and d.needed_from<=v_end and d.needed_until>=v_start
          and (
            (d.project_id is null and v_can_people)
            or (d.project_id is not null and public._operations_can_access_project(
              v_eid,v_uid,d.project_id,
              array['projects.view_all','projects.manage',
                    'people.view_all','people.manage']::text[]))
          )
        group by d.skill
      ), availability as (
        select ps.skill,
          sum(
            coalesce(ps.available_hours,0)
            * greatest(0,
                least(v_end,coalesce(ps.valid_until,v_end))
                -greatest(v_start,current_date)+1
              )/7.0
          ) available_hours
        from public.profile_skills ps
        join public.enterprise_members m
          on m.enterprise_id=ps.enterprise_id
         and m.profile_id=ps.profile_id and m.status='active'
        where v_can_people and ps.enterprise_id=v_eid
          and (ps.valid_until is null or ps.valid_until>=v_start)
          and public._operations_can_access_profile(
            v_eid,v_uid,ps.profile_id,
            array['people.view_all','people.manage']::text[],false)
        group by ps.skill
      ), skills as (
        select skill from demand union select skill from availability
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'skill',s.skill,
        'required_hours',coalesce(d.required_hours,0),
        'available_hours',round(coalesce(a.available_hours,0),2),
        'gap_hours',greatest(
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0),
        'period_start',v_start,'period_end',v_end,
        'status',case when
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0)>0
          then 'shortage' else 'covered' end
      ) order by greatest(
        coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0
      ) desc,s.skill),'[]'::jsonb)
      from skills s
      left join demand d on d.skill=s.skill
      left join availability a on a.skill=s.skill
    ),
    'performance',(
      with acceptance_stats as (
        select
          t.employee_id profile_id,
          to_char(coalesce(max(a.reviewed_at),now()),'YYYY-MM') period,
          count(*) filter(where a.status='accepted') accepted_count,
          count(*) filter(where a.status='rework') rework_count,
          case when count(*) filter(where a.status='accepted')>0 then
            count(*) filter(
              where a.status='accepted' and a.submitted_at::date<=t.plan_date
            )::numeric/count(*) filter(where a.status='accepted')
          else 0 end on_time_rate,
          case when count(*)>0 then
            count(*) filter(where a.status='accepted')::numeric/count(*)
          else 0 end first_pass_rate,
          case when count(*)>0 then
            count(*) filter(where a.status='rework')::numeric/count(*)
          else 0 end rework_rate,
          jsonb_agg(jsonb_build_object(
            'type','task_acceptance','id',a.task_id,'status',a.status,
            'reviewed_at',a.reviewed_at)) evidence
        from public.task_acceptance a
        join public.tasks t on t.id=a.task_id
        where v_can_performance and a.enterprise_id=v_eid
          and a.status in ('accepted','rework')
          and public._operations_can_access_profile(
            v_eid,v_uid,t.employee_id,
            array['people.view_all','people.manage','tasks.grade']::text[],false)
        group by t.employee_id,to_char(coalesce(a.reviewed_at,a.updated_at),'YYYY-MM')
      ), performance_items as (
        select jsonb_build_object(
          'id',e.id,
          'enterprise_id',e.enterprise_id,
          'profile_id',e.profile_id,
          'period',e.period,
          'on_time_rate',e.on_time_rate,
          'first_pass_rate',e.first_pass_rate,
          'rework_rate',e.rework_rate,
          'collaboration_score',e.collaboration_score,
          'complexity_score',e.complexity_score,
          'business_contribution',e.business_contribution,
          'customer_evaluation',e.customer_evaluation,
          'evidence',e.evidence,
          'employee_statement',e.employee_statement,
          'status',e.status,
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,e.rework_rate,
              e.collaboration_score,e.complexity_score,
              e.business_contribution) end,
          'reviewer_note',e.reviewer_note,
          'reviewed_by',e.reviewed_by,
          'reviewed_at',e.reviewed_at,
          'source','manual',
          'source_id',e.id,
          'evidence_details',public._operations_evidence_details(
            v_eid,e.evidence),
          'can_review',public._operations_can_access_profile(
            v_eid,v_uid,e.profile_id,
            array['people.manage','tasks.grade','company.manage']::text[],false)
        ) item,
        p.name sort_name,
        e.period sort_period
        from public.performance_evidence e
        join public.profiles p on p.id=e.profile_id
        where v_can_performance and e.enterprise_id=v_eid
          and public._operations_can_access_profile(
            v_eid,v_uid,e.profile_id,
            array['people.view_all','people.manage','tasks.grade']::text[],false)
        union all
        select jsonb_build_object(
          'id',null,
          'enterprise_id',v_eid,
          'profile_id',s.profile_id,
          'period',s.period,
          'on_time_rate',s.on_time_rate,
          'first_pass_rate',s.first_pass_rate,
          'rework_rate',s.rework_rate,
          'collaboration_score',0,
          'complexity_score',0,
          'business_contribution',0,
          'customer_evaluation','{}'::jsonb,
          'evidence',s.evidence,
          'employee_statement','',
          'status','submitted',
          'score',public._operations_performance_score(
            s.on_time_rate,s.first_pass_rate,s.rework_rate,0,0,0),
          'reviewer_note','Derived from task acceptance records',
          'reviewed_by',null,
          'reviewed_at',null,
          'source','task_acceptance',
          'source_id',null,
          'accepted_count',s.accepted_count,
          'rework_count',s.rework_count,
          'evidence_details',s.evidence,
          'can_review',false
        ) item,
        p.name sort_name,
        s.period sort_period
        from acceptance_stats s
        join public.profiles p on p.id=s.profile_id
      )
      select coalesce(jsonb_agg(
        item order by sort_name,sort_period desc
      ),'[]'::jsonb)
      from performance_items
    ),
    'worklog_summary',(
      with entries as (
        select coalesce(d.work_kind,'project') work_kind,
          coalesce(d.billable,true) billable,
          coalesce(d.overtime,false) overtime,
          coalesce(d.rework,false) rework,
          coalesce(d.waiting,false) waiting,
          coalesce(d.travel,false) travel,
          w.hours
        from public.worklogs w
        left join public.worklog_dimensions d on d.worklog_id=w.id
        where v_can_worklogs and w.boss_id=v_owner
          and w.approval_status='approved'
          and w.work_date between v_start and v_end
          and (
            (w.project_id is null and public._operations_has_company_permission(
              v_eid,v_uid,array['worklogs.approve','people.view_all',
                'people.manage','reports.view','finance.view',
                'finance.manage']::text[]))
            or (w.project_id is not null and public._operations_can_access_project(
              v_eid,v_uid,w.project_id,
              array['worklogs.approve','people.view_all','people.manage',
                    'reports.view','finance.view','finance.manage']::text[]))
          )
      )
      select jsonb_build_object(
        'total_hours',coalesce(sum(hours),0),
        'billable_hours',coalesce(sum(hours) filter(where billable),0),
        'overtime_hours',coalesce(sum(hours) filter(where overtime),0),
        'rework_hours',coalesce(sum(hours) filter(where rework),0),
        'waiting_hours',coalesce(sum(hours) filter(where waiting),0),
        'travel_hours',coalesce(sum(hours) filter(where travel),0),
        'by_kind',coalesce((
          select jsonb_object_agg(k.work_kind,k.hours)
          from (
            select work_kind,sum(hours) hours from entries group by work_kind
          ) k
        ),'{}'::jsonb)
      )
      from entries
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'profile_id',m.profile_id,'name',p.name,
        'department',m.department,'title',m.title
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where (v_can_people or v_can_performance)
        and m.enterprise_id=v_eid and m.status='active'
        and public._operations_can_access_profile(
          v_eid,v_uid,m.profile_id,
          array['people.view_all','people.manage','tasks.grade']::text[],true)
    ),
    'security_audit',(
      select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb)
      from (
        select * from public.operations_security_audit
         where v_can_audit and enterprise_id=v_eid
         order by created_at desc limit 50
      ) a
    )
  );
end;
$fn$;

-- ------------------------------------------------------------ privileges
revoke all on function public.upsert_project_economics(uuid,jsonb) from public;
revoke all on function public.upsert_project_economics(uuid,jsonb) from anon;
revoke all on function public.upsert_project_economics(uuid,jsonb) from authenticated;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from public;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from anon;
revoke all on function public.upsert_profile_skill(uuid,text,jsonb) from authenticated;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from public;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from anon;
revoke all on function public.upsert_capacity_demand(uuid,jsonb) from authenticated;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from public;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from anon;
revoke all on function public.upsert_worklog_dimensions(uuid,jsonb) from authenticated;
revoke all on function public.get_worklog_dimensions(uuid) from public;
revoke all on function public.get_worklog_dimensions(uuid) from anon;
revoke all on function public.get_worklog_dimensions(uuid) from authenticated;
revoke all on function public.worklog_dimensions(uuid,jsonb) from public;
revoke all on function public.worklog_dimensions(uuid,jsonb) from anon;
revoke all on function public.worklog_dimensions(uuid,jsonb) from authenticated;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from public;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from anon;
revoke all on function public.upsert_performance_evidence(uuid,text,jsonb) from authenticated;
revoke all on function public.get_my_performance_evidence() from public;
revoke all on function public.get_my_performance_evidence() from anon;
revoke all on function public.get_my_performance_evidence() from authenticated;
revoke all on function public.submit_performance_statement(uuid,text) from public;
revoke all on function public.submit_performance_statement(uuid,text) from anon;
revoke all on function public.submit_performance_statement(uuid,text) from authenticated;
revoke all on function public.review_performance_evidence(uuid,text) from public;
revoke all on function public.review_performance_evidence(uuid,text) from anon;
revoke all on function public.review_performance_evidence(uuid,text) from authenticated;
revoke all on function public.get_operations_dashboard(integer) from public;
revoke all on function public.get_operations_dashboard(integer) from anon;
revoke all on function public.get_operations_dashboard(integer) from authenticated;

grant execute on function public.upsert_project_economics(uuid,jsonb) to authenticated;
grant execute on function public.upsert_profile_skill(uuid,text,jsonb) to authenticated;
grant execute on function public.upsert_capacity_demand(uuid,jsonb) to authenticated;
grant execute on function public.upsert_worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.get_worklog_dimensions(uuid) to authenticated;
grant execute on function public.worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.upsert_performance_evidence(uuid,text,jsonb) to authenticated;
grant execute on function public.get_my_performance_evidence() to authenticated;
grant execute on function public.submit_performance_statement(uuid,text) to authenticated;
grant execute on function public.review_performance_evidence(uuid,text) to authenticated;
grant execute on function public.get_operations_dashboard(integer) to authenticated;
$operations_phase2b$;
end;
$operations_installer$;

-- Phase 4: work intake
-- Canonical source: mobile/sql/work-intake-v1.sql
-- This guarded block applies after enterprise identity, projects, tasks,
-- and the Phase 1-3 migrations. Re-running is safe.
do $intake_installer$
begin
  if to_regclass('public.enterprises') is null
     or to_regclass('public.projects') is null
     or to_regclass('public.tasks') is null
     or to_regprocedure('public._identity_role_permissions(uuid,uuid)') is null then
    raise notice 'Phase 4 skipped: run enterprise identity, unified platform, and Phase 1-3 migrations first.';
  else
-- ============================================================
-- Project Recorder - Phase 4 work intake
--
-- Run after decision-approvals-v1.sql, execution-tracking-v1.sql,
-- and operations-economics-v1.sql. This migration is idempotent.
-- Public callers use form tokens and receive no internal data.
-- ============================================================

create sequence if not exists public.intake_request_seq;

create table if not exists public.intake_settings (
  enterprise_id uuid primary key references public.enterprises(id) on delete cascade,
  email_domain text not null default 'inbound.projectrecorder.local',
  public_form_base_url text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_forms (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  name text not null default 'Work intake',
  public_token text not null unique,
  allowed_types text[] not null default array['customer','sales','improvement','incident','temporary']::text[],
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  request_no text not null default ('INT-' || to_char(now(),'YYYYMMDD') || '-' || lpad(nextval('public.intake_request_seq')::text,6,'0')) unique,
  source_type text not null default 'quick'
    check (source_type in ('quick','public_form','email','wechat','internal')),
  request_type text not null default 'temporary'
    check (request_type in ('customer','sales','improvement','incident','temporary')),
  title text not null check (char_length(btrim(title)) > 0),
  detail text not null default '',
  requester_profile_id uuid references public.profiles(id) on delete set null,
  requester_name text not null default '',
  requester_email text not null default '',
  requester_phone text not null default '',
  tracking_code text unique,
  form_id uuid references public.intake_forms(id) on delete set null,
  status text not null default 'submitted'
    check (status in ('submitted','triage','in_progress','resolved','closed','merged')),
  priority_score numeric not null default 0 check (priority_score >= 0),
  priority_factors jsonb not null default '[]'::jsonb,
  priority_override numeric check (priority_override is null or priority_override >= 0),
  priority_override_reason text not null default '',
  owner_profile_id uuid references public.profiles(id) on delete set null,
  sla_due_at timestamptz not null default now(),
  first_response_at timestamptz,
  escalated_at timestamptz,
  resolved_at timestamptz,
  merged_into_id uuid references public.intake_requests(id) on delete set null,
  converted_kind text check (converted_kind is null or converted_kind in ('project','task','presales')),
  converted_at timestamptz,
  linked_project_id uuid references public.projects(id) on delete set null,
  linked_task_id uuid references public.tasks(id) on delete set null,
  presales_owner_id uuid references public.profiles(id) on delete set null,
  source_ref text not null default '',
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (merged_into_id is null or merged_into_id <> id),
  check (status <> 'merged' or merged_into_id is not null)
);

create table if not exists public.intake_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  source_request_id uuid references public.intake_requests(id) on delete set null,
  author_profile_id uuid references public.profiles(id) on delete set null,
  author_label text not null default '',
  visibility text not null default 'internal'
    check (visibility in ('public','internal','system')),
  body text not null check (char_length(btrim(body)) > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.intake_links (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  linked_request_id uuid not null references public.intake_requests(id) on delete cascade,
  link_type text not null default 'related'
    check (link_type in ('duplicate','related')),
  note text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (request_id, linked_request_id, link_type),
  check (request_id <> linked_request_id)
);

create table if not exists public.intake_events (
  id bigserial primary key,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  from_status text not null default '',
  to_status text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_security_audit (
  id bigserial primary key,
  enterprise_id uuid references public.enterprises(id) on delete set null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  reason text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_submission_attempts (
  id bigserial primary key,
  form_id uuid references public.intake_forms(id) on delete cascade,
  email_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_email_aliases (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  label text not null default '',
  alias_token text not null unique,
  email_address text not null,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_notifications (
  id bigserial primary key,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  recipient_email text not null,
  kind text not null default 'status',
  subject text not null default '',
  body text not null default '',
  status text not null default 'pending'
    check (status in ('pending','sent','failed')),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.presales_opportunities (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  title text not null,
  customer_name text not null default '',
  estimated_value numeric not null default 0 check (estimated_value >= 0),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  stage text not null default 'qualified'
    check (stage in ('qualified','proposal','negotiation','won','lost')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_conversions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  kind text not null check (kind in ('project','task','presales')),
  linked_id uuid not null,
  payload jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists intake_requests_request_no_idx
  on public.intake_requests(request_no);
create index if not exists intake_requests_enterprise_status_idx
  on public.intake_requests(enterprise_id,status,created_at desc);
create index if not exists intake_requests_sla_idx
  on public.intake_requests(enterprise_id,status,sla_due_at);
create index if not exists intake_requests_requester_idx
  on public.intake_requests(requester_profile_id,created_at desc);
create index if not exists intake_conversions_request_idx
  on public.intake_conversions(request_id,created_at);
create index if not exists intake_messages_request_idx
  on public.intake_messages(request_id,created_at);
create index if not exists intake_submission_attempts_idx
  on public.intake_submission_attempts(form_id,email_hash,created_at desc);
create index if not exists intake_notifications_pending_idx
  on public.intake_notifications(status,created_at);

alter table public.intake_settings enable row level security;
alter table public.intake_forms enable row level security;
alter table public.intake_requests enable row level security;
alter table public.intake_messages enable row level security;
alter table public.intake_links enable row level security;
alter table public.intake_events enable row level security;
alter table public.intake_security_audit enable row level security;
alter table public.intake_submission_attempts enable row level security;
alter table public.intake_email_aliases enable row level security;
alter table public.intake_notifications enable row level security;
alter table public.presales_opportunities enable row level security;
alter table public.intake_conversions enable row level security;

revoke all on table public.intake_settings from public, anon, authenticated;
revoke all on table public.intake_forms from public, anon, authenticated;
revoke all on table public.intake_requests from public, anon, authenticated;
revoke all on table public.intake_messages from public, anon, authenticated;
revoke all on table public.intake_links from public, anon, authenticated;
revoke all on table public.intake_events from public, anon, authenticated;
revoke all on table public.intake_security_audit from public, anon, authenticated;
revoke all on table public.intake_submission_attempts from public, anon, authenticated;
revoke all on table public.intake_email_aliases from public, anon, authenticated;
revoke all on table public.intake_notifications from public, anon, authenticated;
revoke all on table public.presales_opportunities from public, anon, authenticated;
revoke all on table public.intake_conversions from public, anon, authenticated;

create or replace function public._intake_current_enterprise(p_uid uuid)
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

create or replace function public._intake_is_member(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select p_uid is not null and exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
  );
$fn$;

create or replace function public._intake_has_permission(
  p_eid uuid,p_uid uuid,p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
  ) then return false; end if;
  if exists(select 1 from public.enterprises e
    where e.id=p_eid and e.owner_profile_id=p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permissions(p_eid,p_uid)
    )
  loop
    if (v_grant #>> '{}') = any(p_permissions) then return true; end if;
    if jsonb_typeof(v_grant)='object'
       and coalesce(v_grant->>'permission_key','') = any(p_permissions) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._intake_can_manage(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._intake_has_permission(
    p_eid,p_uid,
    array['company.manage','projects.manage','tasks.assign','reports.view']::text[]
  );
$fn$;

create or replace function public._intake_is_executive(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(select 1 from public.enterprises e
    where e.id=p_eid and e.owner_profile_id=p_uid)
    or public._intake_has_permission(
      p_eid,p_uid,array['company.manage','governance.vote']::text[]);
$fn$;

create or replace function public._intake_safe_number(
  p_value text,p_default numeric,p_min numeric,p_max numeric
) returns numeric
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_value numeric;
begin
  begin v_value:=nullif(btrim(coalesce(p_value,'')),'')::numeric;
  exception when others then v_value:=null; end;
  return least(greatest(coalesce(v_value,p_default),p_min),p_max);
end;
$fn$;

create or replace function public._intake_type(p_type text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_type text:=lower(btrim(coalesce(p_type,'')));
begin
  if v_type in ('customer',U&'\5BA2\6237',U&'\5BA2\6237\9700\6C42') then return 'customer'; end if;
  if v_type in ('sales',U&'\9500\552E',U&'\9500\552E\673A\4F1A') then return 'sales'; end if;
  if v_type in ('improvement',U&'\5185\90E8\6539\8FDB') then return 'improvement'; end if;
  if v_type in ('incident','fault',U&'\6545\969C') then return 'incident'; end if;
  if v_type in ('temporary',U&'\4E34\65F6',U&'\4E34\65F6\4E8B\9879') then return 'temporary'; end if;
  return 'temporary';
end;
$fn$;

create or replace function public._intake_sla_interval(p_type text)
returns interval
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select case public._intake_type(p_type)
    when 'incident' then interval '2 hours'
    when 'customer' then interval '1 day'
    when 'improvement' then interval '3 days'
    else interval '1 day' end;
$fn$;

create or replace function public._intake_priority(p_data jsonb)
returns jsonb
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_business numeric:=public._intake_safe_number(p_data->>'business_value',0,0,5);
  v_urgency numeric:=public._intake_safe_number(p_data->>'urgency',0,0,5);
  v_risk numeric:=public._intake_safe_number(p_data->>'risk',0,0,5);
  v_dependency numeric:=public._intake_safe_number(p_data->>'dependency_impact',0,0,5);
  v_effort numeric:=public._intake_safe_number(p_data->>'effort',0,0,5);
  v_score numeric;
begin
  v_score:=v_business*5+v_urgency*4+v_risk*3+v_dependency*2-v_effort*2;
  return jsonb_build_object(
    'score',v_score,
    'factors',jsonb_build_array(
      jsonb_build_object('key','business_value','label','Business value','value',v_business,'weight',5,'points',v_business*5,'reason','business value x 5'),
      jsonb_build_object('key','urgency','label','Urgency','value',v_urgency,'weight',4,'points',v_urgency*4,'reason','urgency x 4'),
      jsonb_build_object('key','risk','label','Risk','value',v_risk,'weight',3,'points',v_risk*3,'reason','risk x 3'),
      jsonb_build_object('key','dependency_impact','label','Dependency impact','value',v_dependency,'weight',2,'points',v_dependency*2,'reason','dependency impact x 2'),
      jsonb_build_object('key','effort','label','Effort','value',v_effort,'weight',-2,'points',v_effort*-2,'reason','effort x -2')
    ),
    'explanation','server-computed weighted score'
  );
end;
$fn$;

create or replace function public._intake_tracking_code()
returns text
language sql volatile security definer
set search_path=public,auth,pg_temp
as $fn$
  select upper(substr(md5(clock_timestamp()::text || random()::text || gen_random_uuid()::text),1,8));
$fn$;

create or replace function public._intake_public_token()
returns text
language sql volatile security definer
set search_path=public,auth,pg_temp
as $fn$
  select lower(substr(md5(clock_timestamp()::text || random()::text || gen_random_uuid()::text),1,32));
$fn$;

create or replace function public._intake_similarity(p_left text,p_right text)
returns numeric
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_left text:=regexp_replace(lower(coalesce(p_left,'')),'[[:space:][:punct:]]','','g');
  v_right text:=regexp_replace(lower(coalesce(p_right,'')),'[[:space:][:punct:]]','','g');
  v_len integer;
  v_matches integer:=0;
  v_gram text;
  i integer;
begin
  if v_left='' or v_right='' then return 0; end if;
  v_len:=greatest(length(v_left)-1,1);
  for i in 1..v_len loop
    v_gram:=substr(v_left,i,2);
    if v_gram<>'' and position(v_gram in v_right)>0 then v_matches:=v_matches+1; end if;
  end loop;
  return round((2.0*v_matches)::numeric/(length(v_left)+length(v_right)),4);
end;
$fn$;

create or replace function public._intake_denied(
  p_eid uuid,p_uid uuid,p_operation text,p_reason text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.intake_security_audit(
    enterprise_id,actor_profile_id,operation,reason,payload
  ) values(p_eid,p_uid,p_operation,p_reason,coalesce(p_payload,'{}'::jsonb));
  return jsonb_build_object(
    'ok',false,'code','permission_denied','error',p_reason
  );
end;
$fn$;

create or replace function public._intake_success(
  p_eid uuid,p_uid uuid,p_operation text,p_request uuid,
  p_action text,p_before jsonb,p_after jsonb,p_payload jsonb default '{}'::jsonb
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_eid,p_uid,p_operation,null,
    jsonb_build_object(
      'request_id',p_request,'action',p_action,
      'before',coalesce(p_before,'{}'::jsonb),
      'after',coalesce(p_after,'{}'::jsonb),
      'payload',coalesce(p_payload,'{}'::jsonb)
    )
  );
end;
$fn$;

create or replace function public._intake_event(
  p_request uuid,p_uid uuid,p_action text,p_from text,p_to text,
  p_payload jsonb default '{}'::jsonb
) returns void
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  insert into public.intake_events(
    request_id,actor_profile_id,action,from_status,to_status,payload
  ) values(
    p_request,p_uid,p_action,coalesce(p_from,''),coalesce(p_to,''),
    coalesce(p_payload,'{}'::jsonb)
  );
$fn$;

create or replace function public._intake_notify(
  p_request uuid,p_kind text,p_subject text,p_body text
) returns void
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  insert into public.intake_notifications(
    request_id,recipient_email,kind,subject,body
  )
  select p_request,nullif(lower(btrim(r.requester_email)),''),p_kind,p_subject,p_body
    from public.intake_requests r
   where r.id=p_request and btrim(r.requester_email)<>'';
$fn$;

create or replace function public._intake_escalate_due(p_eid uuid)
returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_owner uuid;
  v_row public.intake_requests%rowtype;
  v_count integer:=0;
begin
  select e.owner_profile_id into v_owner
    from public.enterprises e where e.id=p_eid;
  for v_row in
    select * from public.intake_requests r
     where r.enterprise_id=p_eid and r.status='submitted'
       and r.sla_due_at<=now() and r.escalated_at is null
     for update
  loop
    update public.intake_requests set
      status='triage',
      owner_profile_id=coalesce(owner_profile_id,v_owner),
      priority_score=priority_score+10,
      escalated_at=now(),
      version=version+1,
      updated_at=now()
    where id=v_row.id;
    perform public._intake_event(
      v_row.id,null,'sla.escalated','submitted','triage',
      jsonb_build_object('owner_profile_id',coalesce(v_row.owner_profile_id,v_owner))
    );
    perform public._intake_notify(
      v_row.id,'sla','Request escalated',
      'The request exceeded its triage SLA and was escalated.'
    );
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$fn$;

-- ---------------------------------------------------------- forms and board
create or replace function public.create_intake_form(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_name text:=btrim(coalesce(p_data->>'name','Work intake'));
  v_token text;
  v_types text[];
  v_row public.intake_forms%rowtype;
  v_base text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_form','projects.manage authority required');
  end if;
  select coalesce(array_agg(public._intake_type(value)),array['customer','sales','improvement','incident','temporary']::text[])
    into v_types
    from jsonb_array_elements_text(coalesce(p_data->'allowed_types','[]'::jsonb)) value;
  if v_types is null or cardinality(v_types)=0 then
    v_types:=array['customer','sales','improvement','incident','temporary']::text[];
  end if;
  loop
    v_token:=public._intake_public_token();
    exit when not exists(select 1 from public.intake_forms f where f.public_token=v_token);
  end loop;
  insert into public.intake_forms(
    enterprise_id,name,public_token,allowed_types,created_by
  ) values(v_eid,coalesce(nullif(v_name,''),'Work intake'),v_token,v_types,v_uid)
  returning * into v_row;
  select coalesce(s.public_form_base_url,'') into v_base
    from public.intake_settings s where s.enterprise_id=v_eid;
  v_base:=coalesce(nullif(rtrim(v_base,'/'),''),'');
  perform public._intake_success(
    v_eid,v_uid,'intake_form',v_row.id,'form.created','{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('name',v_row.name)
  );
  return jsonb_build_object(
    'ok',true,'form',to_jsonb(v_row),
    'public_url',case when v_base='' then '/intake.html?token='||v_row.public_token
      else v_base||'/intake.html?token='||v_row.public_token end
  );
end;
$fn$;

create or replace function public.update_intake_form(
  p_form uuid,p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_forms%rowtype;
  v_before jsonb;
  v_types text[];
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_forms where id=p_form for update;
  if not found then raise exception 'intake form not found'; end if;
  v_eid:=v_row.enterprise_id;
  if not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'update_intake_form','projects.manage authority required');
  end if;
  select coalesce(array_agg(public._intake_type(value)),v_row.allowed_types)
    into v_types
    from jsonb_array_elements_text(coalesce(p_data->'allowed_types',to_jsonb(v_row.allowed_types))) value;
  v_before:=to_jsonb(v_row);
  update public.intake_forms set
    name=coalesce(nullif(btrim(p_data->>'name'),''),name),
    allowed_types=coalesce(v_types,allowed_types),
    active=case when p_data ? 'active' then (p_data->>'active')::boolean else active end,
    updated_at=now()
  where id=p_form returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_form',p_form,'form.updated',v_before,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'form',to_jsonb(v_row));
end;
$fn$;

create or replace function public.get_intake_board(p_enterprise uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=coalesce(p_enterprise,public._intake_current_enterprise(auth.uid()));
  v_settings public.intake_settings%rowtype;
  v_base text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    return public._intake_denied(null,v_uid,'get_intake_board','enterprise not found');
  end if;
  if not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'get_intake_board','projects.manage authority required');
  end if;
  perform public._intake_escalate_due(v_eid);
  select * into v_settings from public.intake_settings where enterprise_id=v_eid;
  v_base:=coalesce(nullif(rtrim(v_settings.public_form_base_url,'/'),''),'');
  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'settings',jsonb_build_object(
      'email_domain',coalesce(v_settings.email_domain,'inbound.projectrecorder.local'),
      'public_form_base_url',v_base
    ),
    'forms',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',f.id,'name',f.name,'active',f.active,
        'allowed_types',f.allowed_types,'public_token',f.public_token,
        'public_url',case when v_base='' then '/intake.html?token='||f.public_token
          else v_base||'/intake.html?token='||f.public_token end,
        'created_at',f.created_at
      ) order by f.created_at desc),'[]'::jsonb)
      from public.intake_forms f where f.enterprise_id=v_eid
    ),
    'email_aliases',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',a.id,'label',a.label,'email_address',a.email_address,
        'active',a.active,'created_at',a.created_at
      ) order by a.created_at desc),'[]'::jsonb)
      from public.intake_email_aliases a where a.enterprise_id=v_eid
    ),
    'requests',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',r.id,'request_no',r.request_no,'source_type',r.source_type,
        'request_type',r.request_type,'title',r.title,'detail',r.detail,
        'requester_name',r.requester_name,'requester_email',r.requester_email,
        'status',r.status,'priority_score',r.priority_score,
        'priority_factors',r.priority_factors,
        'priority_override',r.priority_override,
        'priority_override_reason',r.priority_override_reason,
        'owner_profile_id',r.owner_profile_id,'owner_name',op.name,
        'sla_due_at',r.sla_due_at,'first_response_at',r.first_response_at,
        'escalated_at',r.escalated_at,'resolved_at',r.resolved_at,
        'sla_overdue',r.status in ('submitted','triage','in_progress') and r.sla_due_at<now(),
        'merged_into_id',r.merged_into_id,'converted_kind',r.converted_kind,
        'converted_at',r.converted_at,'linked_project_id',r.linked_project_id,
        'linked_project_name',pr.name,'linked_task_id',r.linked_task_id,
        'linked_task_title',t.title,'presales_owner_id',r.presales_owner_id,
        'conversions',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',c.id,'kind',c.kind,'linked_id',c.linked_id,
            'payload',c.payload,'created_at',c.created_at
          ) order by c.created_at)
          from public.intake_conversions c where c.request_id=r.id
        ),'[]'::jsonb),
        'created_at',r.created_at,'updated_at',r.updated_at,
        'actions',jsonb_build_object(
          'triage',true,'merge',r.status<>'merged','convert',r.status<>'merged'
        ),
        'messages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',m.id,'author_profile_id',m.author_profile_id,
            'author_label',m.author_label,'visibility',m.visibility,
            'body',m.body,'created_at',m.created_at
          ) order by m.created_at)
          from public.intake_messages m where m.request_id=r.id
        ),'[]'::jsonb),
        'links',coalesce((
          select jsonb_agg(jsonb_build_object(
            'linked_request_id',l.linked_request_id,'link_type',l.link_type,
            'note',l.note
          ) order by l.created_at)
          from public.intake_links l where l.request_id=r.id
        ),'[]'::jsonb)
      ) order by r.priority_score desc,r.created_at desc),'[]'::jsonb)
      from (
        select * from public.intake_requests
         where enterprise_id=v_eid
         order by priority_score desc,created_at desc limit 300
      ) r
      left join public.profiles op on op.id=r.owner_profile_id
      left join public.projects pr on pr.id=r.linked_project_id
      left join public.tasks t on t.id=r.linked_task_id
    ),
    'projects',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',p.id,'name',p.name,'boss_id',p.boss_id
      ) order by p.name),'[]'::jsonb)
      from public.projects p
      where exists(
        select 1 from public.enterprise_members m
         where m.enterprise_id=v_eid and m.profile_id=p.boss_id and m.status='active'
      )
    ),
    'tasks',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',x.id,'title',x.title,'project_id',x.project_id,
        'employee_id',x.employee_id
      ) order by x.plan_date desc,x.title),'[]'::jsonb)
      from (
        select t.id,t.title,t.project_id,t.employee_id,t.plan_date
          from public.tasks t
          join public.projects p on p.id=t.project_id
         where exists(
           select 1 from public.enterprise_members m
            where m.enterprise_id=v_eid and m.profile_id=p.boss_id and m.status='active'
         )
         order by t.plan_date desc,t.title limit 500
      ) x
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',m.profile_id,'name',p.name,'department',m.department,
        'role_key',m.role_key
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
    ),
    'access',jsonb_build_object(
      'management',true,'can_create_form',true,
      'can_merge',true,'can_convert',true
    ),
    'generated_at',now()
  );
end;
$fn$;

create or replace function public.get_my_intake_requests()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'ok',true,
    'requests',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',r.id,'request_no',r.request_no,'tracking_code',r.tracking_code,
        'source_type',r.source_type,'request_type',r.request_type,
        'title',r.title,'detail',r.detail,'status',r.status,
        'priority_score',r.priority_score,'sla_due_at',r.sla_due_at,
        'resolved_at',r.resolved_at,'converted_kind',r.converted_kind,
        'created_at',r.created_at,
        'messages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'body',m.body,'created_at',m.created_at,
            'author_label',m.author_label
          ) order by m.created_at)
          from public.intake_messages m
          where m.request_id=r.id and m.visibility='public'
        ),'[]'::jsonb)
      ) order by r.created_at desc),'[]'::jsonb)
      from (
        select * from public.intake_requests
        where requester_profile_id=v_uid or owner_profile_id=v_uid
        order by created_at desc limit 200
      ) r
    )
  );
end;
$fn$;

create or replace function public.get_public_intake_form(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_row record;
begin
  select f.id,f.name,f.allowed_types,f.enterprise_id,e.name enterprise_name
    into v_row
    from public.intake_forms f
    join public.enterprises e on e.id=f.enterprise_id
   where f.public_token=btrim(coalesce(p_token,'')) and f.active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_form','error','form not available');
  end if;
  return jsonb_build_object(
    'ok',true,'form_id',v_row.id,'form_name',v_row.name,
    'enterprise_name',v_row.enterprise_name,
    'allowed_types',v_row.allowed_types
  );
end;
$fn$;

-- ---------------------------------------------------------- quick/public intake
create or replace function public.create_intake_request(p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_detail text:=btrim(coalesce(v_data->>'detail',''));
  v_type text:=public._intake_type(v_data->>'request_type');
  v_source text:=lower(btrim(coalesce(v_data->>'source_type','quick')));
  v_priority jsonb:=public._intake_priority(v_data);
  v_score numeric;
  v_override numeric;
  v_reason text:=btrim(coalesce(v_data->>'priority_override_reason',''));
  v_row public.intake_requests%rowtype;
  v_name text;
  v_duplicates jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_is_member(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_request','active enterprise membership required');
  end if;
  if v_title='' or length(v_detail)<5 then
    raise exception 'title and detail are required';
  end if;
  if v_source not in ('quick','internal','wechat') then v_source:='quick'; end if;
  select coalesce(name,code,'Member') into v_name from public.profiles where id=v_uid;
  v_score:=coalesce((v_priority->>'score')::numeric,0);
  if v_data ? 'priority_override' and nullif(btrim(v_data->>'priority_override'),'') is not null then
    if not public._intake_can_manage(v_eid,v_uid) then
      return public._intake_denied(v_eid,v_uid,'create_intake_request','priority override requires management authority');
    end if;
    if v_reason='' then raise exception 'priority override reason required'; end if;
    v_override:=public._intake_safe_number(v_data->>'priority_override',v_score,0,100);
    v_score:=v_override;
  end if;
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_profile_id,requester_name,tracking_code,
    priority_score,priority_factors,priority_override,priority_override_reason,
    sla_due_at,status,source_ref
  ) values(
    v_eid,v_source,v_type,v_title,v_detail,
    v_uid,coalesce(v_name,'Member'),public._intake_tracking_code(),
    v_score,v_priority->'factors',v_override,v_reason,
    now()+public._intake_sla_interval(v_type),'submitted',
    btrim(coalesce(v_data->>'source_ref',''))
  ) returning * into v_row;
  perform public._intake_event(v_row.id,v_uid,'request.created','','submitted',
    jsonb_build_object('source_type',v_source));
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    v_row.id,v_uid,'System','public','Your request has been received and is waiting for triage.'
  );
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',x.id,'request_no',x.request_no,'title',x.title,
    'similarity',x.similarity
  ) order by x.similarity desc),'[]'::jsonb)
    into v_duplicates
    from (
      select r.id,r.request_no,r.title,
        public._intake_similarity(v_title||' '||v_detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_eid and r.id<>v_row.id
       order by r.created_at desc limit 200
    ) x
    where x.similarity>=0.35
    limit 5;
  perform public._intake_success(
    v_eid,v_uid,'intake_request',v_row.id,'request.created','{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('duplicate_count',jsonb_array_length(v_duplicates))
  );
  return jsonb_build_object(
    'ok',true,'request_id',v_row.id,'request_no',v_row.request_no,
    'tracking_code',v_row.tracking_code,'sla_due_at',v_row.sla_due_at,
    'priority',v_priority,'duplicates',v_duplicates
  );
end;
$fn$;

create or replace function public.submit_public_intake(p_token text,p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_form public.intake_forms%rowtype;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_type text:=public._intake_type(v_data->>'request_type');
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_detail text:=btrim(coalesce(v_data->>'detail',''));
  v_name text:=btrim(coalesce(v_data->>'requester_name',''));
  v_email text:=lower(btrim(coalesce(v_data->>'requester_email','')));
  v_consent boolean:=coalesce((v_data->>'consent')::boolean,false);
  v_priority jsonb:=public._intake_priority(v_data);
  v_row public.intake_requests%rowtype;
  v_count integer;
  v_hash text;
  v_duplicate_count integer;
begin
  select * into v_form from public.intake_forms
   where public_token=btrim(coalesce(p_token,'')) and active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_form','error','form not available');
  end if;
  if v_title='' or length(v_detail)<5 or v_name=''
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or not v_consent then
    return jsonb_build_object('ok',false,'code','invalid_input','error','valid contact, consent, title, and detail are required');
  end if;
  if cardinality(v_form.allowed_types)>0 and not (v_type=any(v_form.allowed_types)) then
    return jsonb_build_object('ok',false,'code','invalid_type','error','request type is not allowed on this form');
  end if;
  v_hash:=md5(v_email);
  select count(*) into v_count
    from public.intake_submission_attempts a
   where a.form_id=v_form.id and a.email_hash=v_hash
     and a.created_at>now()-interval '10 minutes';
  if v_count>=5 then
    insert into public.intake_security_audit(
      enterprise_id,actor_profile_id,operation,reason,payload
    ) values(v_form.enterprise_id,null,'submit_public_intake','rate limit',
      jsonb_build_object('form_id',v_form.id,'email_hash',v_hash));
    return jsonb_build_object('ok',false,'code','rate_limited','error','too many submissions; try again later');
  end if;
  insert into public.intake_submission_attempts(form_id,email_hash)
    values(v_form.id,v_hash);
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_name,requester_email,tracking_code,form_id,
    priority_score,priority_factors,sla_due_at,status
  ) values(
    v_form.enterprise_id,'public_form',v_type,v_title,v_detail,
    v_name,v_email,public._intake_tracking_code(),v_form.id,
    coalesce((v_priority->>'score')::numeric,0),v_priority->'factors',
    now()+public._intake_sla_interval(v_type),'submitted'
  ) returning * into v_row;
  perform public._intake_event(v_row.id,null,'request.created','','submitted',
    jsonb_build_object('source_type','public_form'));
  insert into public.intake_messages(
    request_id,author_label,visibility,body
  ) values(v_row.id,'System','public','Your request has been received and is waiting for triage.');
  perform public._intake_notify(
    v_row.id,'receipt','Request received',
    'Your request was received. Keep the tracking code and email address for status lookup.'
  );
  select count(*) into v_duplicate_count
    from (
      select public._intake_similarity(v_title||' '||v_detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_form.enterprise_id and r.id<>v_row.id
       order by r.created_at desc limit 200
    ) x where x.similarity>=0.35;
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'sla_due_at',v_row.sla_due_at,'duplicate_count',v_duplicate_count,
    'message','Submission received'
  );
end;
$fn$;

create or replace function public.get_public_intake_status(
  p_tracking_code text,p_email text
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_row public.intake_requests%rowtype;
  v_messages jsonb;
begin
  select * into v_row from public.intake_requests
   where tracking_code=upper(btrim(coalesce(p_tracking_code,'')))
     and requester_email<>''
     and lower(btrim(requester_email))=lower(btrim(coalesce(p_email,'')));
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','error','request not found');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'body',m.body,'created_at',m.created_at,'author_label',m.author_label
  ) order by m.created_at),'[]'::jsonb)
    into v_messages
    from public.intake_messages m
   where m.request_id=v_row.id and m.visibility='public';
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'request_type',v_row.request_type,'title',v_row.title,'status',v_row.status,
    'created_at',v_row.created_at,'sla_due_at',v_row.sla_due_at,
    'resolved_at',v_row.resolved_at,'messages',v_messages
  );
end;
$fn$;

create or replace function public.ingest_intake_email(
  p_alias_token text,p_from text,p_subject text,p_body text,
  p_request_type text default 'customer'
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_alias public.intake_email_aliases%rowtype;
  v_type text:=public._intake_type(p_request_type);
  v_from text:=lower(btrim(coalesce(p_from,'')));
  v_subject text:=btrim(coalesce(p_subject,''));
  v_body text:=btrim(coalesce(p_body,''));
  v_hash text;
  v_count integer;
  v_row public.intake_requests%rowtype;
  v_priority jsonb:=public._intake_priority('{}'::jsonb);
begin
  select * into v_alias from public.intake_email_aliases
   where alias_token=btrim(coalesce(p_alias_token,'')) and active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_alias','error','email alias not available');
  end if;
  if v_from !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or v_subject='' or length(v_body)<5 then
    return jsonb_build_object('ok',false,'code','invalid_input','error','sender, subject, and body are required');
  end if;
  v_hash:=md5(btrim(coalesce(p_alias_token,''))||v_from);
  select count(*) into v_count from public.intake_submission_attempts a
   where a.form_id is null and a.email_hash=v_hash
     and a.created_at>now()-interval '10 minutes';
  if v_count>=10 then
    return jsonb_build_object('ok',false,'code','rate_limited','error','too many messages');
  end if;
  insert into public.intake_submission_attempts(form_id,email_hash)
    values(null,v_hash);
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_name,requester_email,tracking_code,
    priority_score,priority_factors,sla_due_at,status,source_ref
  ) values(
    v_alias.enterprise_id,'email',v_type,v_subject,v_body,
    split_part(v_from,'@',1),v_from,public._intake_tracking_code(),
    coalesce((v_priority->>'score')::numeric,0),v_priority->'factors',
    now()+public._intake_sla_interval(v_type),'submitted',v_alias.email_address
  ) returning * into v_row;
  perform public._intake_event(v_row.id,null,'request.created','','submitted',
    jsonb_build_object('source_type','email','alias',v_alias.email_address));
  insert into public.intake_messages(
    request_id,author_label,visibility,body
  ) values(v_row.id,'System','public','Your email was received and is waiting for triage.');
  perform public._intake_notify(
    v_row.id,'receipt','Email request received',
    'Your email was received. Keep the tracking code and email address for status lookup.'
  );
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'sla_due_at',v_row.sla_due_at
  );
end;
$fn$;

-- ---------------------------------------------------------- triage and messages
create or replace function public.triage_intake_request(
  p_request uuid,
  p_owner uuid default null,
  p_request_type text default null,
  p_priority_override numeric default null,
  p_reason text default '',
  p_status text default 'triage'
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_before jsonb;
  v_type text;
  v_status text:=lower(btrim(coalesce(p_status,'triage')));
  v_score numeric;
  v_reason text:=btrim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'triage_intake_request','projects.manage authority required');
  end if;
  if v_row.status='merged' then raise exception 'merged requests cannot be triaged'; end if;
  if v_status not in ('triage','in_progress','resolved','closed') then
    raise exception 'invalid triage status';
  end if;
  if p_owner is not null and not public._intake_is_member(v_row.enterprise_id,p_owner) then
    raise exception 'owner must be an active enterprise member';
  end if;
  if p_priority_override is not null and v_reason='' then
    raise exception 'priority override reason required';
  end if;
  if p_request_type is not null then
    v_type:=public._intake_type(p_request_type);
  else
    v_type:=v_row.request_type;
  end if;
  v_score:=case when p_priority_override is null then v_row.priority_score
    else public._intake_safe_number(p_priority_override::text,v_row.priority_score,0,100) end;
  v_before:=to_jsonb(v_row);
  update public.intake_requests set
    status=v_status,
    owner_profile_id=coalesce(p_owner,owner_profile_id),
    request_type=v_type,
    priority_score=v_score,
    priority_override=case when p_priority_override is null then priority_override else v_score end,
    priority_override_reason=case when p_priority_override is null then priority_override_reason else v_reason end,
    first_response_at=coalesce(first_response_at,now()),
    resolved_at=case when v_status in ('resolved','closed') then coalesce(resolved_at,now()) else resolved_at end,
    sla_due_at=case when p_request_type is null then sla_due_at
      else created_at+public._intake_sla_interval(v_type) end,
    version=version+1,
    updated_at=now()
  where id=p_request returning * into v_row;
  perform public._intake_event(
    p_request,v_uid,'request.triaged',v_before->>'status',v_status,
    jsonb_build_object('owner_profile_id',v_row.owner_profile_id,
      'request_type',v_row.request_type,'priority_score',v_score)
  );
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) select v_row.id,v_uid,coalesce(p.name,'Coordinator'),'public',
    'Request triaged. Current status: '||v_status||'.'
    from public.profiles p where p.id=v_uid;
  perform public._intake_notify(
    p_request,'status','Request status updated',
    'Your request status is now '||v_status||'.'
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'request.triaged',
    v_before,to_jsonb(v_row),jsonb_build_object('reason',v_reason)
  );
  return jsonb_build_object(
    'ok',true,'request_id',v_row.id,'status',v_row.status,
    'owner_profile_id',v_row.owner_profile_id,
    'request_type',v_row.request_type,'priority_score',v_row.priority_score
  );
end;
$fn$;

create or replace function public.add_intake_message(
  p_request uuid,p_body text,p_public boolean default true
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_body text:=btrim(coalesce(p_body,''));
  v_name text;
  v_manager boolean;
  v_requester boolean;
  v_visibility text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  v_manager:=public._intake_can_manage(v_row.enterprise_id,v_uid);
  v_requester:=v_row.requester_profile_id=v_uid;
  if not v_manager and not v_requester then
    return public._intake_denied(v_row.enterprise_id,v_uid,'add_intake_message','requester or manager authority required');
  end if;
  if v_body='' or length(v_body)>8000 then raise exception 'message is empty or too long'; end if;
  if p_public and length(v_body)>4000 then raise exception 'public message is too long'; end if;
  if not v_manager and not p_public then
    return public._intake_denied(v_row.enterprise_id,v_uid,'add_intake_message','only managers can add internal notes');
  end if;
  if v_row.status in ('closed','merged') then raise exception 'request is closed'; end if;
  v_visibility:=case when p_public then 'public' else 'internal' end;
  select coalesce(name,code,'Member') into v_name from public.profiles where id=v_uid;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(p_request,v_uid,coalesce(v_name,'Member'),v_visibility,v_body);
  if v_manager and v_visibility='public' then
    update public.intake_requests set
      first_response_at=coalesce(first_response_at,now()),version=version+1,updated_at=now()
    where id=p_request;
    perform public._intake_notify(
      p_request,'message','New reply to your request',v_body
    );
  end if;
  perform public._intake_event(
    p_request,v_uid,'message.'||v_visibility,'','',
    jsonb_build_object('body_length',length(v_body))
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'message.'||v_visibility,
    '{}'::jsonb,jsonb_build_object('visibility',v_visibility,'body',v_body)
  );
  return jsonb_build_object('ok',true,'request_id',p_request,'visibility',v_visibility);
end;
$fn$;

create or replace function public.find_intake_duplicates(
  p_request uuid,p_limit integer default 5
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_limit integer:=least(greatest(coalesce(p_limit,5),1),20);
begin
  select * into v_row from public.intake_requests where id=p_request;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'find_intake_duplicates','projects.manage authority required');
  end if;
  return jsonb_build_object('ok',true,'duplicates',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',x.id,'request_no',x.request_no,'title',x.title,
      'status',x.status,'similarity',x.similarity
    ) order by x.similarity desc),'[]'::jsonb)
    from (
      select r.id,r.request_no,r.title,r.status,
        public._intake_similarity(v_row.title||' '||v_row.detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_row.enterprise_id and r.id<>v_row.id
         and r.status<>'merged'
       order by r.created_at desc limit 200
    ) x where x.similarity>=0.3 order by x.similarity desc limit v_limit
  ));
end;
$fn$;

create or replace function public.merge_intake_request(
  p_source uuid,p_target uuid,p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_source public.intake_requests%rowtype;
  v_target public.intake_requests%rowtype;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_source=p_target then raise exception 'cannot merge a request into itself'; end if;
  select * into v_source from public.intake_requests where id=p_source for update;
  if not found then raise exception 'source request not found'; end if;
  select * into v_target from public.intake_requests where id=p_target for update;
  if not found then raise exception 'target request not found'; end if;
  if v_source.enterprise_id<>v_target.enterprise_id then raise exception 'requests must belong to the same enterprise'; end if;
  if not public._intake_can_manage(v_source.enterprise_id,v_uid) then
    return public._intake_denied(v_source.enterprise_id,v_uid,'merge_intake_request','projects.manage authority required');
  end if;
  if v_source.status='merged' then raise exception 'source request is already merged'; end if;
  if v_target.status='merged' then raise exception 'target request is merged'; end if;
  v_before:=to_jsonb(v_source);
  insert into public.intake_links(request_id,linked_request_id,link_type,note,created_by)
    values(p_source,p_target,'duplicate',btrim(coalesce(p_note,'')),v_uid)
    on conflict (request_id,linked_request_id,link_type) do nothing;
  insert into public.intake_links(request_id,linked_request_id,link_type,note,created_by)
    values(p_target,p_source,'related',btrim(coalesce(p_note,'')),v_uid)
    on conflict (request_id,linked_request_id,link_type) do nothing;
  insert into public.intake_messages(
    request_id,source_request_id,author_profile_id,author_label,visibility,body,created_at
  )
  select p_target,p_source,m.author_profile_id,m.author_label,m.visibility,m.body,m.created_at
    from public.intake_messages m where m.request_id=p_source;
  update public.intake_requests set
    status='merged',merged_into_id=p_target,version=version+1,updated_at=now()
  where id=p_source;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_target,v_uid,'System','internal',
    'Merged source '||v_source.request_no||'. '||btrim(coalesce(p_note,''))
  );
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_source,v_uid,'System','public',
    'This request was merged into '||v_target.request_no||'.'
  );
  perform public._intake_event(
    p_source,v_uid,'request.merged',v_source.status,'merged',
    jsonb_build_object('target_request_id',p_target,'target_request_no',v_target.request_no)
  );
  perform public._intake_notify(
    p_source,'merged','Request merged',
    'Your request was merged into '||v_target.request_no||'.'
  );
  perform public._intake_success(
    v_source.enterprise_id,v_uid,'intake_request',p_source,'request.merged',
    v_before,to_jsonb(v_target),jsonb_build_object('target_request_id',p_target)
  );
  return jsonb_build_object(
    'ok',true,'source_id',p_source,'target_id',p_target,
    'target_request_no',v_target.request_no
  );
end;
$fn$;

-- ---------------------------------------------------------- conversion
create or replace function public.convert_intake_request(
  p_request uuid,p_kind text,p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_before jsonb;
  v_kind text:=lower(btrim(coalesce(p_kind,'')));
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_project uuid;
  v_task uuid;
  v_presales uuid;
  v_employee uuid;
  v_project_boss uuid;
  v_project_name text;
  v_conversion uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'convert_intake_request','projects.manage authority required');
  end if;
  if v_row.status in ('merged','closed') then raise exception 'request cannot be converted'; end if;
  if v_kind not in ('project','task','presales') then
    raise exception 'conversion kind must be project, task, or presales';
  end if;
  v_before:=to_jsonb(v_row);
  if v_kind='project' then
    if btrim(coalesce(v_data->>'name',''))='' then raise exception 'project name required'; end if;
    insert into public.projects(
      boss_id,name,owner,client,status,priority,start_date,due_date,
      budget,cost,progress,note
    ) values(
      v_uid,btrim(v_data->>'name'),coalesce(v_data->>'owner',''),
      coalesce(v_data->>'client',''),coalesce(v_data->>'status',U&'\8FDB\884C\4E2D'),
      coalesce(v_data->>'priority',U&'\4E2D'),
      nullif(v_data->>'start_date','')::date,
      nullif(v_data->>'due_date','')::date,
      coalesce((v_data->>'budget')::numeric,0),
      coalesce((v_data->>'cost')::numeric,0),0,
      coalesce(v_data->>'note',v_row.detail)
    ) returning id into v_project;
  elsif v_kind='task' then
    if btrim(coalesce(v_data->>'title',''))='' or not (v_data ? 'project_id')
       or not (v_data ? 'employee_id') or nullif(v_data->>'plan_date','') is null then
      raise exception 'task title, project, employee, and plan date are required';
    end if;
    select p.id,p.boss_id,p.name into v_project,v_project_boss,v_project_name
      from public.projects p where p.id=(v_data->>'project_id')::uuid;
    if v_project is null or not (
      exists(select 1 from public.enterprises e where e.id=v_row.enterprise_id and e.owner_profile_id=v_project_boss)
      or public._intake_is_member(v_row.enterprise_id,v_project_boss)
    ) then raise exception 'project does not belong to the enterprise'; end if;
    v_employee:=(v_data->>'employee_id')::uuid;
    if not public._intake_is_member(v_row.enterprise_id,v_employee) then
      raise exception 'employee is not an active enterprise member';
    end if;
    insert into public.tasks(
      boss_id,employee_id,title,detail,plan_date,est_hours,
      project_id,project_name,step_name,accept_status
    ) values(
      v_project_boss,v_employee,btrim(v_data->>'title'),
      coalesce(nullif(v_data->>'detail',''),v_row.detail),
      (v_data->>'plan_date')::date,
      greatest(coalesce((v_data->>'est_hours')::numeric,0),0),
      v_project,coalesce(v_project_name,''),coalesce(v_data->>'step_name',''),'pending'
    ) returning id into v_task;
  else
    if not (v_data ? 'owner_id') then raise exception 'presales owner required'; end if;
    v_employee:=(v_data->>'owner_id')::uuid;
    if not public._intake_is_member(v_row.enterprise_id,v_employee) then
      raise exception 'presales owner is not an active enterprise member';
    end if;
    insert into public.presales_opportunities(
      enterprise_id,request_id,title,customer_name,estimated_value,owner_profile_id,stage
    ) values(
      v_row.enterprise_id,p_request,v_row.title,
      coalesce(v_data->>'customer_name',''),
      greatest(coalesce((v_data->>'estimated_value')::numeric,0),0),
      v_employee,coalesce(v_data->>'stage','qualified')
    ) returning id into v_presales;
  end if;
  insert into public.intake_conversions(
    request_id,kind,linked_id,payload,created_by
  ) values(
    p_request,v_kind,
    case v_kind when 'project' then v_project
      when 'task' then v_task else v_presales end,
    v_data,v_uid
  ) returning id into v_conversion;
  update public.intake_requests set
    status='in_progress',
    converted_kind=v_kind,
    converted_at=now(),
    linked_project_id=case when v_kind='project' then v_project else linked_project_id end,
    linked_task_id=case when v_kind='task' then v_task else linked_task_id end,
    presales_owner_id=case when v_kind='presales' then v_employee else presales_owner_id end,
    owner_profile_id=coalesce(owner_profile_id,v_uid),
    first_response_at=coalesce(first_response_at,now()),
    version=version+1,
    updated_at=now()
  where id=p_request returning * into v_row;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_request,v_uid,'System','public',
    'This request has been converted to '||v_kind||' and is now in progress.'
  );
  perform public._intake_event(
    p_request,v_uid,'request.converted','in_progress','in_progress',
    jsonb_build_object('kind',v_kind,'project_id',v_project,
      'task_id',v_task,'presales_id',v_presales)
  );
  perform public._intake_notify(
    p_request,'converted','Request converted',
    'Your request has been converted to '||v_kind||' and is now in progress.'
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'conversion.'||v_kind,
    v_before,to_jsonb(v_row),
    jsonb_build_object('project_id',v_project,'task_id',v_task,'presales_id',v_presales)
  );
  return jsonb_build_object(
    'ok',true,'request_id',p_request,'kind',v_kind,
    'project_id',v_project,'task_id',v_task,'presales_id',v_presales,
    'conversion_id',v_conversion,'status',v_row.status
  );
end;
$fn$;

-- ---------------------------------------------------------- settings and aliases
create or replace function public.upsert_intake_settings(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_row public.intake_settings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'upsert_intake_settings','projects.manage authority required');
  end if;
  insert into public.intake_settings(enterprise_id,email_domain,public_form_base_url,updated_by)
  values(
    v_eid,coalesce(nullif(btrim(p_data->>'email_domain'),''),'inbound.projectrecorder.local'),
    btrim(coalesce(p_data->>'public_form_base_url','')),v_uid
  )
  on conflict (enterprise_id) do update set
    email_domain=coalesce(nullif(btrim(excluded.email_domain),''),public.intake_settings.email_domain),
    public_form_base_url=excluded.public_form_base_url,
    updated_by=excluded.updated_by,
    updated_at=now()
  returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_settings',v_eid,'settings.updated','{}'::jsonb,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'settings',to_jsonb(v_row));
end;
$fn$;

create or replace function public.create_intake_email_alias(p_label text default '')
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_settings public.intake_settings%rowtype;
  v_token text;
  v_domain text;
  v_address text;
  v_row public.intake_email_aliases%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_email_alias','projects.manage authority required');
  end if;
  select * into v_settings from public.intake_settings where enterprise_id=v_eid;
  v_domain:=coalesce(nullif(v_settings.email_domain,''),'inbound.projectrecorder.local');
  loop
    v_token:=substr(public._intake_public_token(),1,16);
    exit when not exists(select 1 from public.intake_email_aliases a where a.alias_token=v_token);
  end loop;
  v_address:='intake+'||v_token||'@'||v_domain;
  insert into public.intake_email_aliases(
    enterprise_id,label,alias_token,email_address,created_by
  ) values(v_eid,btrim(coalesce(p_label,'')),v_token,v_address,v_uid)
  returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_email_alias',v_row.id,'alias.created','{}'::jsonb,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'alias',to_jsonb(v_row));
end;
$fn$;

create or replace function public.intake_escalate_sla(p_enterprise uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=coalesce(p_enterprise,public._intake_current_enterprise(auth.uid()));
  v_count integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'intake_escalate_sla','projects.manage authority required');
  end if;
  v_count:=public._intake_escalate_due(v_eid);
  return jsonb_build_object('ok',true,'escalated',v_count);
end;
$fn$;

-- ---------------------------------------------------------- privileges
revoke all on function public._intake_current_enterprise(uuid) from public, anon, authenticated;
revoke all on function public._intake_is_member(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_has_permission(uuid,uuid,text[]) from public, anon, authenticated;
revoke all on function public._intake_can_manage(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_is_executive(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_safe_number(text,numeric,numeric,numeric) from public, anon, authenticated;
revoke all on function public._intake_type(text) from public, anon, authenticated;
revoke all on function public._intake_sla_interval(text) from public, anon, authenticated;
revoke all on function public._intake_priority(jsonb) from public, anon, authenticated;
revoke all on function public._intake_tracking_code() from public, anon, authenticated;
revoke all on function public._intake_public_token() from public, anon, authenticated;
revoke all on function public._intake_similarity(text,text) from public, anon, authenticated;
revoke all on function public._intake_denied(uuid,uuid,text,text,jsonb) from public, anon, authenticated;
revoke all on function public._intake_success(uuid,uuid,text,uuid,text,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public._intake_event(uuid,uuid,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public._intake_notify(uuid,text,text,text) from public, anon, authenticated;
revoke all on function public._intake_escalate_due(uuid) from public, anon, authenticated;

revoke all on function public.create_intake_form(jsonb) from public, anon, authenticated;
revoke all on function public.update_intake_form(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.get_intake_board(uuid) from public, anon, authenticated;
revoke all on function public.get_my_intake_requests() from public, anon, authenticated;
revoke all on function public.create_intake_request(jsonb) from public, anon, authenticated;
revoke all on function public.submit_public_intake(text,jsonb) from public, anon, authenticated;
revoke all on function public.get_public_intake_form(text) from public, anon, authenticated;
revoke all on function public.get_public_intake_status(text,text) from public, anon, authenticated;
revoke all on function public.ingest_intake_email(text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.triage_intake_request(uuid,uuid,text,numeric,text,text) from public, anon, authenticated;
revoke all on function public.add_intake_message(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.find_intake_duplicates(uuid,integer) from public, anon, authenticated;
revoke all on function public.merge_intake_request(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.convert_intake_request(uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.upsert_intake_settings(jsonb) from public, anon, authenticated;
revoke all on function public.create_intake_email_alias(text) from public, anon, authenticated;
revoke all on function public.intake_escalate_sla(uuid) from public, anon, authenticated;

grant execute on function public.create_intake_form(jsonb) to authenticated;
grant execute on function public.update_intake_form(uuid,jsonb) to authenticated;
grant execute on function public.get_intake_board(uuid) to authenticated;
grant execute on function public.get_my_intake_requests() to authenticated;
grant execute on function public.create_intake_request(jsonb) to authenticated;
grant execute on function public.triage_intake_request(uuid,uuid,text,numeric,text,text) to authenticated;
grant execute on function public.add_intake_message(uuid,text,boolean) to authenticated;
grant execute on function public.find_intake_duplicates(uuid,integer) to authenticated;
grant execute on function public.merge_intake_request(uuid,uuid,text) to authenticated;
grant execute on function public.convert_intake_request(uuid,text,jsonb) to authenticated;
grant execute on function public.upsert_intake_settings(jsonb) to authenticated;
grant execute on function public.create_intake_email_alias(text) to authenticated;
grant execute on function public.intake_escalate_sla(uuid) to authenticated;

grant execute on function public.submit_public_intake(text,jsonb) to anon, authenticated;
grant execute on function public.get_public_intake_form(text) to anon, authenticated;
grant execute on function public.get_public_intake_status(text,text) to anon, authenticated;
grant execute on function public.ingest_intake_email(text,text,text,text,text) to anon, authenticated;

-- Source rows are never deleted; merge preserves all source messages and links.
-- Internal notes are stored as internal messages; internal_note is never public.
-- The outbound mail worker sets Reply-To from the request alias.

  end if;
end;
$intake_installer$;


-- Phase 5: shareholder meetings
-- Canonical source: mobile/sql/shareholder-meetings-v1.sql
-- Applies after enterprise identity and governance are installed. Re-running is safe.
do $meeting_installer$
begin
  if to_regclass('public.enterprises') is null
     or to_regclass('public.enterprise_shareholders') is null
     or to_regclass('public.enterprise_members') is null
     or to_regclass('public.enterprise_identity_audit') is null
     or to_regprocedure('public._identity_shares(uuid,uuid)') is null
     or to_regprocedure('public._identity_role_permissions(uuid,uuid)') is null then
    raise notice 'Shareholder meetings skipped: run enterprise identity and governance migrations first.';
  else
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

  end if;
end;
$meeting_installer$;
