-- ============================================================
-- Phase 1: primary company and consent-based member invites
--
-- Additive migration:
--   * profiles.primary_enterprise_id
--   * organization_member_invites
--   * primary-company RPCs
--   * ordinary-member invitation RPCs
--
-- Joining a company NEVER removes another membership and never
-- moves historical tasks or worklogs. The primary company is the
-- account's home company; active_enterprise_id remains the
-- currently viewed company.
--
-- ASCII-only and safe to run more than once.
-- ============================================================

alter table public.profiles
  add column if not exists primary_enterprise_id uuid
  references public.enterprises(id) on delete set null;

create index if not exists profiles_primary_company_idx
  on public.profiles(primary_enterprise_id);

create table if not exists public.organization_member_invites (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  inviter_profile_id uuid not null references public.profiles(id) on delete cascade,
  invitee_profile_id uuid not null references public.profiles(id) on delete cascade,
  department text not null default '',
  title text not null default '',
  status text not null default 'invited'
    check (status in ('invited','accepted','declined','expired','revoked')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now()+interval '7 days'),
  responded_at timestamptz
);

create unique index if not exists organization_member_invite_open_idx
  on public.organization_member_invites(enterprise_id,invitee_profile_id)
  where status='invited';
create index if not exists organization_member_invitee_idx
  on public.organization_member_invites(invitee_profile_id,status,created_at desc);
create index if not exists organization_member_inviter_idx
  on public.organization_member_invites(enterprise_id,status,created_at desc);

alter table public.organization_member_invites enable row level security;
revoke all on public.organization_member_invites from public,anon,authenticated;

update public.profiles p
   set primary_enterprise_id = (
     select m.enterprise_id
       from public.enterprise_members m
      where m.profile_id=p.id and m.status='active'
      order by
        case when m.enterprise_id=p.active_enterprise_id then 0 else 1 end,
        m.updated_at desc,
        m.enterprise_id
      limit 1
   )
 where p.primary_enterprise_id is null
   and exists(
     select 1 from public.enterprise_members m
      where m.profile_id=p.id and m.status='active'
   );

create or replace function public._phase1_ensure_primary_company(p_uid uuid)
returns uuid
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_primary uuid;
  v_candidate uuid;
  v_active uuid;
begin
  if p_uid is null then return null; end if;

  select primary_enterprise_id,active_enterprise_id
    into v_primary,v_active
    from public.profiles where id=p_uid;

  if v_primary is not null and exists(
    select 1 from public.enterprise_members m
     where m.profile_id=p_uid and m.enterprise_id=v_primary
       and m.status='active'
  ) then
    return v_primary;
  end if;

  select m.enterprise_id into v_candidate
    from public.enterprise_members m
   where m.profile_id=p_uid and m.status='active'
   order by
     case when m.enterprise_id=v_active then 0 else 1 end,
     m.updated_at desc,
     m.enterprise_id
   limit 1;

  if v_candidate is null then return null; end if;

  if v_active is null or not exists(
    select 1 from public.enterprise_members m
     where m.profile_id=p_uid and m.enterprise_id=v_active
       and m.status='active'
  ) then
    v_active:=v_candidate;
  end if;

  update public.profiles
     set primary_enterprise_id=v_candidate,
         active_enterprise_id=v_active
   where id=p_uid;
  return v_candidate;
end;
$fn$;

create or replace function public.get_primary_company()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._phase1_ensure_primary_company(v_uid);
  return jsonb_build_object(
    'ok',true,
    'primary_enterprise_id',v_eid,
    'required',v_eid is null and exists(
      select 1 from public.enterprise_members m
       where m.profile_id=v_uid and m.status='active'
    ),
    'name',(select e.name from public.enterprises e where e.id=v_eid)
  );
end;
$fn$;

