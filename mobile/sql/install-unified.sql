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
  if not found or v_task.boss_id is distinct from v_uid then raise exception 'not your task'; end if;
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
-- Phase 2B: operations economics, skills, worklog dimensions,
-- and performance evidence.
--
-- Canonical source: mobile/sql/operations-economics-v1.sql
-- This guarded block applies only after Phase 2A and its base tables
-- exist. Re-running the unified installer is safe.
-- ============================================================
do $operations_installer$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.projects') is null
     or to_regclass('public.worklogs') is null
     or to_regclass('public.enterprises') is null
     or to_regclass('public.enterprise_identity_audit') is null
     or to_regclass('public.decision_items') is null then
    raise notice 'Phase 2B skipped: run Phase 1, task extension, and decision approval migrations first.';
    return;
  end if;

  execute $operations_phase2b$
-- ============================================================
-- Project Recorder - Phase 2B operations economics
--
-- Deployment order:
--   enterprise-identity.sql
--   community.sql
--   enterprise-governance-v2.sql
--   unified-platform.sql
--   task-accept-extension.sql
--   decision-approvals-v1.sql
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
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

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

-- ------------------------------------------------------------ RLS / least privilege
alter table public.project_economics enable row level security;
alter table public.profile_skills enable row level security;
alter table public.capacity_demands enable row level security;
alter table public.performance_evidence enable row level security;
alter table public.worklog_dimensions enable row level security;

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
  p_collaboration numeric
) returns numeric
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select round(least(greatest(
    least(greatest(coalesce(p_on_time,0),0),1)*35
    +least(greatest(coalesce(p_first_pass,0),0),1)*30
    +(1-least(greatest(coalesce(p_rework,0),0),1))*20
    +least(greatest(coalesce(p_collaboration,0),0),5)/5*15,
    0),100),1);
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

revoke all on function public._operations_number(jsonb,text,numeric)
  from public;
revoke all on function public._operations_number(jsonb,text,numeric)
  from anon;
revoke all on function public._operations_number(jsonb,text,numeric)
  from authenticated;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from public;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from anon;
revoke all on function public._operations_assert_nonnegative(jsonb,text[])
  from authenticated;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from public;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from anon;
revoke all on function public._operations_has_permission(uuid,uuid,text[])
  from authenticated;
revoke all on function public._operations_has_management(uuid,uuid)
  from public;
revoke all on function public._operations_has_management(uuid,uuid)
  from anon;
revoke all on function public._operations_has_management(uuid,uuid)
  from authenticated;
revoke all on function public._operations_project_enterprise(uuid)
  from public;
revoke all on function public._operations_project_enterprise(uuid)
  from anon;
revoke all on function public._operations_project_enterprise(uuid)
  from authenticated;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from public;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from anon;
revoke all on function public._operations_performance_score(numeric,numeric,numeric,numeric)
  from authenticated;
revoke all on function public._operations_validate_project_economics()
  from public;
revoke all on function public._operations_validate_project_economics()
  from anon;
revoke all on function public._operations_validate_project_economics()
  from authenticated;
revoke all on function public._operations_worklog_defaults()
  from public;
revoke all on function public._operations_worklog_defaults()
  from anon;
