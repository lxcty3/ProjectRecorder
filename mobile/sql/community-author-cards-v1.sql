-- ============================================================
-- Community author cards v1
--
-- Returns the community avatar plus the author's primary-company
-- role for feed and comment authors. When several active role
-- assignments exist in that company, the highest-ranked role wins.
--
-- ASCII-only and safe to run more than once.
-- ============================================================

create or replace function public.get_community_author_cards(p_profiles uuid[])
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'ok',true,
    'authors',coalesce((
      select jsonb_agg(jsonb_build_object(
        'profile_id',p.id,
        'avatar_url',coalesce(cp.avatar_url,''),
        'primary_enterprise_id',p.primary_enterprise_id,
        'company_name',role_info.company_name,
        'role_key',role_info.role_key,
        'role_name',role_info.role_name
      ))
      from public.profiles p
      left join public.community_profiles cp on cp.profile_id=p.id
      left join lateral (
        select m.enterprise_id,e.name company_name,
               coalesce(assigned.role_key,m.role_key) role_key,
               r.name role_name,r.rank role_rank
          from public.enterprise_members m
          join public.enterprises e on e.id=m.enterprise_id
          left join lateral (
            select t.key role_key,t.name role_name,ar.rank role_rank
              from public.enterprise_role_assignments a
              join public.enterprise_role_template_versions tv
                on tv.id=a.template_version_id
              join public.enterprise_role_templates t
                on t.id=tv.template_id
              join public.enterprise_role_catalog ar on ar.key=t.key
             where a.enterprise_id=m.enterprise_id
               and a.profile_id=p.id and a.status='active'
               and a.starts_at<=now()
               and (a.ends_at is null or a.ends_at>now())
             order by ar.rank desc,t.name
             limit 1
          ) assigned on true
          join public.enterprise_role_catalog r
            on r.key=coalesce(assigned.role_key,m.role_key)
         where m.profile_id=p.id and m.status='active'
           and (p.primary_enterprise_id is null
             or m.enterprise_id=p.primary_enterprise_id)
         order by r.rank desc,e.name
         limit 1
      ) role_info on true
      where p.id=any(coalesce(p_profiles,'{}'::uuid[]))
    ),'[]'::jsonb)
  );
end;
$fn$;

revoke all on function public.get_community_author_cards(uuid[])
  from public,anon,authenticated;
grant execute on function public.get_community_author_cards(uuid[])
  to authenticated;

-- Verification:
--   select proname,prosecdef from pg_proc
--    where proname='get_community_author_cards';