create or replace function public.set_primary_company(p_enterprise uuid)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_name text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists(
    select 1 from public.enterprise_members m
     where m.profile_id=v_uid and m.enterprise_id=p_enterprise
       and m.status='active'
  ) then
    raise exception 'active company membership required';
  end if;
  select name into v_name from public.enterprises where id=p_enterprise;
  update public.profiles
     set primary_enterprise_id=p_enterprise,
         active_enterprise_id=p_enterprise
   where id=v_uid;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(
    p_enterprise,v_uid,'organization.primary_set',
    jsonb_build_object('primary_enterprise_id',p_enterprise)
  );
  return jsonb_build_object('ok',true,'primary_enterprise_id',p_enterprise,
    'name',v_name);
end;
$fn$;

create or replace function public.invite_organization_member(
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
  v_invite uuid;
  v_department text:=btrim(coalesce(p_department,''));
  v_title text:=btrim(coalesce(p_title,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not public._organization_can_manage(p_enterprise,v_uid) then
    raise exception 'organization management permission required';
  end if;
  if v_lookup='' then raise exception 'account code or name is required'; end if;

  select p.id,p.name,p.code into v_profile,v_name,v_code
    from public.profiles p
   where coalesce(p.active,true)
     and lower(p.code)=lower(v_lookup)
   order by p.created_at nulls last,p.id
   limit 1;

  if v_profile is null then
    select count(*) into v_matches
      from public.profiles p
     where coalesce(p.active,true) and p.name=v_lookup;
    if v_matches=0 then raise exception 'member account not found'; end if;
    if v_matches>1 then
      raise exception 'more than one account has that name; use the account code';
    end if;
    select p.id,p.name,p.code into v_profile,v_name,v_code
      from public.profiles p
     where coalesce(p.active,true) and p.name=v_lookup
     limit 1;
  end if;

  if v_profile=v_uid then raise exception 'cannot invite yourself'; end if;
  if exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_enterprise and m.profile_id=v_profile
       and m.status='active'
  ) then
    return jsonb_build_object('ok',true,'already_member',true,
      'profile_id',v_profile,'name',v_name,'code',v_code);
  end if;

  select id into v_invite
    from public.organization_member_invites
   where enterprise_id=p_enterprise and invitee_profile_id=v_profile
     and status='invited'
   limit 1;

  if v_invite is null then
    insert into public.organization_member_invites(
      enterprise_id,inviter_profile_id,invitee_profile_id,
      department,title,expires_at
    ) values(
      p_enterprise,v_uid,v_profile,v_department,v_title,now()+interval '7 days'
    ) returning id into v_invite;
  else
    update public.organization_member_invites
       set inviter_profile_id=v_uid,
           department=v_department,
           title=v_title,
           expires_at=now()+interval '7 days'
     where id=v_invite;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_enterprise,v_uid,'organization.member_invited',v_profile,
    jsonb_build_object('invite_id',v_invite,'name',v_name,'code',v_code,
      'department',v_department,'title',v_title)
  );

  return jsonb_build_object('ok',true,'invite_id',v_invite,
    'profile_id',v_profile,'name',v_name,'code',v_code,
    'expires_at',now()+interval '7 days');
end;
$fn$;

create or replace function public.respond_organization_member_invite(
  p_invite uuid,p_accept boolean
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.organization_member_invites%rowtype;
  v_org_name text;
  v_owner uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row
    from public.organization_member_invites
   where id=p_invite and invitee_profile_id=v_uid
   for update;
  if not found then raise exception 'invite not found'; end if;
  if v_row.status<>'invited' then raise exception 'invite is not open'; end if;

  select name,owner_profile_id into v_org_name,v_owner
    from public.enterprises where id=v_row.enterprise_id;

  if v_row.expires_at<=now() then
    update public.organization_member_invites
       set status='expired',responded_at=now() where id=p_invite;
    return jsonb_build_object('ok',false,'code','invite_expired',
      'error','invite expired');
  end if;

  if not coalesce(p_accept,false) then
    update public.organization_member_invites
       set status='declined',responded_at=now() where id=p_invite;
    return jsonb_build_object('ok',true,'accepted',false,
      'enterprise_id',v_row.enterprise_id,'organization_name',v_org_name);
  end if;

  insert into public.enterprise_members(
    enterprise_id,profile_id,role_key,department,title,status,
    appointed_by,appointed_at,updated_at
  ) values(
    v_row.enterprise_id,v_uid,'employee',v_row.department,v_row.title,'active',
    v_row.inviter_profile_id,now(),now()
  )
  on conflict(enterprise_id,profile_id) do update set
    department=excluded.department,
    title=excluded.title,
    status='active',
    appointed_by=excluded.appointed_by,
    appointed_at=now(),
    updated_at=now();

  update public.organization_member_invites
     set status='accepted',responded_at=now() where id=p_invite;

  -- Accepting an invite switches the current organization. The primary
  -- company is not changed when one already exists.
  update public.profiles
     set active_enterprise_id=v_row.enterprise_id,
         boss_id=v_owner
   where id=v_uid;
  perform public._phase1_ensure_primary_company(v_uid);

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    v_row.enterprise_id,v_uid,'organization.member_invite_accepted',v_uid,
    jsonb_build_object('invite_id',p_invite,
      'primary_preserved',true,'department',v_row.department,'title',v_row.title)
  );

  return jsonb_build_object('ok',true,'accepted',true,
    'enterprise_id',v_row.enterprise_id,'organization_name',v_org_name,
    'primary_preserved',true);
end;
$fn$;

create or replace function public.get_organization_member_invites()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._organization_active_enterprise(v_uid);
  return jsonb_build_object(
    'ok',true,
    'received',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',i.id,'enterprise_id',i.enterprise_id,
        'organization_name',e.name,
        'inviter_name',ip.name,'inviter_code',ip.code,
        'department',i.department,'title',i.title,
        'status',i.status,'created_at',i.created_at,'expires_at',i.expires_at
      ) order by i.created_at desc)
      from public.organization_member_invites i
      join public.enterprises e on e.id=i.enterprise_id
      join public.profiles ip on ip.id=i.inviter_profile_id
      where i.invitee_profile_id=v_uid
    ),'[]'::jsonb),
    'sent',case when v_eid is not null
      and public._organization_can_manage(v_eid,v_uid) then coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',i.id,'enterprise_id',i.enterprise_id,
          'invitee_name',p.name,'invitee_code',p.code,
          'department',i.department,'title',i.title,
          'status',i.status,'created_at',i.created_at,'expires_at',i.expires_at
        ) order by i.created_at desc)
        from public.organization_member_invites i
        join public.profiles p on p.id=i.invitee_profile_id
        where i.enterprise_id=v_eid
      ),'[]'::jsonb) else '[]'::jsonb end
  );