revoke all on function public._operations_worklog_defaults()
  from authenticated;
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  v_project_eid:=public._operations_project_enterprise(p_project);
  if v_project_eid is null then raise exception 'project not found'; end if;
  if v_project_eid<>v_eid then raise exception 'project not in enterprise'; end if;
  if not public._operations_has_permission(
    v_eid,v_uid,array['finance.manage','projects.manage']::text[]
  ) then
    raise exception 'finance or project management permission required';
  end if;

  perform public._operations_assert_nonnegative(
    v_data,
    array[
      'contract_amount','invoiced_amount','collected_amount',
      'outsourced_committed','outsourced_paid','labor_cost',
      'estimated_completion_cost','other_cost'
    ]::text[]
  );

  insert into public.project_economics as pe(
    project_id,enterprise_id,contract_amount,invoiced_amount,collected_amount,
    outsourced_committed,outsourced_paid,labor_cost,
    estimated_completion_cost,other_cost,updated_by,updated_at
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
      'labor_cost',v_row.labor_cost,
      'estimated_completion_cost',v_row.estimated_completion_cost
    )
  );

  return to_jsonb(v_row)||jsonb_build_object(
    'projected_completion_cost',v_projected,
    'projected_margin',v_row.contract_amount-v_projected,
    'projected_margin_percent',case when v_row.contract_amount>0
      then round((v_row.contract_amount-v_projected)/v_row.contract_amount*100,2)
      else 0 end,
    'collection_gap',greatest(v_row.contract_amount-v_row.collected_amount,0),
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
  if v_uid<>p_profile and not public._operations_has_permission(
    v_eid,v_uid,array['people.manage','company.manage']::text[]
  ) then
    raise exception 'people management permission required';
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
      'skill',v_row.skill,'level',v_row.level,
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
  v_id uuid:=p_demand;
  v_skill text:=btrim(coalesce(v_data->>'skill',''));
  v_required numeric:=public._operations_number(v_data,'required_hours');
  v_from date:=coalesce(nullif(v_data->>'needed_from','')::date,current_date);
  v_until date:=coalesce(nullif(v_data->>'needed_until','')::date,current_date+28);
  v_project uuid:=nullif(v_data->>'project_id','')::uuid;
  v_owner uuid:=nullif(v_data->>'owner_profile_id','')::uuid;
  v_row public.capacity_demands%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_permission(
    v_eid,v_uid,array['projects.manage','people.manage','company.manage']::text[]
  ) then
    raise exception 'project or people management permission required';
  end if;
  if v_skill='' then raise exception 'skill required'; end if;
  if v_required<=0 then raise exception 'required_hours must be positive'; end if;
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
      'required_hours',v_row.required_hours,
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
  if v_uid<>v_worklog.employee_id and v_uid<>v_worklog.boss_id
     and not public._operations_has_permission(
       v_eid,v_uid,array['worklogs.approve','people.manage']::text[]
     ) then
    raise exception 'worklog permission required';
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
    raise exception 'performance review permission required';
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
  if jsonb_typeof(v_evidence) not in ('array','object') then
    raise exception 'evidence must be an array or object';
  end if;
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
    evidence,status,score,created_at,updated_at
  ) values(
    v_eid,p_profile,v_period,v_on_time,v_first_pass,v_rework,
    v_collaboration,v_complexity,v_contribution,v_evidence,'draft',0,now(),now()
  )
  on conflict (enterprise_id,profile_id,period) do update set
    on_time_rate=excluded.on_time_rate,
    first_pass_rate=excluded.first_pass_rate,
    rework_rate=excluded.rework_rate,
    collaboration_score=excluded.collaboration_score,
    complexity_score=excluded.complexity_score,
    business_contribution=excluded.business_contribution,
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
      'status',v_row.status,'evidence',v_row.evidence
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
              e.rework_rate,e.collaboration_score)
          end
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
    raise exception 'performance evidence belongs to another member';
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
      v_row.rework_rate,v_row.collaboration_score)
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
    raise exception 'performance review permission required';
  end if;
  if v_row.profile_id=v_uid then
    raise exception 'self-review is not allowed';
  end if;
  if v_note='' then raise exception 'review note required'; end if;
  if v_row.status='reviewed' then
    return to_jsonb(v_row)||jsonb_build_object('duplicate',true);
  end if;

  v_score:=public._operations_performance_score(
    v_row.on_time_rate,v_row.first_pass_rate,
    v_row.rework_rate,v_row.collaboration_score
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
      'score',v_score,'note',v_note
    )
  );
  return to_jsonb(v_row)||jsonb_build_object('duplicate',false);
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._operations_has_management(v_eid,v_uid) then
    raise exception 'management permission required';
  end if;
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;

  return jsonb_build_object(
    'enterprise_id',v_eid,
    'generated_at',now(),
    'management_only',true,
    'window_weeks',v_weeks,
    'period_start',v_start,
    'period_end',v_end,
    'projects',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'project_id',x.project_id,
        'name',x.name,
        'owner',x.owner,
        'status',x.status,
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
        'unpaid_invoice',greatest(x.invoiced_amount-x.collected_amount,0)
      ) order by x.name),'[]'::jsonb)
      from (
        select p.id project_id,p.name,p.owner,p.status,
          coalesce(pe.contract_amount,0) contract_amount,
          coalesce(pe.invoiced_amount,0) invoiced_amount,
          coalesce(pe.collected_amount,0) collected_amount,
          coalesce(pe.outsourced_committed,0) outsourced_committed,
          coalesce(pe.outsourced_paid,0) outsourced_paid,
          coalesce(pe.labor_cost,0) labor_cost,
          coalesce(pe.other_cost,0) other_cost,
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
      ) x
    ),
    'capacity_gaps',(
      with demand as (
        select d.skill,sum(d.required_hours) required_hours
        from public.capacity_demands d
        where d.enterprise_id=v_eid
          and d.needed_from<=v_end and d.needed_until>=v_start
        group by d.skill
      ),
      availability as (
        select ps.skill,
          sum(
            coalesce(ps.available_hours,0)
            * greatest(
                0,
                least(v_end,coalesce(ps.valid_until,v_end))
                -greatest(v_start,current_date)+1
              )/7.0
          ) available_hours
        from public.profile_skills ps
        join public.enterprise_members m
          on m.enterprise_id=ps.enterprise_id
         and m.profile_id=ps.profile_id
         and m.status='active'
        where ps.enterprise_id=v_eid
          and (ps.valid_until is null or ps.valid_until>=v_start)
        group by ps.skill
      ),
      skills as (
        select skill from demand
        union
        select skill from availability
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'skill',s.skill,
        'required_hours',coalesce(d.required_hours,0),
        'available_hours',round(coalesce(a.available_hours,0),2),
        'gap_hours',greatest(
          coalesce(d.required_hours,0)-coalesce(a.available_hours,0),0
        ),
        'period_start',v_start,
        'period_end',v_end,
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
      select coalesce(jsonb_agg(
        to_jsonb(e)||jsonb_build_object(
          'name',p.name,
          'score',case when e.status='reviewed' then e.score
            else public._operations_performance_score(
              e.on_time_rate,e.first_pass_rate,
              e.rework_rate,e.collaboration_score) end
        ) order by p.name,e.period desc
      ),'[]'::jsonb)
      from public.performance_evidence e
      join public.profiles p on p.id=e.profile_id
      where e.enterprise_id=v_eid
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
        where w.boss_id=v_owner
          and w.work_date between v_start and v_end
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
            select work_kind,sum(hours) hours
            from entries
            group by work_kind
          ) k
        ),'{}'::jsonb)
      )
      from entries
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
grant execute on function public.worklog_dimensions(uuid,jsonb) to authenticated;
grant execute on function public.upsert_performance_evidence(uuid,text,jsonb) to authenticated;
grant execute on function public.get_my_performance_evidence() to authenticated;
grant execute on function public.submit_performance_statement(uuid,text) to authenticated;
grant execute on function public.review_performance_evidence(uuid,text) to authenticated;
grant execute on function public.get_operations_dashboard(integer) to authenticated;
$operations_phase2b$;
end;
$operations_installer$;
