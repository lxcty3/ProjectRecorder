-- ============================================================
-- My companies directory v1
--
-- Lists every active company membership for the signed-in user,
-- marks the required primary company, and exposes only the people
-- fields the caller is authorized to see.
--
-- ASCII-only and safe to run more than once.
-- ============================================================

create or replace function public.get_my_companies()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_primary uuid;
  v_active uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_primary:=public._phase1_ensure_primary_company(v_uid);
  v_active:=public._organization_active_enterprise(v_uid);

  return jsonb_build_object(
    'ok',true,
    'primary_enterprise_id',v_primary,
    'active_enterprise_id',v_active,
    'companies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,
        'name',e.name,
        'owner_profile_id',e.owner_profile_id,
        'role_key',m.role_key,
        'department',m.department,
        'title',m.title,
        'is_primary',e.id=v_primary,
        'is_active',e.id=v_active,
        'member_count',(
          select count(*) from public.enterprise_members x
           where x.enterprise_id=e.id and x.status='active'
        ),
        'can_view_people',true,
        'can_view_sensitive',
          e.owner_profile_id=v_uid
          or public._organization_is_founder(e.id,v_uid)
          or public._identity_role_permissions(e.id,v_uid) ? 'people.view_all'
          or public._identity_role_permissions(e.id,v_uid) ? 'people.manage'
          or public._identity_role_permissions(e.id,v_uid) ? 'company.manage'
          or public._identity_role_permissions(e.id,v_uid) ? 'governance.manage'
      ) order by (e.id=v_primary) desc,e.name)
      from public.enterprise_members m
      join public.enterprises e on e.id=m.enterprise_id
      where m.profile_id=v_uid and m.status='active'
    ),'[]'::jsonb)
  );
end;
$fn$;

create or replace function public.get_company_people(p_enterprise uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_company public.enterprises%rowtype;
  v_my_member public.enterprise_members%rowtype;
  v_full boolean:=false;
  v_total numeric:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_company from public.enterprises where id=p_enterprise;
  if not found then raise exception 'company not found'; end if;
  select * into v_my_member
    from public.enterprise_members
   where enterprise_id=p_enterprise and profile_id=v_uid and status='active';
  if not found then raise exception 'active company membership required'; end if;

  v_full:=v_company.owner_profile_id=v_uid
    or public._organization_is_founder(p_enterprise,v_uid)
    or public._identity_role_permissions(p_enterprise,v_uid) ? 'people.view_all'
    or public._identity_role_permissions(p_enterprise,v_uid) ? 'people.manage'
    or public._identity_role_permissions(p_enterprise,v_uid) ? 'company.manage'
    or public._identity_role_permissions(p_enterprise,v_uid) ? 'governance.manage';

  select coalesce(sum(shares),0) into v_total
    from public.enterprise_shareholders
   where enterprise_id=p_enterprise;

  return jsonb_build_object(
    'ok',true,
    'company',jsonb_build_object('id',v_company.id,'name',v_company.name),
    'access',jsonb_build_object(
      'full',v_full,
      'can_view_people',true,
      'message',case when v_full then '??????????????????'
        else '????????????????' end
    ),
    'people',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'profile_id',p.id,
          'name',p.name,
          'role_key',m.role_key,
          'department',m.department,
          'title',m.title,
          'is_me',p.id=v_uid
        ) || case when v_full then jsonb_build_object(
          'code',p.code,
          'email',p.email,
          'primary_enterprise_id',p.primary_enterprise_id,
          'primary_company_name',(select pe.name from public.enterprises pe where pe.id=p.primary_enterprise_id),
          'status',m.status,
          'appointed_at',m.appointed_at,
          'is_shareholder',coalesce(s.shares,0)>0,
          'shares',coalesce(s.shares,0),
          'share_percent',case when v_total>0 then round(coalesce(s.shares,0)/v_total*100,2) else 0 end
        ) else '{}'::jsonb end
        order by (p.id=v_uid) desc,r.rank desc,p.name
      )
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      join public.enterprise_role_catalog r on r.key=m.role_key
      left join public.enterprise_shareholders s
        on s.enterprise_id=m.enterprise_id and s.profile_id=m.profile_id
      where m.enterprise_id=p_enterprise
        and (m.status='active' or v_full)
    ),'[]'::jsonb)
  );
end;
$fn$;

revoke all on function public.get_my_companies()
  from public,anon,authenticated;
revoke all on function public.get_company_people(uuid)
  from public,anon,authenticated;
grant execute on function public.get_my_companies() to authenticated;
grant execute on function public.get_company_people(uuid) to authenticated;

-- Verification:
--   select proname,prosecdef from pg_proc
--    where proname in ('get_my_companies','get_company_people');
