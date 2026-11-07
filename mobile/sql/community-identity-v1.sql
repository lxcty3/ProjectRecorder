-- Community identity v1: alias, avatar, bio, follows and blocks.
-- Additive, ASCII-only, idempotent.
create table if not exists public.community_profiles (
  enterprise_id uuid references public.enterprises(id) on delete cascade,
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  alias_name text not null,
  alias_key text not null,
  avatar_url text not null default '',
  bio text not null default '',
  signature text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (char_length(alias_name) between 2 and 20),
  check (char_length(bio) <= 300),
  check (char_length(signature) <= 120)
);
create unique index if not exists community_profiles_alias_idx
  on public.community_profiles(coalesce(enterprise_id,
    '00000000-0000-0000-0000-000000000000'::uuid),alias_key);
create table if not exists public.community_user_follows (
  follower_profile_id uuid not null references public.profiles(id) on delete cascade,
  followed_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_profile_id,followed_profile_id),
  check (follower_profile_id<>followed_profile_id)
);
create table if not exists public.community_user_blocks (
  blocker_profile_id uuid not null references public.profiles(id) on delete cascade,
  blocked_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_profile_id,blocked_profile_id),
  check (blocker_profile_id<>blocked_profile_id)
);
alter table public.community_profiles enable row level security;
alter table public.community_user_follows enable row level security;
alter table public.community_user_blocks enable row level security;
revoke all on public.community_profiles from anon,authenticated;
revoke all on public.community_user_follows from anon,authenticated;
revoke all on public.community_user_blocks from anon,authenticated;

create or replace function public.get_my_community_profile()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
 v_uid uuid:=auth.uid();
 v_row public.community_profiles%rowtype;
begin
 if v_uid is null then raise exception 'not signed in'; end if;
 select * into v_row from public.community_profiles where profile_id=v_uid;
 return jsonb_build_object(
  'ok',true,'profile_id',v_uid,
  'alias_name',coalesce(v_row.alias_name,(select name from public.profiles where id=v_uid)),
  'avatar_url',coalesce(v_row.avatar_url,''),'bio',coalesce(v_row.bio,''),
  'signature',coalesce(v_row.signature,''),'initialized',found,
  'followers',(select count(*) from public.community_user_follows f where f.followed_profile_id=v_uid),
  'following',(select count(*) from public.community_user_follows f where f.follower_profile_id=v_uid)
 );
end;
$fn$;

create or replace function public.update_community_profile(
 p_alias text,p_avatar_url text default '',p_bio text default '',p_signature text default ''
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
 v_uid uuid:=auth.uid();
 v_eid uuid;
 v_alias text:=btrim(coalesce(p_alias,''));
 v_old public.community_profiles%rowtype;
begin
 if v_uid is null then raise exception 'not signed in'; end if;
 if char_length(v_alias)<2 or char_length(v_alias)>20 then raise exception 'alias must be 2 to 20 characters'; end if;
 select active_enterprise_id into v_eid from public.profiles where id=v_uid;
 select * into v_old from public.community_profiles where profile_id=v_uid;
 if found and v_old.alias_key<>lower(v_alias) and v_old.updated_at>now()-interval '30 days' then
  raise exception 'alias can only be changed every 30 days';
 end if;
 insert into public.community_profiles(enterprise_id,profile_id,alias_name,alias_key,avatar_url,bio,signature)
 values(v_eid,v_uid,v_alias,lower(v_alias),btrim(coalesce(p_avatar_url,'')),btrim(coalesce(p_bio,'')),btrim(coalesce(p_signature,'')))
 on conflict(profile_id) do update set enterprise_id=excluded.enterprise_id,alias_name=excluded.alias_name,
 alias_key=excluded.alias_key,avatar_url=excluded.avatar_url,bio=excluded.bio,signature=excluded.signature,updated_at=now();
 update public.community_posts set author_name=v_alias where author_id=v_uid;
 update public.community_comments set author_name=v_alias where author_id=v_uid;
 if v_eid is not null then
  insert into public.enterprise_identity_audit(enterprise_id,actor_profile_id,action,target_profile_id,details)
  values(v_eid,v_uid,'community.profile_updated',v_uid,jsonb_build_object('alias',v_alias));
 end if;
 return jsonb_build_object('ok',true,'alias_name',v_alias);
end;
$fn$;

create or replace function public.get_community_user_profile(p_profile uuid)
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid(); v_row public.community_profiles%rowtype; v_name text;
begin
 if v_uid is null then raise exception 'not signed in'; end if;
 select * into v_row from public.community_profiles where profile_id=p_profile;
 if found then v_name:=v_row.alias_name; else select name into v_name from public.profiles where id=p_profile; end if;
 return jsonb_build_object('ok',true,'profile_id',p_profile,'alias_name',v_name,
  'avatar_url',coalesce(v_row.avatar_url,''),'bio',coalesce(v_row.bio,''),'signature',coalesce(v_row.signature,''),
  'followers',(select count(*) from public.community_user_follows f where f.followed_profile_id=p_profile),
  'following',(select count(*) from public.community_user_follows f where f.follower_profile_id=p_profile),
  'following_me',exists(select 1 from public.community_user_follows f where f.follower_profile_id=v_uid and f.followed_profile_id=p_profile),
  'blocked',exists(select 1 from public.community_user_blocks b where b.blocker_profile_id=v_uid and b.blocked_profile_id=p_profile));
end;
$fn$;

create or replace function public.follow_community_user(p_profile uuid,p_follow boolean default true)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid();
begin
 if v_uid is null or v_uid=p_profile then raise exception 'invalid follow target'; end if;
 if coalesce(p_follow,true) then
  insert into public.community_user_follows(follower_profile_id,followed_profile_id) values(v_uid,p_profile) on conflict do nothing;
 else delete from public.community_user_follows f where f.follower_profile_id=v_uid and f.followed_profile_id=p_profile; end if;
 return jsonb_build_object('ok',true,'following',coalesce(p_follow,true));
end;
$fn$;

create or replace function public.block_community_user(p_profile uuid,p_block boolean default true)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid();
begin
 if v_uid is null or v_uid=p_profile then raise exception 'invalid block target'; end if;
 if coalesce(p_block,true) then
  insert into public.community_user_blocks(blocker_profile_id,blocked_profile_id) values(v_uid,p_profile) on conflict do nothing;
 else delete from public.community_user_blocks b where b.blocker_profile_id=v_uid and b.blocked_profile_id=p_profile; end if;
 return jsonb_build_object('ok',true,'blocked',coalesce(p_block,true));
end;
$fn$;

revoke all on function public.get_my_community_profile() from public,anon,authenticated;
revoke all on function public.update_community_profile(text,text,text,text) from public,anon,authenticated;
revoke all on function public.get_community_user_profile(uuid) from public,anon,authenticated;
revoke all on function public.follow_community_user(uuid,boolean) from public,anon,authenticated;
revoke all on function public.block_community_user(uuid,boolean) from public,anon,authenticated;
grant execute on function public.get_my_community_profile() to authenticated;
grant execute on function public.update_community_profile(text,text,text,text) to authenticated;
grant execute on function public.get_community_user_profile(uuid) to authenticated;
grant execute on function public.follow_community_user(uuid,boolean) to authenticated;
grant execute on function public.block_community_user(uuid,boolean) to authenticated;
