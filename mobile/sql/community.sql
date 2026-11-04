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

create index if not exists idx_community_posts_created
  on public.community_posts(created_at desc);
create index if not exists idx_community_posts_author
  on public.community_posts(author_id, created_at desc);

alter table public.community_posts enable row level security;

-- Direct reads are safe at the table boundary. Paid posts are visible only
-- to their author, required posts, and free posts here. The later governance
-- migration replaces this policy with an unlock-aware SECURITY DEFINER check.
create or replace function public._community_post_readable(
  p_post uuid,
  p_uid uuid
) returns boolean
language sql stable security definer
set search_path = public, auth, pg_temp
as $community_readable$
  select p_uid is not null
    and not (p_uid is distinct from auth.uid())
    and exists(
      select 1
        from public.community_posts p
       where p.id = p_post
         and (
           p.is_required
           or p.unlock_cost = 0
           or p.author_id = p_uid
         )
    );
$community_readable$;

revoke all on function public._community_post_readable(uuid, uuid) from public;
revoke all on function public._community_post_readable(uuid, uuid) from anon;
revoke all on function public._community_post_readable(uuid, uuid) from authenticated;
grant execute on function public._community_post_readable(uuid, uuid)
  to authenticated;

drop policy if exists "community posts readable by members"
  on public.community_posts;
create policy "community posts readable by members"
  on public.community_posts for select to authenticated
  using (public._community_post_readable(id,auth.uid()));
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
