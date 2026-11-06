-- ============================================================
-- ProjectRecorder v2.1 community foundation
-- Additive and idempotent. ASCII-only.
-- ============================================================

create table if not exists public.community_boards (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid references public.enterprises(id) on delete cascade,
  slug text not null,
  name text not null,
  description text not null default '',
  icon text not null default '*',
  sort_order integer not null default 100,
  visibility text not null default 'public'
    check (visibility in ('public','restricted')),
  required_permissions text[] not null default '{}',
  allow_posts boolean not null default true,
  is_archived boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists community_boards_scope_slug_idx
  on public.community_boards(coalesce(enterprise_id,
    '00000000-0000-0000-0000-000000000000'::uuid), slug);
create index if not exists community_boards_scope_sort_idx
  on public.community_boards(enterprise_id, sort_order, created_at);

insert into public.community_boards(
  id, enterprise_id, slug, name, description, icon, sort_order, visibility
) values
  ('10000000-0000-4000-8000-000000000001', null, 'general',
   E'\u7efc\u5408\u8ba8\u8bba',
   E'\u6240\u6709\u6210\u5458\u90fd\u80fd\u53c2\u4e0e\u7684\u4e3b\u8ba8\u8bba\u533a',
   '*', 10, 'public'),
  ('10000000-0000-4000-8000-000000000002', null, 'announcements',
   E'\u516c\u544a', E'\u516c\u53f8\u4e0e\u56e2\u961f\u516c\u544a',
   '!', 20, 'public'),
  ('10000000-0000-4000-8000-000000000003', null, 'projects',
   E'\u9879\u76ee', E'\u9879\u76ee\u8fdb\u5c55\u3001\u98ce\u9669\u4e0e\u534f\u4f5c',
   '#', 30, 'public'),
  ('10000000-0000-4000-8000-000000000004', null, 'experience',
   E'\u7ecf\u9a8c', E'\u590d\u76d8\u3001\u65b9\u6cd5\u4e0e\u53ef\u590d\u7528\u77e5\u8bc6',
   '+', 40, 'public'),
  ('10000000-0000-4000-8000-000000000005', null, 'help',
   E'\u6c42\u52a9', E'\u9047\u5230\u95ee\u9898\u65f6\u53d1\u5e03\u6c42\u52a9',
   '?', 50, 'public'),
  ('10000000-0000-4000-8000-000000000006', null, 'featured',
   E'\u77e5\u8bc6\u7cbe\u9009', E'\u88ab\u7ba1\u7406\u5458\u9009\u4e2d\u7684\u9ad8\u4ef7\u503c\u5185\u5bb9',
   '^', 60, 'public')
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description,
  icon = excluded.icon,
  sort_order = excluded.sort_order;

alter table public.community_posts
  add column if not exists board_id uuid,
  add column if not exists pinned boolean not null default false,
  add column if not exists featured boolean not null default false,
  add column if not exists comment_count integer not null default 0,
  add column if not exists like_count integer not null default 0,
  add column if not exists last_activity_at timestamptz,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz;

update public.community_posts
   set board_id = '10000000-0000-4000-8000-000000000001'
 where board_id is null;
update public.community_posts
   set last_activity_at = created_at
 where last_activity_at is null;

alter table public.community_posts
  alter column board_id set default '10000000-0000-4000-8000-000000000001',
  alter column board_id set not null,
  alter column last_activity_at set default now();

do $do$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid='public.community_posts'::regclass
       and conname='community_posts_board_fk'
  ) then
    alter table public.community_posts
      add constraint community_posts_board_fk
      foreign key (board_id) references public.community_boards(id)
      on delete restrict;
  end if;
end;
$do$;

create index if not exists community_posts_board_activity_idx
  on public.community_posts(board_id, pinned desc, last_activity_at desc);
create index if not exists community_posts_search_idx
  on public.community_posts using gin (to_tsvector('simple', content));

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  parent_id uuid references public.community_comments(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  author_name text not null default '',
  author_role text not null default 'employee',
  body text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (char_length(body) between 1 and 4000)
);
create index if not exists community_comments_post_idx
  on public.community_comments(post_id, created_at);
create index if not exists community_comments_author_idx
  on public.community_comments(author_id, created_at desc);

