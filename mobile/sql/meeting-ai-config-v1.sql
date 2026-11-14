-- Company-level meeting AI config. Keys are never returned to clients.
create table if not exists public.enterprise_meeting_ai (
  enterprise_id uuid primary key
    references public.enterprises(id) on delete cascade,
  provider text not null default 'gemini'
    check (provider in ('gemini','domestic')),
  gemini_key text not null default '',
  asr_url text not null default '',
  asr_key text not null default '',
  llm_url text not null default '',
  llm_key text not null default '',
  llm_model text not null default 'deepseek-chat',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.enterprise_meeting_ai enable row level security;
revoke all on public.enterprise_meeting_ai from public, anon, authenticated;

create or replace function public.set_meeting_ai_config(
  p_provider text,
  p_gemini_key text default '',
  p_asr_url text default '',
  p_asr_key text default '',
  p_llm_url text default '',
  p_llm_key text default '',
  p_llm_model text default 'deepseek-chat'
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_owner uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;
  if v_uid <> v_owner then raise exception 'only the owner can set company AI config'; end if;
  if p_provider not in ('gemini','domestic') then raise exception 'invalid provider'; end if;
  insert into public.enterprise_meeting_ai(
    enterprise_id, provider, gemini_key, asr_url, asr_key,
    llm_url, llm_key, llm_model, updated_by, updated_at
  ) values (
    v_eid, p_provider, coalesce(p_gemini_key,''), coalesce(p_asr_url,''),
    coalesce(p_asr_key,''), coalesce(p_llm_url,''), coalesce(p_llm_key,''),
    coalesce(nullif(trim(p_llm_model),''),'deepseek-chat'), v_uid, now()
  )
  on conflict (enterprise_id) do update set
    provider=excluded.provider, gemini_key=excluded.gemini_key,
    asr_url=excluded.asr_url, asr_key=excluded.asr_key,
    llm_url=excluded.llm_url, llm_key=excluded.llm_key,
    llm_model=excluded.llm_model, updated_by=excluded.updated_by,
    updated_at=now();
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.get_meeting_ai_config_status()
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_row public.enterprise_meeting_ai%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid := public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid, v_uid) then
    raise exception 'not an enterprise member';
  end if;
  select * into v_row from public.enterprise_meeting_ai where enterprise_id=v_eid;
  return jsonb_build_object(
    'ok', true,
    'provider', coalesce(v_row.provider,''),
    'configured', case
      when v_row.provider='gemini' then coalesce(v_row.gemini_key,'') <> ''
      when v_row.provider='domestic' then coalesce(v_row.asr_url,'') <> '' and coalesce(v_row.llm_url,'') <> ''
      else false end,
    'asr_url', coalesce(v_row.asr_url,''),
    'llm_url', coalesce(v_row.llm_url,''),
    'llm_model', coalesce(v_row.llm_model,'')
  );
end;
$fn$;

create or replace function public.get_meeting_ai_secrets(p_enterprise uuid)
returns jsonb
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select jsonb_build_object(
    'provider', coalesce(provider,''),
    'gemini_key', coalesce(gemini_key,''),
    'asr_url', coalesce(asr_url,''),
    'asr_key', coalesce(asr_key,''),
    'llm_url', coalesce(llm_url,''),
    'llm_key', coalesce(llm_key,''),
    'llm_model', coalesce(llm_model,'deepseek-chat')
  )
  from public.enterprise_meeting_ai where enterprise_id=p_enterprise;
$fn$;

revoke all on function public.set_meeting_ai_config(text,text,text,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.set_meeting_ai_config(text,text,text,text,text,text,text)
  to authenticated;
revoke all on function public.get_meeting_ai_config_status()
  from public, anon, authenticated;
grant execute on function public.get_meeting_ai_config_status()
  to authenticated;
revoke all on function public.get_meeting_ai_secrets(uuid)
  from public, anon, authenticated;
grant execute on function public.get_meeting_ai_secrets(uuid)
  to service_role;

insert into public.app_migrations(version,name,notes)
values ('meeting-ai-config-v1','Meeting AI config','Company-level meeting AI provider config')
on conflict (version) do update set notes=excluded.notes;