end;
$fn$;

revoke all on function public._phase1_ensure_primary_company(uuid)
  from public,anon,authenticated;
revoke all on function public.get_primary_company()
  from public,anon,authenticated;
revoke all on function public.set_primary_company(uuid)
  from public,anon,authenticated;
revoke all on function public.invite_organization_member(uuid,text,text,text)
  from public,anon,authenticated;
revoke all on function public.respond_organization_member_invite(uuid,boolean)
  from public,anon,authenticated;
revoke all on function public.get_organization_member_invites()
  from public,anon,authenticated;

grant execute on function public.get_primary_company() to authenticated;
grant execute on function public.set_primary_company(uuid) to authenticated;
grant execute on function public.invite_organization_member(uuid,text,text,text) to authenticated;
grant execute on function public.respond_organization_member_invite(uuid,boolean) to authenticated;
grant execute on function public.get_organization_member_invites() to authenticated;

-- Force clients through consent-based invitations when the direct-add
-- migration is present. Older databases can install this file first.
do $do$
begin
  if to_regprocedure('public.add_organization_member(uuid,text,text,text)') is not null then
    revoke execute on function public.add_organization_member(uuid,text,text,text)
      from authenticated;
  end if;
end;
$do$;

-- Verification:
--   select proname,prosecdef from pg_proc
--    where proname in ('get_primary_company','invite_organization_member',
--                      'respond_organization_member_invite');
