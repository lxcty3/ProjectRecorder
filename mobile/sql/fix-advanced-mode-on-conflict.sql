-- ProjectRecorder advanced-mode compatibility fix
-- Run once in the Supabase SQL editor after organization-founders-v1.sql.
-- ASCII only and safe to run again.

begin;

-- organization-founders-v1 intentionally removed the old owner uniqueness
-- constraint so one profile can own multiple companies. The legacy bootstrap
-- must resolve the owner with a plain SELECT instead.
create or replace function public._identity_ensure_enterprise(p_owner uuid)
returns uuid
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_id uuid;
  v_name text;
begin
  if p_owner is null then
    raise exception 'owner profile is required';
  end if;

  -- Serialize bootstrap for one owner, then use a plain insert. This keeps
  -- multi-company ownership legal while remaining race-safe.
  perform pg_advisory_xact_lock(hashtextextended(p_owner::text, 0));

  select id into v_id
    from public.enterprises
   where owner_profile_id=p_owner
   order by created_at,id
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  select coalesce(nullif(trim(name),''),'Enterprise')||' Enterprise'
    into v_name
    from public.profiles
   where id=p_owner;
  if v_name is null then
    v_name:='Enterprise';
  end if;

  insert into public.enterprises(owner_profile_id,name)
  values(p_owner,v_name)
  returning id into v_id;
  return v_id;
end;
$fn$;

-- The primary key normally provides these indexes. Keep idempotent unique
-- indexes as a repair for databases created from an older partial install.
create unique index if not exists enterprise_members_enterprise_profile_uidx
  on public.enterprise_members(enterprise_id,profile_id);

create unique index if not exists enterprise_shareholders_enterprise_profile_uidx
  on public.enterprise_shareholders(enterprise_id,profile_id);

-- Prefer the member's active company. Only bootstrap when the profile has not
-- selected a company yet. This also fixes UI-mode switching in multi-company
-- accounts.
create or replace function public.set_enterprise_ui_mode(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if p_mode not in ('simple','advanced') then
    raise exception 'invalid mode';
  end if;

  select active_enterprise_id into v_eid
    from public.profiles
   where id=v_uid;

  if v_eid is null then
    v_eid:=public._identity_bootstrap(
      public._identity_owner_for_uid(v_uid)
    );
  end if;

  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  if p_mode='advanced'
     and not public._identity_can_use_advanced_mode(v_eid,v_uid) then
    raise exception 'advanced mode requires management, finance, audit or governance permission';
  end if;

  update public.enterprise_members
     set preferred_mode=p_mode,
         updated_at=now()
   where enterprise_id=v_eid
     and profile_id=v_uid;
  return jsonb_build_object('ok',true,'mode',p_mode,'enterprise_id',v_eid);
end;
$fn$;

revoke all on function public.set_enterprise_ui_mode(text) from public;
revoke all on function public.set_enterprise_ui_mode(text) from anon;
revoke all on function public.set_enterprise_ui_mode(text) from authenticated;
grant execute on function public.set_enterprise_ui_mode(text) to authenticated;

commit;