create table if not exists public.community_reactions (
  post_id uuid not null references public.community_posts(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'like' check (kind in ('like')),
  created_at timestamptz not null default now(),
  primary key (post_id, profile_id, kind)
);

create table if not exists public.community_bookmarks (
  post_id uuid not null references public.community_posts(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, profile_id)
);

create table if not exists public.community_board_follows (
  board_id uuid not null references public.community_boards(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (board_id, profile_id)
);

create table if not exists public.community_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid references public.community_posts(id) on delete cascade,
  comment_id uuid references public.community_comments(id) on delete cascade,
  reporter_profile_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  detail text not null default '',
  status text not null default 'open'
    check (status in ('open','reviewing','resolved','dismissed')),
  resolved_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  check (post_id is not null or comment_id is not null)
);
create index if not exists community_reports_status_idx
  on public.community_reports(status, created_at desc);

create table if not exists public.community_notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  board_id uuid references public.community_boards(id) on delete cascade,
  post_id uuid references public.community_posts(id) on delete cascade,
  comment_id uuid references public.community_comments(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists community_notifications_member_idx
  on public.community_notifications(profile_id, read_at, created_at desc);

create or replace function public._community_can_manage(p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select p_uid is not null and p_uid=auth.uid()
    and (public.identity_has_permission('company.manage')
      or public.identity_has_permission('governance.manage'));
$fn$;

create or replace function public._community_can_view_board(p_board uuid,p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select p_uid is not null and p_uid=auth.uid() and exists(
    select 1 from public.community_boards b
     where b.id=p_board and not b.is_archived
       and (b.enterprise_id is null
         or public._identity_is_member(b.enterprise_id,p_uid))
       and (b.visibility='public'
         or cardinality(b.required_permissions)=0
         or exists(select 1 from unnest(b.required_permissions) permission
           where public.identity_has_permission(permission)))
  );
$fn$;

create or replace function public._community_can_post_board(p_board uuid,p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select public._community_can_view_board(p_board,p_uid)
    and exists(select 1 from public.community_boards b
      where b.id=p_board and b.allow_posts and not b.is_archived);
$fn$;

create or replace function public._community_post_unlocked(p_post uuid,p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select p_uid is not null and p_uid=auth.uid() and exists(
    select 1 from public.community_posts p
     where p.id=p_post and (
       p.is_required or p.unlock_cost=0 or p.author_id=p_uid
       or exists(select 1 from public.enterprise_knowledge_unlocks u
         where u.post_id=p.id and u.profile_id=p_uid)
     )
  );
$fn$;

create or replace function public._community_notify(
  p_profile uuid,p_actor uuid,p_board uuid,p_post uuid,p_comment uuid,
  p_kind text,p_title text,p_body text
) returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
begin
  if p_profile is null or p_profile=p_actor then return; end if;
  if exists(select 1 from public.community_notifications n
    where n.profile_id=p_profile and n.kind=p_kind
      and n.post_id is not distinct from p_post
      and n.comment_id is not distinct from p_comment
      and n.actor_profile_id is not distinct from p_actor
      and n.created_at > now() - interval '1 minute') then return; end if;
  insert into public.community_notifications(
    profile_id,actor_profile_id,board_id,post_id,comment_id,kind,title,body
  ) values(p_profile,p_actor,p_board,p_post,p_comment,p_kind,p_title,p_body);
end;
$fn$;

create or replace function public._community_notify_mentions(
  p_text text,p_actor uuid,p_board uuid,p_post uuid,p_comment uuid
) returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_handle text;
  v_profile uuid;
begin
  for v_handle in
    select (m)[1] from regexp_matches(
      coalesce(p_text,''),E'@([^[:space:]@]{1,30})','g') m
  loop
    select p.id into v_profile from public.profiles p
     where coalesce(p.active,true) and (p.name=v_handle or p.code=v_handle)
     limit 1;
    if v_profile is not null then
      perform public._community_notify(
        v_profile,p_actor,p_board,p_post,p_comment,'mention',
        'Mentioned in community',left(coalesce(p_text,''),160));
    end if;
  end loop;
end;
$fn$;

create or replace function public.get_community_boards()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_boards jsonb;
  v_unread integer:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',b.id,'enterprise_id',b.enterprise_id,'slug',b.slug,
    'name',b.name,'description',b.description,'icon',b.icon,
    'sort_order',b.sort_order,'visibility',b.visibility,
    'required_permissions',b.required_permissions,
    'allow_posts',b.allow_posts,'is_archived',b.is_archived,
    'followed',exists(select 1 from public.community_board_follows f
      where f.board_id=b.id and f.profile_id=v_uid),
    'post_count',(select count(*) from public.community_posts p
      where p.board_id=b.id and p.deleted_at is null),
    'can_edit',b.enterprise_id is not null
      and public._community_can_manage(v_uid)
  ) order by b.sort_order,b.created_at), '[]'::jsonb)
    into v_boards
    from public.community_boards b
   where public._community_can_view_board(b.id,v_uid);
  select count(*) into v_unread from public.community_notifications n
   where n.profile_id=v_uid and n.read_at is null;
  return jsonb_build_object('ok',true,'boards',v_boards,
    'unread_count',v_unread,'access',jsonb_build_object(
      'can_manage',public._community_can_manage(v_uid)));
end;
$fn$;

create or replace function public.list_community_posts_v2(
  p_board uuid default null,
  p_search text default '',
  p_before timestamptz default null,
  p_limit integer default 20,
  p_bookmarked boolean default false
) returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_limit integer:=greatest(1,least(coalesce(p_limit,20),50));
  v_rows jsonb;
  v_next timestamptz;
  v_has_more boolean:=false;
  v_search text:=btrim(coalesce(p_search,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  with candidate as (
    select p.*,b.name board_name,b.slug board_slug,b.icon board_icon,
      (p.pinned and (p_board is null or p.board_id=p_board)) is_pinned,
      exists(select 1 from public.community_reactions r
        where r.post_id=p.id and r.profile_id=v_uid and r.kind='like') liked,
      exists(select 1 from public.community_bookmarks bm
        where bm.post_id=p.id and bm.profile_id=v_uid) bookmarked,
      public._community_post_unlocked(p.id,v_uid) unlocked
      from public.community_posts p
      join public.community_boards b on b.id=p.board_id
     where public._community_can_view_board(p.board_id,v_uid)
       and p.deleted_at is null
       and (p_board is null or p.board_id=p_board)
       and (p_before is null or p.last_activity_at < p_before)
       and (v_search='' or (
         public._community_post_unlocked(p.id,v_uid)
         and p.content ilike '%'||v_search||'%'
       ))
       and (not p_bookmarked or exists(select 1 from public.community_bookmarks bm
         where bm.post_id=p.id and bm.profile_id=v_uid))
     order by is_pinned desc,p.last_activity_at desc,p.id desc
     limit v_limit+1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'board_id',c.board_id,'board_name',c.board_name,
    'board_slug',c.board_slug,'board_icon',c.board_icon,
    'author_id',c.author_id,'author_name',c.author_name,
    'author_role',c.author_role,'topic',c.topic,
    'content',case when c.unlocked then c.content else '' end,
    'preview',left(c.content,180),'unlock_cost',c.unlock_cost,
    'is_required',c.is_required,'pinned',c.pinned,'featured',c.featured,
    'locked',not c.unlocked,'liked',c.liked,'bookmarked',c.bookmarked,
    'like_count',c.like_count,'comment_count',c.comment_count,
    'created_at',c.created_at,'last_activity_at',c.last_activity_at
  ) order by c.is_pinned desc,c.last_activity_at desc,c.id desc), '[]'::jsonb),
  max(c.last_activity_at),count(*)>v_limit
  into v_rows,v_next,v_has_more
  from (select * from candidate limit v_limit) c;
  return jsonb_build_object('ok',true,'posts',coalesce(v_rows,'[]'::jsonb),
    'next_cursor',v_next,'has_more',coalesce(v_has_more,false));
end;
$fn$;

create or replace function public.get_community_post(p_post uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_post jsonb;
  v_comments jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select jsonb_build_object(
    'id',p.id,'board_id',p.board_id,'board_name',b.name,
    'author_id',p.author_id,'author_name',p.author_name,
    'author_role',p.author_role,'topic',p.topic,
    'content',case when public._community_post_unlocked(p.id,v_uid)
      then p.content else '' end,
    'preview',left(p.content,180),'unlock_cost',p.unlock_cost,
    'is_required',p.is_required,'pinned',p.pinned,'featured',p.featured,
    'locked',not public._community_post_unlocked(p.id,v_uid),
    'liked',exists(select 1 from public.community_reactions r
      where r.post_id=p.id and r.profile_id=v_uid and r.kind='like'),
    'bookmarked',exists(select 1 from public.community_bookmarks bm
      where bm.post_id=p.id and bm.profile_id=v_uid),
    'like_count',p.like_count,'comment_count',p.comment_count,
    'created_at',p.created_at,'last_activity_at',p.last_activity_at)
    into v_post
    from public.community_posts p
    join public.community_boards b on b.id=p.board_id
   where p.id=p_post and p.deleted_at is null
     and public._community_can_view_board(p.board_id,v_uid);
  if v_post is null then raise exception 'post not found or access denied'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'parent_id',c.parent_id,'author_id',c.author_id,
    'author_name',c.author_name,'author_role',c.author_role,
    'body',c.body,'created_at',c.created_at) order by c.created_at), '[]'::jsonb)
    into v_comments
    from (select * from public.community_comments
      where post_id=p_post and deleted_at is null
      order by created_at limit 100) c;
  return jsonb_build_object('ok',true,'post',v_post,'comments',v_comments);
end;
$fn$;

create or replace function public.post_community_message_v2(
  p_content text,p_topic text default 'share',
  p_unlock_cost integer default 0,p_is_required boolean default false,
  p_board uuid default null
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_name text;
  v_role text;
  v_board uuid:=coalesce(p_board,'10000000-0000-4000-8000-000000000001');
  v_topic text:=lower(trim(coalesce(p_topic,'share')));
  v_content text:=trim(coalesce(p_content,''));
  v_cost integer:=greatest(coalesce(p_unlock_cost,0),0);
  v_required boolean:=coalesce(p_is_required,false);
  v_id uuid;
  v_follower record;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not public._community_can_post_board(v_board,v_uid) then
    raise exception 'board posting denied';
  end if;
  select name,role into v_name,v_role from public.profiles
   where id=v_uid and coalesce(active,true)=true;
  if v_name is null then raise exception 'profile not found'; end if;
  if char_length(v_content)<1 then raise exception 'message is empty'; end if;
  if char_length(v_content)>2000 then raise exception 'message is too long'; end if;
  if char_length(v_topic)<1 or char_length(v_topic)>24 then v_topic:='share'; end if;
  insert into public.community_posts(
    board_id,author_id,author_name,author_role,topic,content,
    unlock_cost,is_required,last_activity_at,updated_at)
  values(v_board,v_uid,v_name,coalesce(v_role,'employee'),v_topic,v_content,
    v_cost,v_required,now(),now()) returning id into v_id;
  for v_follower in select f.profile_id from public.community_board_follows f
   where f.board_id=v_board and f.profile_id<>v_uid loop
    perform public._community_notify(v_follower.profile_id,v_uid,v_board,v_id,
      null,'board_post','New post in followed board',left(v_content,160));
  end loop;
  perform public._community_notify_mentions(v_content,v_uid,v_board,v_id,null);
  return jsonb_build_object('ok',true,'id',v_id,'board_id',v_board);
end;
$fn$;

create or replace function public.post_community_message(
  p_content text,p_topic text default 'share',
  p_unlock_cost integer default 0,p_is_required boolean default false
) returns jsonb language sql security definer
set search_path=public,auth,pg_temp as $fn$
  select public.post_community_message_v2(
    p_content,p_topic,p_unlock_cost,p_is_required,null);
$fn$;

create or replace function public.add_community_comment(
  p_post uuid,p_body text,p_parent uuid default null
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_name text;
  v_role text;
  v_body text:=btrim(coalesce(p_body,''));
  v_post public.community_posts%rowtype;
  v_id uuid;
  v_parent_author uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_post from public.community_posts where id=p_post for update;
  if not found or not public._community_can_view_board(v_post.board_id,v_uid) then
    raise exception 'post not found or access denied';
  end if;
  if not public._community_post_unlocked(p_post,v_uid) then
    raise exception 'knowledge must be unlocked before commenting';
  end if;
  if char_length(v_body)<1 then raise exception 'comment is empty'; end if;
  if char_length(v_body)>4000 then raise exception 'comment is too long'; end if;
  select name,role into v_name,v_role from public.profiles where id=v_uid;
  if p_parent is not null then
    select author_id into v_parent_author from public.community_comments
     where id=p_parent and post_id=p_post and deleted_at is null;
    if v_parent_author is null then raise exception 'parent comment not found'; end if;
  end if;
  insert into public.community_comments(
    post_id,parent_id,author_id,author_name,author_role,body)
  values(p_post,p_parent,v_uid,v_name,coalesce(v_role,'employee'),v_body)
  returning id into v_id;
  update public.community_posts set comment_count=comment_count+1,
    last_activity_at=now(),updated_at=now() where id=p_post;
  perform public._community_notify(v_post.author_id,v_uid,v_post.board_id,
    p_post,v_id,'comment','New comment on your post',left(v_body,160));
  if v_parent_author is not null then
    perform public._community_notify(v_parent_author,v_uid,v_post.board_id,
      p_post,v_id,'reply','New reply to your comment',left(v_body,160));
  end if;
  perform public._community_notify_mentions(v_body,v_uid,v_post.board_id,p_post,v_id);
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;

create or replace function public.toggle_community_like(p_post uuid)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_board uuid;
  v_author uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select board_id,author_id into v_board,v_author
    from public.community_posts where id=p_post;
  if v_board is null or not public._community_can_view_board(v_board,v_uid) then
    raise exception 'post not found or access denied';
  end if;
  if exists(select 1 from public.community_reactions r
    where r.post_id=p_post and r.profile_id=v_uid and r.kind='like') then
    delete from public.community_reactions r
     where r.post_id=p_post and r.profile_id=v_uid and r.kind='like';
    update public.community_posts set like_count=greatest(0,like_count-1),
      updated_at=now() where id=p_post;
    return jsonb_build_object('ok',true,'liked',false,
      'like_count',(select like_count from public.community_posts where id=p_post));
  end if;
  insert into public.community_reactions(post_id,profile_id,kind)
    values(p_post,v_uid,'like') on conflict do nothing;
  update public.community_posts set like_count=like_count+1,
    last_activity_at=now(),updated_at=now() where id=p_post;
  perform public._community_notify(v_author,v_uid,v_board,p_post,null,'like',
    'Your post received a like','');
  return jsonb_build_object('ok',true,'liked',true,
    'like_count',(select like_count from public.community_posts where id=p_post));
end;
$fn$;

create or replace function public.toggle_community_bookmark(p_post uuid)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_board uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select board_id into v_board from public.community_posts where id=p_post;
  if v_board is null or not public._community_can_view_board(v_board,v_uid) then
    raise exception 'post not found or access denied';
  end if;
  if exists(select 1 from public.community_bookmarks bm
    where bm.post_id=p_post and bm.profile_id=v_uid) then
    delete from public.community_bookmarks bm
     where bm.post_id=p_post and bm.profile_id=v_uid;
    return jsonb_build_object('ok',true,'bookmarked',false);
  end if;
  insert into public.community_bookmarks(post_id,profile_id)
    values(p_post,v_uid) on conflict do nothing;
  return jsonb_build_object('ok',true,'bookmarked',true);
end;
$fn$;

create or replace function public.follow_community_board(
  p_board uuid,p_follow boolean default true
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not public._community_can_view_board(p_board,v_uid) then
    raise exception 'board not found or access denied';
  end if;
  if coalesce(p_follow,true) then
    insert into public.community_board_follows(board_id,profile_id)
      values(p_board,v_uid) on conflict do nothing;
  else
    delete from public.community_board_follows f
     where f.board_id=p_board and f.profile_id=v_uid;
  end if;
  return jsonb_build_object('ok',true,'followed',coalesce(p_follow,true));
end;
$fn$;

create or replace function public.report_community_content(
  p_post uuid default null,p_comment uuid default null,
  p_reason text default '',p_detail text default ''
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_board uuid;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_post is null and p_comment is null then raise exception 'report target required'; end if;
  if p_post is not null then
    select board_id into v_board from public.community_posts where id=p_post;
  else
    select p.board_id into v_board from public.community_comments c
      join public.community_posts p on p.id=c.post_id where c.id=p_comment;
  end if;
  if v_board is null or not public._community_can_view_board(v_board,v_uid) then
    raise exception 'target not found or access denied';
  end if;
  if char_length(btrim(coalesce(p_reason,'')))<1 then
    raise exception 'report reason required';
  end if;
  insert into public.community_reports(
    post_id,comment_id,reporter_profile_id,reason,detail)
  values(p_post,p_comment,v_uid,btrim(p_reason),btrim(coalesce(p_detail,'')))
  returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end;
$fn$;

create or replace function public.get_community_notifications(
  p_limit integer default 20
) returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_limit integer:=greatest(1,least(coalesce(p_limit,20),50));
  v_items jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,'kind',n.kind,'title',n.title,'body',n.body,
    'board_id',n.board_id,'post_id',n.post_id,'comment_id',n.comment_id,
    'actor_profile_id',n.actor_profile_id,'read_at',n.read_at,
    'created_at',n.created_at) order by n.created_at desc), '[]'::jsonb)
    into v_items
    from (select * from public.community_notifications where profile_id=v_uid
      order by created_at desc limit v_limit) n;
  return jsonb_build_object('ok',true,'notifications',v_items,
    'unread_count',(select count(*) from public.community_notifications
      where profile_id=v_uid and read_at is null));
end;
$fn$;

create or replace function public.mark_community_notifications_read(
  p_notification uuid default null
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_count integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update public.community_notifications set read_at=now()
   where profile_id=v_uid and read_at is null
     and (p_notification is null or id=p_notification);
  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',true,'marked',v_count);
end;
$fn$;

create or replace function public.create_community_board(
  p_name text,p_slug text,p_description text default '',
  p_visibility text default 'public',
  p_required_permissions text[] default '{}',p_icon text default '*'
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_name text:=btrim(coalesce(p_name,''));
  v_slug text:=lower(btrim(coalesce(p_slug,'')));
  v_visibility text:=lower(coalesce(p_visibility,'public'));
  v_id uuid;
begin
  if not public._community_can_manage(v_uid) then raise exception 'permission denied'; end if;
  if char_length(v_name)<1 or char_length(v_name)>60 then raise exception 'invalid board name'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,39}$' then raise exception 'invalid board slug'; end if;
  if v_visibility not in ('public','restricted') then raise exception 'invalid visibility'; end if;
  select e.id into v_eid from public.enterprises e
   where e.owner_profile_id=public.identity_owner_id() limit 1;
  if v_eid is null then raise exception 'enterprise required'; end if;
  insert into public.community_boards(
    enterprise_id,slug,name,description,icon,visibility,
    required_permissions,created_by)
  values(v_eid,v_slug,v_name,btrim(coalesce(p_description,'')),
    left(coalesce(p_icon,'*'),8),v_visibility,
    coalesce(p_required_permissions,'{}'::text[]),v_uid)
  returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
exception when unique_violation then
  raise exception 'board slug already exists';
end;
$fn$;

create or replace function public.update_community_board(
  p_board uuid,p_name text,p_description text default '',
  p_visibility text default 'public',
  p_required_permissions text[] default '{}',
  p_icon text default '*',p_archived boolean default false
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_visibility text:=lower(coalesce(p_visibility,'public'));
begin
  if not public._community_can_manage(v_uid) then raise exception 'permission denied'; end if;
  if v_visibility not in ('public','restricted') then raise exception 'invalid visibility'; end if;
  update public.community_boards set
    name=btrim(coalesce(p_name,'')),description=btrim(coalesce(p_description,'')),
    icon=left(coalesce(p_icon,'*'),8),visibility=v_visibility,
    required_permissions=coalesce(p_required_permissions,'{}'::text[]),
    is_archived=coalesce(p_archived,false),updated_at=now()
   where id=p_board and enterprise_id is not null;
  if not found then raise exception 'board not editable'; end if;
  return jsonb_build_object('ok',true,'id',p_board);
end;
$fn$;

create or replace function public.moderate_community_post(
  p_post uuid,p_pinned boolean default false,
  p_featured boolean default false,p_deleted boolean default false
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid();
begin
  if not public._community_can_manage(v_uid) then raise exception 'permission denied'; end if;
  update public.community_posts set pinned=coalesce(p_pinned,false),
    featured=coalesce(p_featured,false),
    deleted_at=case when coalesce(p_deleted,false) then now() else null end,
    updated_at=now()
   where id=p_post;
  if not found then raise exception 'post not found'; end if;
  return jsonb_build_object('ok',true,'id',p_post,
    'pinned',coalesce(p_pinned,false),'featured',coalesce(p_featured,false),
    'deleted',coalesce(p_deleted,false));
end;
$fn$;

create or replace function public.resolve_community_report(
  p_report uuid,p_status text default 'resolved'
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_status text:=lower(coalesce(p_status,'resolved'));
begin
  if not public._community_can_manage(v_uid) then raise exception 'permission denied'; end if;
  if v_status not in ('reviewing','resolved','dismissed') then
    raise exception 'invalid report status';
  end if;
  update public.community_reports set status=v_status,
    resolved_by=case when v_status='reviewing' then null else v_uid end,
    resolved_at=case when v_status='reviewing' then null else now() end
   where id=p_report;
  if not found then raise exception 'report not found'; end if;
  return jsonb_build_object('ok',true,'id',p_report,'status',v_status);
end;
$fn$;

create or replace function public.get_community_admin_stats()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_result jsonb;
begin
  if not public._community_can_manage(v_uid) then raise exception 'permission denied'; end if;
  select jsonb_build_object(
    'weekly_active_members',(
      select count(distinct actor) from (
        select author_id actor from public.community_posts
         where created_at>=now()-interval '7 days'
        union all
        select author_id from public.community_comments
         where created_at>=now()-interval '7 days' and deleted_at is null
      ) activity),
    'posts_7d',(select count(*) from public.community_posts
      where created_at>=now()-interval '7 days' and deleted_at is null),
    'comments_7d',(select count(*) from public.community_comments
      where created_at>=now()-interval '7 days' and deleted_at is null),
    'replied_24h',(
      select count(*) from public.community_posts p
       where p.created_at>=now()-interval '7 days'
         and exists(select 1 from public.community_comments c
           where c.post_id=p.id and c.created_at<=p.created_at+interval '24 hours'
             and c.deleted_at is null)),
    'featured_count',(select count(*) from public.community_posts
      where featured and deleted_at is null),
    'open_reports',(select count(*) from public.community_reports where status='open'),
    'boards',(select coalesce(jsonb_agg(jsonb_build_object(
      'board_id',b.id,'name',b.name,
      'posts_7d',(select count(*) from public.community_posts p
        where p.board_id=b.id and p.created_at>=now()-interval '7 days'
          and p.deleted_at is null),
      'comments_7d',(select count(*) from public.community_comments c
        join public.community_posts p on p.id=c.post_id
        where p.board_id=b.id and c.created_at>=now()-interval '7 days'
          and c.deleted_at is null)) order by b.sort_order), '[]'::jsonb)
      from public.community_boards b
      where public._community_can_view_board(b.id,v_uid)))
    into v_result;
  return jsonb_build_object('ok',true,'stats',v_result,'generated_at',now());
end;
$fn$;

alter table public.community_boards enable row level security;
alter table public.community_comments enable row level security;
alter table public.community_reactions enable row level security;
alter table public.community_bookmarks enable row level security;
alter table public.community_board_follows enable row level security;
alter table public.community_reports enable row level security;
alter table public.community_notifications enable row level security;

drop policy if exists "community boards readable by members" on public.community_boards;
create policy "community boards readable by members"
  on public.community_boards for select to authenticated
  using (public._community_can_view_board(id,auth.uid()));

drop policy if exists "community posts readable by members" on public.community_posts;
create policy "community posts readable by members"
  on public.community_posts for select to authenticated
  using (deleted_at is null
    and public._community_can_view_board(board_id,auth.uid())
    and public._community_post_unlocked(id,auth.uid()));

drop policy if exists "community comments readable by members" on public.community_comments;
create policy "community comments readable by members"
  on public.community_comments for select to authenticated
  using (deleted_at is null and exists(
    select 1 from public.community_posts p where p.id=post_id
      and public._community_can_view_board(p.board_id,auth.uid())
      and public._community_post_unlocked(p.id,auth.uid())));

drop policy if exists "community reactions readable by owner" on public.community_reactions;
create policy "community reactions readable by owner"
  on public.community_reactions for select to authenticated
  using (profile_id=auth.uid());

drop policy if exists "community bookmarks readable by owner" on public.community_bookmarks;
create policy "community bookmarks readable by owner"
  on public.community_bookmarks for select to authenticated
  using (profile_id=auth.uid());

drop policy if exists "community follows readable by owner" on public.community_board_follows;
create policy "community follows readable by owner"
  on public.community_board_follows for select to authenticated
  using (profile_id=auth.uid());

drop policy if exists "community reports readable by reporter or manager" on public.community_reports;
create policy "community reports readable by reporter or manager"
  on public.community_reports for select to authenticated
  using (reporter_profile_id=auth.uid() or public._community_can_manage(auth.uid()));

drop policy if exists "community notifications readable by owner" on public.community_notifications;
create policy "community notifications readable by owner"
  on public.community_notifications for select to authenticated
  using (profile_id=auth.uid());

revoke insert,update,delete on public.community_boards from anon,authenticated;
revoke insert,update,delete on public.community_comments from anon,authenticated;
revoke insert,update,delete on public.community_reactions from anon,authenticated;
revoke insert,update,delete on public.community_bookmarks from anon,authenticated;
revoke insert,update,delete on public.community_board_follows from anon,authenticated;
revoke insert,update,delete on public.community_reports from anon,authenticated;
revoke insert,update,delete on public.community_notifications from anon,authenticated;
revoke select on public.community_boards,public.community_comments,
  public.community_reactions,public.community_bookmarks,
  public.community_board_follows,public.community_reports,
  public.community_notifications from anon;
grant select on public.community_boards,public.community_comments,
  public.community_reactions,public.community_bookmarks,
  public.community_board_follows,public.community_reports,
  public.community_notifications to authenticated;

revoke all on function public._community_can_manage(uuid) from public,anon,authenticated;
revoke all on function public._community_can_view_board(uuid,uuid) from public,anon,authenticated;
revoke all on function public._community_can_post_board(uuid,uuid) from public,anon,authenticated;
revoke all on function public._community_post_unlocked(uuid,uuid) from public,anon,authenticated;
revoke all on function public._community_notify(uuid,uuid,uuid,uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public._community_can_manage(uuid) to authenticated;
grant execute on function public._community_can_view_board(uuid,uuid) to authenticated;
grant execute on function public._community_post_unlocked(uuid,uuid) to authenticated;
revoke all on function public._community_notify_mentions(text,uuid,uuid,uuid,uuid) from public,anon,authenticated;

revoke all on function public.get_community_boards() from public,anon,authenticated;
revoke all on function public.list_community_posts_v2(uuid,text,timestamptz,integer,boolean) from public,anon,authenticated;
revoke all on function public.get_community_post(uuid) from public,anon,authenticated;
revoke all on function public.post_community_message_v2(text,text,integer,boolean,uuid) from public,anon,authenticated;
revoke all on function public.post_community_message(text,text,integer,boolean) from public,anon,authenticated;
revoke all on function public.add_community_comment(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.toggle_community_like(uuid) from public,anon,authenticated;
revoke all on function public.toggle_community_bookmark(uuid) from public,anon,authenticated;
revoke all on function public.follow_community_board(uuid,boolean) from public,anon,authenticated;
revoke all on function public.report_community_content(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.get_community_notifications(integer) from public,anon,authenticated;
revoke all on function public.mark_community_notifications_read(uuid) from public,anon,authenticated;
revoke all on function public.create_community_board(text,text,text,text,text[],text) from public,anon,authenticated;
revoke all on function public.update_community_board(uuid,text,text,text,text[],text,boolean) from public,anon,authenticated;
revoke all on function public.moderate_community_post(uuid,boolean,boolean,boolean) from public,anon,authenticated;
revoke all on function public.resolve_community_report(uuid,text) from public,anon,authenticated;
revoke all on function public.get_community_admin_stats() from public,anon,authenticated;

grant execute on function public.get_community_boards() to authenticated;
grant execute on function public.list_community_posts_v2(uuid,text,timestamptz,integer,boolean) to authenticated;
grant execute on function public.get_community_post(uuid) to authenticated;
grant execute on function public.post_community_message_v2(text,text,integer,boolean,uuid) to authenticated;
grant execute on function public.post_community_message(text,text,integer,boolean) to authenticated;
grant execute on function public.add_community_comment(uuid,text,uuid) to authenticated;
grant execute on function public.toggle_community_like(uuid) to authenticated;
grant execute on function public.toggle_community_bookmark(uuid) to authenticated;
grant execute on function public.follow_community_board(uuid,boolean) to authenticated;
grant execute on function public.report_community_content(uuid,uuid,text,text) to authenticated;
grant execute on function public.get_community_notifications(integer) to authenticated;
grant execute on function public.mark_community_notifications_read(uuid) to authenticated;
grant execute on function public.create_community_board(text,text,text,text,text[],text) to authenticated;
grant execute on function public.update_community_board(uuid,text,text,text,text[],text,boolean) to authenticated;
grant execute on function public.moderate_community_post(uuid,boolean,boolean,boolean) to authenticated;
grant execute on function public.resolve_community_report(uuid,text) to authenticated;
grant execute on function public.get_community_admin_stats() to authenticated;

do $do$
declare v_table text;
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    foreach v_table in array array['community_boards','community_posts',
      'community_comments','community_notifications'] loop
      if not exists(select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public'
          and tablename=v_table) then
        execute format('alter publication supabase_realtime add table public.%I',v_table);
      end if;
    end loop;
  end if;
end;
$do$;
