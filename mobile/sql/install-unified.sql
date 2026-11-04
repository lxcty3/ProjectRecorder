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
