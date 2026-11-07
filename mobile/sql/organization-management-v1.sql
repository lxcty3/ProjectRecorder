-- ============================================================
-- Organization management v1
--
-- Adds two checked RPCs:
--   1. rename the active organization
--   2. add an existing account as an ordinary company member
--
-- Both RPCs are SECURITY DEFINER and require company.manage or
-- governance.manage on the target enterprise. They never expose
-- direct table writes to the client.
--
-- This file is ASCII-only and safe to run more than once.
-- ============================================================

create or replace function public.rename_organization(
  p_enterprise uuid,
  p_name text
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_name text:=btrim(coalesce(p_name,''));
  v_old text;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if not public._organization_can_manage(p_enterprise,v_uid) then
    raise exception 'organization management permission required';
  end if;
  if char_length(v_name)<1 or char_length(v_name)>120 then
    raise exception 'organization name must be 1 to 120 characters';
  end if;

  select name into v_old
    from public.enterprises
   where id=p_enterprise;
  if not found then
    raise exception 'organization not found';
  end if;

  if v_old is distinct from v_name then
    update public.enterprises
       set name=v_name,updated_at=now()
     where id=p_enterprise;
    insert into public.enterprise_identity_audit(
      enterprise_id,actor_profile_id,action,details
    ) values(
      p_enterprise,v_uid,'organization.renamed',
      jsonb_build_object('old_name',v_old,'new_name',v_name)
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'enterprise_id',p_enterprise,
    'name',v_name,
    'changed',v_old is distinct from v_name
  );
end;
$fn$;

create or replace function public.add_organization_member(
  p_enterprise uuid,
  p_lookup text,
  p_department text default '',
  p_title text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_lookup text:=btrim(coalesce(p_lookup,''));
  v_profile uuid;
  v_name text;
  v_code text;
  v_matches integer:=0;
  v_already boolean:=false;
  v_department text:=btrim(coalesce(p_department,''));
  v_title text:=btrim(coalesce(p_title,''));
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if not public._organization_can_manage(p_enterprise,v_uid) then
    raise exception 'organization management permission required';
  end if;
  if v_lookup='' then
    raise exception 'account code or name is required';
  end if;

  -- Prefer an exact employee-code match. Fall back to an exact name,
  -- but refuse ambiguous names instead of picking an arbitrary person.
  select p.id,p.name,p.code
    into v_profile,v_name,v_code
    from public.profiles p
   where coalesce(p.active,true)
     and lower(p.code)=lower(v_lookup)
   order by p.created_at nulls last,p.id
   limit 1;

  if v_profile is null then
    select count(*) into v_matches
      from public.profiles p
     where coalesce(p.active,true)
       and p.name=v_lookup;
    if v_matches=0 then
      raise exception 'member account not found';
    end if;
    if v_matches>1 then
      raise exception 'more than one account has that name; use the account code';
    end if;
    select p.id,p.name,p.code
      into v_profile,v_name,v_code
      from public.profiles p
     where coalesce(p.active,true)
       and p.name=v_lookup
     limit 1;
  end if;

  select exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_enterprise
       and m.profile_id=v_profile
       and m.status='active'
  ) into v_already;

  insert into public.enterprise_members(
    enterprise_id,profile_id,role_key,department,title,status,
    appointed_by,appointed_at,updated_at
  ) values(
    p_enterprise,v_profile,'employee',v_department,v_title,'active',
    v_uid,now(),now()
  )
  on conflict(enterprise_id,profile_id) do update set
    department=excluded.department,
    title=excluded.title,
    status='active',
    appointed_by=excluded.appointed_by,
    appointed_at=now(),
    updated_at=now();

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_enterprise,v_uid,'organization.member_added',v_profile,
    jsonb_build_object(
      'name',v_name,'code',v_code,
      'department',v_department,'title',v_title,
      'already_member',v_already
    )
  );

  return jsonb_build_object(
    'ok',true,
    'profile_id',v_profile,
    'name',v_name,
    'code',v_code,
    'already_member',v_already
  );
end;
$fn$;

revoke all on function public.rename_organization(uuid,text)
  from public,anon,authenticated;
revoke all on function public.add_organization_member(uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.rename_organization(uuid,text)
  to authenticated;
grant execute on function public.add_organization_member(uuid,text,text,text)
  to authenticated;

-- Verification:
--   select proname,prosecdef
--     from pg_proc
--    where proname in ('rename_organization','add_organization_member');
-- Both rows must have prosecdef = true.
