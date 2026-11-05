create or replace function public.list_knowledge_posts(p_limit integer default 80)
returns jsonb
language plpgsql
stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_limit integer:=least(greatest(coalesce(p_limit,80),1),100);
  v_result jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select e.id into v_eid
    from public.enterprises e
   where e.owner_profile_id=public._identity_owner_for_uid(v_uid)
   limit 1;
  if v_eid is null then
    select m.enterprise_id into v_eid
      from public.enterprise_members m
     where m.profile_id=v_uid and m.status='active'
     order by m.updated_at desc
     limit 1;
  end if;
  if v_eid is null or not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select coalesce(jsonb_agg(item order by created_at desc),'[]'::jsonb)
    into v_result
    from (
      select p.created_at,jsonb_build_object(
        'id',p.id,'author_id',p.author_id,'author_name',p.author_name,
        'author_role',p.author_role,'topic',p.topic,
        'content',case
          when p.author_id=v_uid or p.is_required or p.unlock_cost=0
            or exists(select 1 from public.enterprise_knowledge_unlocks u
                       where u.profile_id=v_uid and u.post_id=p.id)
          then p.content else '' end,
        'preview',left(p.content,180),
        'unlock_cost',p.unlock_cost,'is_required',p.is_required,
        'locked',not (
          p.author_id=v_uid or p.is_required or p.unlock_cost=0
          or exists(select 1 from public.enterprise_knowledge_unlocks u
                     where u.profile_id=v_uid and u.post_id=p.id)
        ),
        'created_at',p.created_at
      ) item
      from public.community_posts p
      order by p.created_at desc
      limit v_limit
    ) posts;
  return v_result;
end;
$fn$;

revoke all on function public.list_knowledge_posts(integer) from public;
revoke all on function public.list_knowledge_posts(integer) from anon;
revoke all on function public.list_knowledge_posts(integer) from authenticated;
grant execute on function public.list_knowledge_posts(integer) to authenticated;
notify pgrst, 'reload schema';
