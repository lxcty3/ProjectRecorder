-- ============================================================
-- Project Recorder - Phase 4 work intake
--
-- Run after decision-approvals-v1.sql, execution-tracking-v1.sql,
-- and operations-economics-v1.sql. This migration is idempotent.
-- Public callers use form tokens and receive no internal data.
-- ============================================================

create sequence if not exists public.intake_request_seq;

create table if not exists public.intake_settings (
  enterprise_id uuid primary key references public.enterprises(id) on delete cascade,
  email_domain text not null default 'inbound.projectrecorder.local',
  public_form_base_url text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_forms (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  name text not null default 'Work intake',
  public_token text not null unique,
  allowed_types text[] not null default array['customer','sales','improvement','incident','temporary']::text[],
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  request_no text not null default ('INT-' || to_char(now(),'YYYYMMDD') || '-' || lpad(nextval('public.intake_request_seq')::text,6,'0')) unique,
  source_type text not null default 'quick'
    check (source_type in ('quick','public_form','email','wechat','internal')),
  request_type text not null default 'temporary'
    check (request_type in ('customer','sales','improvement','incident','temporary')),
  title text not null check (char_length(btrim(title)) > 0),
  detail text not null default '',
  requester_profile_id uuid references public.profiles(id) on delete set null,
  requester_name text not null default '',
  requester_email text not null default '',
  requester_phone text not null default '',
  tracking_code text unique,
  form_id uuid references public.intake_forms(id) on delete set null,
  status text not null default 'submitted'
    check (status in ('submitted','triage','in_progress','resolved','closed','merged')),
  priority_score numeric not null default 0 check (priority_score >= 0),
  priority_factors jsonb not null default '[]'::jsonb,
  priority_override numeric check (priority_override is null or priority_override >= 0),
  priority_override_reason text not null default '',
  owner_profile_id uuid references public.profiles(id) on delete set null,
  sla_due_at timestamptz not null default now(),
  first_response_at timestamptz,
  escalated_at timestamptz,
  resolved_at timestamptz,
  merged_into_id uuid references public.intake_requests(id) on delete set null,
  converted_kind text check (converted_kind is null or converted_kind in ('project','task','presales')),
  converted_at timestamptz,
  linked_project_id uuid references public.projects(id) on delete set null,
  linked_task_id uuid references public.tasks(id) on delete set null,
  presales_owner_id uuid references public.profiles(id) on delete set null,
  source_ref text not null default '',
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (merged_into_id is null or merged_into_id <> id),
  check (status <> 'merged' or merged_into_id is not null)
);

create table if not exists public.intake_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  source_request_id uuid references public.intake_requests(id) on delete set null,
  author_profile_id uuid references public.profiles(id) on delete set null,
  author_label text not null default '',
  visibility text not null default 'internal'
    check (visibility in ('public','internal','system')),
  body text not null check (char_length(btrim(body)) > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.intake_links (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  linked_request_id uuid not null references public.intake_requests(id) on delete cascade,
  link_type text not null default 'related'
    check (link_type in ('duplicate','related')),
  note text not null default '',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (request_id, linked_request_id, link_type),
  check (request_id <> linked_request_id)
);

create table if not exists public.intake_events (
  id bigserial primary key,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  from_status text not null default '',
  to_status text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_security_audit (
  id bigserial primary key,
  enterprise_id uuid references public.enterprises(id) on delete set null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  operation text not null,
  reason text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_submission_attempts (
  id bigserial primary key,
  form_id uuid references public.intake_forms(id) on delete cascade,
  email_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_email_aliases (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  label text not null default '',
  alias_token text not null unique,
  email_address text not null,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.intake_notifications (
  id bigserial primary key,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  recipient_email text not null,
  kind text not null default 'status',
  subject text not null default '',
  body text not null default '',
  status text not null default 'pending'
    check (status in ('pending','sent','failed')),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.presales_opportunities (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  title text not null,
  customer_name text not null default '',
  estimated_value numeric not null default 0 check (estimated_value >= 0),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  stage text not null default 'qualified'
    check (stage in ('qualified','proposal','negotiation','won','lost')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.intake_conversions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.intake_requests(id) on delete cascade,
  kind text not null check (kind in ('project','task','presales')),
  linked_id uuid not null,
  payload jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists intake_requests_request_no_idx
  on public.intake_requests(request_no);
create index if not exists intake_requests_enterprise_status_idx
  on public.intake_requests(enterprise_id,status,created_at desc);
create index if not exists intake_requests_sla_idx
  on public.intake_requests(enterprise_id,status,sla_due_at);
create index if not exists intake_requests_requester_idx
  on public.intake_requests(requester_profile_id,created_at desc);
create index if not exists intake_conversions_request_idx
  on public.intake_conversions(request_id,created_at);
create index if not exists intake_messages_request_idx
  on public.intake_messages(request_id,created_at);
create index if not exists intake_submission_attempts_idx
  on public.intake_submission_attempts(form_id,email_hash,created_at desc);
create index if not exists intake_notifications_pending_idx
  on public.intake_notifications(status,created_at);

alter table public.intake_settings enable row level security;
alter table public.intake_forms enable row level security;
alter table public.intake_requests enable row level security;
alter table public.intake_messages enable row level security;
alter table public.intake_links enable row level security;
alter table public.intake_events enable row level security;
alter table public.intake_security_audit enable row level security;
alter table public.intake_submission_attempts enable row level security;
alter table public.intake_email_aliases enable row level security;
alter table public.intake_notifications enable row level security;
alter table public.presales_opportunities enable row level security;
alter table public.intake_conversions enable row level security;

revoke all on table public.intake_settings from public, anon, authenticated;
revoke all on table public.intake_forms from public, anon, authenticated;
revoke all on table public.intake_requests from public, anon, authenticated;
revoke all on table public.intake_messages from public, anon, authenticated;
revoke all on table public.intake_links from public, anon, authenticated;
revoke all on table public.intake_events from public, anon, authenticated;
revoke all on table public.intake_security_audit from public, anon, authenticated;
revoke all on table public.intake_submission_attempts from public, anon, authenticated;
revoke all on table public.intake_email_aliases from public, anon, authenticated;
revoke all on table public.intake_notifications from public, anon, authenticated;
revoke all on table public.presales_opportunities from public, anon, authenticated;
revoke all on table public.intake_conversions from public, anon, authenticated;

create or replace function public._intake_current_enterprise(p_uid uuid)
returns uuid
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select coalesce(
    (select e.id from public.enterprises e
      where e.owner_profile_id=p_uid limit 1),
    (select m.enterprise_id from public.enterprise_members m
      where m.profile_id=p_uid and m.status='active'
      order by m.updated_at desc limit 1)
  );
$fn$;

create or replace function public._intake_is_member(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select p_uid is not null and exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
  );
$fn$;

create or replace function public._intake_has_permission(
  p_eid uuid,p_uid uuid,p_permissions text[]
) returns boolean
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_grant jsonb;
begin
  if p_uid is null or not exists(
    select 1 from public.enterprise_members m
     where m.enterprise_id=p_eid and m.profile_id=p_uid and m.status='active'
  ) then return false; end if;
  if exists(select 1 from public.enterprises e
    where e.id=p_eid and e.owner_profile_id=p_uid) then return true; end if;
  for v_grant in
    select value from jsonb_array_elements(
      public._identity_role_permissions(p_eid,p_uid)
    )
  loop
    if (v_grant #>> '{}') = any(p_permissions) then return true; end if;
    if jsonb_typeof(v_grant)='object'
       and coalesce(v_grant->>'permission_key','') = any(p_permissions) then
      return true;
    end if;
  end loop;
  return false;
end;
$fn$;

create or replace function public._intake_can_manage(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select public._intake_has_permission(
    p_eid,p_uid,
    array['company.manage','projects.manage','tasks.assign','reports.view']::text[]
  );
$fn$;

create or replace function public._intake_is_executive(p_eid uuid,p_uid uuid)
returns boolean
language sql stable security definer
set search_path=public,auth,pg_temp
as $fn$
  select exists(select 1 from public.enterprises e
    where e.id=p_eid and e.owner_profile_id=p_uid)
    or public._intake_has_permission(
      p_eid,p_uid,array['company.manage','governance.vote']::text[]);
$fn$;

create or replace function public._intake_safe_number(
  p_value text,p_default numeric,p_min numeric,p_max numeric
) returns numeric
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_value numeric;
begin
  begin v_value:=nullif(btrim(coalesce(p_value,'')),'')::numeric;
  exception when others then v_value:=null; end;
  return least(greatest(coalesce(v_value,p_default),p_min),p_max);
end;
$fn$;

create or replace function public._intake_type(p_type text)
returns text
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_type text:=lower(btrim(coalesce(p_type,'')));
begin
  if v_type in ('customer',U&'\5BA2\6237',U&'\5BA2\6237\9700\6C42') then return 'customer'; end if;
  if v_type in ('sales',U&'\9500\552E',U&'\9500\552E\673A\4F1A') then return 'sales'; end if;
  if v_type in ('improvement',U&'\5185\90E8\6539\8FDB') then return 'improvement'; end if;
  if v_type in ('incident','fault',U&'\6545\969C') then return 'incident'; end if;
  if v_type in ('temporary',U&'\4E34\65F6',U&'\4E34\65F6\4E8B\9879') then return 'temporary'; end if;
  return 'temporary';
end;
$fn$;

create or replace function public._intake_sla_interval(p_type text)
returns interval
language sql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
  select case public._intake_type(p_type)
    when 'incident' then interval '2 hours'
    when 'customer' then interval '1 day'
    when 'improvement' then interval '3 days'
    else interval '1 day' end;
$fn$;

create or replace function public._intake_priority(p_data jsonb)
returns jsonb
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_business numeric:=public._intake_safe_number(p_data->>'business_value',0,0,5);
  v_urgency numeric:=public._intake_safe_number(p_data->>'urgency',0,0,5);
  v_risk numeric:=public._intake_safe_number(p_data->>'risk',0,0,5);
  v_dependency numeric:=public._intake_safe_number(p_data->>'dependency_impact',0,0,5);
  v_effort numeric:=public._intake_safe_number(p_data->>'effort',0,0,5);
  v_score numeric;
begin
  v_score:=v_business*5+v_urgency*4+v_risk*3+v_dependency*2-v_effort*2;
  return jsonb_build_object(
    'score',v_score,
    'factors',jsonb_build_array(
      jsonb_build_object('key','business_value','label','Business value','value',v_business,'weight',5,'points',v_business*5,'reason','business value x 5'),
      jsonb_build_object('key','urgency','label','Urgency','value',v_urgency,'weight',4,'points',v_urgency*4,'reason','urgency x 4'),
      jsonb_build_object('key','risk','label','Risk','value',v_risk,'weight',3,'points',v_risk*3,'reason','risk x 3'),
      jsonb_build_object('key','dependency_impact','label','Dependency impact','value',v_dependency,'weight',2,'points',v_dependency*2,'reason','dependency impact x 2'),
      jsonb_build_object('key','effort','label','Effort','value',v_effort,'weight',-2,'points',v_effort*-2,'reason','effort x -2')
    ),
    'explanation','server-computed weighted score'
  );
end;
$fn$;

create or replace function public._intake_tracking_code()
returns text
language sql volatile security definer
set search_path=public,auth,pg_temp
as $fn$
  select upper(substr(md5(clock_timestamp()::text || random()::text || gen_random_uuid()::text),1,8));
$fn$;

create or replace function public._intake_public_token()
returns text
language sql volatile security definer
set search_path=public,auth,pg_temp
as $fn$
  select lower(substr(md5(clock_timestamp()::text || random()::text || gen_random_uuid()::text),1,32));
$fn$;

create or replace function public._intake_similarity(p_left text,p_right text)
returns numeric
language plpgsql immutable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_left text:=regexp_replace(lower(coalesce(p_left,'')),'[[:space:][:punct:]]','','g');
  v_right text:=regexp_replace(lower(coalesce(p_right,'')),'[[:space:][:punct:]]','','g');
  v_len integer;
  v_matches integer:=0;
  v_gram text;
  i integer;
begin
  if v_left='' or v_right='' then return 0; end if;
  v_len:=greatest(length(v_left)-1,1);
  for i in 1..v_len loop
    v_gram:=substr(v_left,i,2);
    if v_gram<>'' and position(v_gram in v_right)>0 then v_matches:=v_matches+1; end if;
  end loop;
  return round((2.0*v_matches)::numeric/(length(v_left)+length(v_right)),4);
end;
$fn$;

create or replace function public._intake_denied(
  p_eid uuid,p_uid uuid,p_operation text,p_reason text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.intake_security_audit(
    enterprise_id,actor_profile_id,operation,reason,payload
  ) values(p_eid,p_uid,p_operation,p_reason,coalesce(p_payload,'{}'::jsonb));
  return jsonb_build_object(
    'ok',false,'code','permission_denied','error',p_reason
  );
end;
$fn$;

create or replace function public._intake_success(
  p_eid uuid,p_uid uuid,p_operation text,p_request uuid,
  p_action text,p_before jsonb,p_after jsonb,p_payload jsonb default '{}'::jsonb
) returns void
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
begin
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(
    p_eid,p_uid,p_operation,null,
    jsonb_build_object(
      'request_id',p_request,'action',p_action,
      'before',coalesce(p_before,'{}'::jsonb),
      'after',coalesce(p_after,'{}'::jsonb),
      'payload',coalesce(p_payload,'{}'::jsonb)
    )
  );
end;
$fn$;

create or replace function public._intake_event(
  p_request uuid,p_uid uuid,p_action text,p_from text,p_to text,
  p_payload jsonb default '{}'::jsonb
) returns void
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  insert into public.intake_events(
    request_id,actor_profile_id,action,from_status,to_status,payload
  ) values(
    p_request,p_uid,p_action,coalesce(p_from,''),coalesce(p_to,''),
    coalesce(p_payload,'{}'::jsonb)
  );
$fn$;

create or replace function public._intake_notify(
  p_request uuid,p_kind text,p_subject text,p_body text
) returns void
language sql security definer
set search_path=public,auth,pg_temp
as $fn$
  insert into public.intake_notifications(
    request_id,recipient_email,kind,subject,body
  )
  select p_request,nullif(lower(btrim(r.requester_email)),''),p_kind,p_subject,p_body
    from public.intake_requests r
   where r.id=p_request and btrim(r.requester_email)<>'';
$fn$;

create or replace function public._intake_escalate_due(p_eid uuid)
returns integer
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_owner uuid;
  v_row public.intake_requests%rowtype;
  v_count integer:=0;
begin
  select e.owner_profile_id into v_owner
    from public.enterprises e where e.id=p_eid;
  for v_row in
    select * from public.intake_requests r
     where r.enterprise_id=p_eid and r.status='submitted'
       and r.sla_due_at<=now() and r.escalated_at is null
     for update
  loop
    update public.intake_requests set
      status='triage',
      owner_profile_id=coalesce(owner_profile_id,v_owner),
      priority_score=priority_score+10,
      escalated_at=now(),
      version=version+1,
      updated_at=now()
    where id=v_row.id;
    perform public._intake_event(
      v_row.id,null,'sla.escalated','submitted','triage',
      jsonb_build_object('owner_profile_id',coalesce(v_row.owner_profile_id,v_owner))
    );
    perform public._intake_notify(
      v_row.id,'sla','Request escalated',
      'The request exceeded its triage SLA and was escalated.'
    );
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$fn$;

-- ---------------------------------------------------------- forms and board
create or replace function public.create_intake_form(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_name text:=btrim(coalesce(p_data->>'name','Work intake'));
  v_token text;
  v_types text[];
  v_row public.intake_forms%rowtype;
  v_base text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_form','projects.manage authority required');
  end if;
  select coalesce(array_agg(public._intake_type(value)),array['customer','sales','improvement','incident','temporary']::text[])
    into v_types
    from jsonb_array_elements_text(coalesce(p_data->'allowed_types','[]'::jsonb)) value;
  if v_types is null or cardinality(v_types)=0 then
    v_types:=array['customer','sales','improvement','incident','temporary']::text[];
  end if;
  loop
    v_token:=public._intake_public_token();
    exit when not exists(select 1 from public.intake_forms f where f.public_token=v_token);
  end loop;
  insert into public.intake_forms(
    enterprise_id,name,public_token,allowed_types,created_by
  ) values(v_eid,coalesce(nullif(v_name,''),'Work intake'),v_token,v_types,v_uid)
  returning * into v_row;
  select coalesce(s.public_form_base_url,'') into v_base
    from public.intake_settings s where s.enterprise_id=v_eid;
  v_base:=coalesce(nullif(rtrim(v_base,'/'),''),'');
  perform public._intake_success(
    v_eid,v_uid,'intake_form',v_row.id,'form.created','{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('name',v_row.name)
  );
  return jsonb_build_object(
    'ok',true,'form',to_jsonb(v_row),
    'public_url',case when v_base='' then '/intake.html?token='||v_row.public_token
      else v_base||'/intake.html?token='||v_row.public_token end
  );
end;
$fn$;

create or replace function public.update_intake_form(
  p_form uuid,p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_forms%rowtype;
  v_before jsonb;
  v_types text[];
  v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_forms where id=p_form for update;
  if not found then raise exception 'intake form not found'; end if;
  v_eid:=v_row.enterprise_id;
  if not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'update_intake_form','projects.manage authority required');
  end if;
  select coalesce(array_agg(public._intake_type(value)),v_row.allowed_types)
    into v_types
    from jsonb_array_elements_text(coalesce(p_data->'allowed_types',to_jsonb(v_row.allowed_types))) value;
  v_before:=to_jsonb(v_row);
  update public.intake_forms set
    name=coalesce(nullif(btrim(p_data->>'name'),''),name),
    allowed_types=coalesce(v_types,allowed_types),
    active=case when p_data ? 'active' then (p_data->>'active')::boolean else active end,
    updated_at=now()
  where id=p_form returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_form',p_form,'form.updated',v_before,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'form',to_jsonb(v_row));
end;
$fn$;

create or replace function public.get_intake_board(p_enterprise uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=coalesce(p_enterprise,public._intake_current_enterprise(auth.uid()));
  v_settings public.intake_settings%rowtype;
  v_base text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    return public._intake_denied(null,v_uid,'get_intake_board','enterprise not found');
  end if;
  if not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'get_intake_board','projects.manage authority required');
  end if;
  perform public._intake_escalate_due(v_eid);
  select * into v_settings from public.intake_settings where enterprise_id=v_eid;
  v_base:=coalesce(nullif(rtrim(v_settings.public_form_base_url,'/'),''),'');
  return jsonb_build_object(
    'ok',true,
    'enterprise_id',v_eid,
    'settings',jsonb_build_object(
      'email_domain',coalesce(v_settings.email_domain,'inbound.projectrecorder.local'),
      'public_form_base_url',v_base
    ),
    'forms',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',f.id,'name',f.name,'active',f.active,
        'allowed_types',f.allowed_types,'public_token',f.public_token,
        'public_url',case when v_base='' then '/intake.html?token='||f.public_token
          else v_base||'/intake.html?token='||f.public_token end,
        'created_at',f.created_at
      ) order by f.created_at desc),'[]'::jsonb)
      from public.intake_forms f where f.enterprise_id=v_eid
    ),
    'email_aliases',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',a.id,'label',a.label,'email_address',a.email_address,
        'active',a.active,'created_at',a.created_at
      ) order by a.created_at desc),'[]'::jsonb)
      from public.intake_email_aliases a where a.enterprise_id=v_eid
    ),
    'requests',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',r.id,'request_no',r.request_no,'source_type',r.source_type,
        'request_type',r.request_type,'title',r.title,'detail',r.detail,
        'requester_name',r.requester_name,'requester_email',r.requester_email,
        'status',r.status,'priority_score',r.priority_score,
        'priority_factors',r.priority_factors,
        'priority_override',r.priority_override,
        'priority_override_reason',r.priority_override_reason,
        'owner_profile_id',r.owner_profile_id,'owner_name',op.name,
        'sla_due_at',r.sla_due_at,'first_response_at',r.first_response_at,
        'escalated_at',r.escalated_at,'resolved_at',r.resolved_at,
        'sla_overdue',r.status in ('submitted','triage','in_progress') and r.sla_due_at<now(),
        'merged_into_id',r.merged_into_id,'converted_kind',r.converted_kind,
        'converted_at',r.converted_at,'linked_project_id',r.linked_project_id,
        'linked_project_name',pr.name,'linked_task_id',r.linked_task_id,
        'linked_task_title',t.title,'presales_owner_id',r.presales_owner_id,
        'conversions',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',c.id,'kind',c.kind,'linked_id',c.linked_id,
            'payload',c.payload,'created_at',c.created_at
          ) order by c.created_at)
          from public.intake_conversions c where c.request_id=r.id
        ),'[]'::jsonb),
        'created_at',r.created_at,'updated_at',r.updated_at,
        'actions',jsonb_build_object(
          'triage',true,'merge',r.status<>'merged','convert',r.status<>'merged'
        ),
        'messages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'id',m.id,'author_profile_id',m.author_profile_id,
            'author_label',m.author_label,'visibility',m.visibility,
            'body',m.body,'created_at',m.created_at
          ) order by m.created_at)
          from public.intake_messages m where m.request_id=r.id
        ),'[]'::jsonb),
        'links',coalesce((
          select jsonb_agg(jsonb_build_object(
            'linked_request_id',l.linked_request_id,'link_type',l.link_type,
            'note',l.note
          ) order by l.created_at)
          from public.intake_links l where l.request_id=r.id
        ),'[]'::jsonb)
      ) order by r.priority_score desc,r.created_at desc),'[]'::jsonb)
      from (
        select * from public.intake_requests
         where enterprise_id=v_eid
         order by priority_score desc,created_at desc limit 300
      ) r
      left join public.profiles op on op.id=r.owner_profile_id
      left join public.projects pr on pr.id=r.linked_project_id
      left join public.tasks t on t.id=r.linked_task_id
    ),
    'projects',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',p.id,'name',p.name,'boss_id',p.boss_id
      ) order by p.name),'[]'::jsonb)
      from public.projects p
      where exists(
        select 1 from public.enterprise_members m
         where m.enterprise_id=v_eid and m.profile_id=p.boss_id and m.status='active'
      )
    ),
    'tasks',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',x.id,'title',x.title,'project_id',x.project_id,
        'employee_id',x.employee_id
      ) order by x.plan_date desc,x.title),'[]'::jsonb)
      from (
        select t.id,t.title,t.project_id,t.employee_id,t.plan_date
          from public.tasks t
          join public.projects p on p.id=t.project_id
         where exists(
           select 1 from public.enterprise_members m
            where m.enterprise_id=v_eid and m.profile_id=p.boss_id and m.status='active'
         )
         order by t.plan_date desc,t.title limit 500
      ) x
    ),
    'members',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',m.profile_id,'name',p.name,'department',m.department,
        'role_key',m.role_key
      ) order by p.name),'[]'::jsonb)
      from public.enterprise_members m
      join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid and m.status='active'
    ),
    'access',jsonb_build_object(
      'management',true,'can_create_form',true,
      'can_merge',true,'can_convert',true
    ),
    'generated_at',now()
  );
end;
$fn$;

create or replace function public.get_my_intake_requests()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'ok',true,
    'requests',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',r.id,'request_no',r.request_no,'tracking_code',r.tracking_code,
        'source_type',r.source_type,'request_type',r.request_type,
        'title',r.title,'detail',r.detail,'status',r.status,
        'priority_score',r.priority_score,'sla_due_at',r.sla_due_at,
        'resolved_at',r.resolved_at,'converted_kind',r.converted_kind,
        'created_at',r.created_at,
        'messages',coalesce((
          select jsonb_agg(jsonb_build_object(
            'body',m.body,'created_at',m.created_at,
            'author_label',m.author_label
          ) order by m.created_at)
          from public.intake_messages m
          where m.request_id=r.id and m.visibility='public'
        ),'[]'::jsonb)
      ) order by r.created_at desc),'[]'::jsonb)
      from (
        select * from public.intake_requests
        where requester_profile_id=v_uid or owner_profile_id=v_uid
        order by created_at desc limit 200
      ) r
    )
  );
end;
$fn$;

create or replace function public.get_public_intake_form(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_row record;
begin
  select f.id,f.name,f.allowed_types,f.enterprise_id,e.name enterprise_name
    into v_row
    from public.intake_forms f
    join public.enterprises e on e.id=f.enterprise_id
   where f.public_token=btrim(coalesce(p_token,'')) and f.active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_form','error','form not available');
  end if;
  return jsonb_build_object(
    'ok',true,'form_id',v_row.id,'form_name',v_row.name,
    'enterprise_name',v_row.enterprise_name,
    'allowed_types',v_row.allowed_types
  );
end;
$fn$;

-- ---------------------------------------------------------- quick/public intake
create or replace function public.create_intake_request(p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_detail text:=btrim(coalesce(v_data->>'detail',''));
  v_type text:=public._intake_type(v_data->>'request_type');
  v_source text:=lower(btrim(coalesce(v_data->>'source_type','quick')));
  v_priority jsonb:=public._intake_priority(v_data);
  v_score numeric;
  v_override numeric;
  v_reason text:=btrim(coalesce(v_data->>'priority_override_reason',''));
  v_row public.intake_requests%rowtype;
  v_name text;
  v_duplicates jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_is_member(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_request','active enterprise membership required');
  end if;
  if v_title='' or length(v_detail)<5 then
    raise exception 'title and detail are required';
  end if;
  if v_source not in ('quick','internal','wechat') then v_source:='quick'; end if;
  select coalesce(name,code,'Member') into v_name from public.profiles where id=v_uid;
  v_score:=coalesce((v_priority->>'score')::numeric,0);
  if v_data ? 'priority_override' and nullif(btrim(v_data->>'priority_override'),'') is not null then
    if not public._intake_can_manage(v_eid,v_uid) then
      return public._intake_denied(v_eid,v_uid,'create_intake_request','priority override requires management authority');
    end if;
    if v_reason='' then raise exception 'priority override reason required'; end if;
    v_override:=public._intake_safe_number(v_data->>'priority_override',v_score,0,100);
    v_score:=v_override;
  end if;
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_profile_id,requester_name,tracking_code,
    priority_score,priority_factors,priority_override,priority_override_reason,
    sla_due_at,status,source_ref
  ) values(
    v_eid,v_source,v_type,v_title,v_detail,
    v_uid,coalesce(v_name,'Member'),public._intake_tracking_code(),
    v_score,v_priority->'factors',v_override,v_reason,
    now()+public._intake_sla_interval(v_type),'submitted',
    btrim(coalesce(v_data->>'source_ref',''))
  ) returning * into v_row;
  perform public._intake_event(v_row.id,v_uid,'request.created','','submitted',
    jsonb_build_object('source_type',v_source));
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    v_row.id,v_uid,'System','public','Your request has been received and is waiting for triage.'
  );
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',x.id,'request_no',x.request_no,'title',x.title,
    'similarity',x.similarity
  ) order by x.similarity desc),'[]'::jsonb)
    into v_duplicates
    from (
      select r.id,r.request_no,r.title,
        public._intake_similarity(v_title||' '||v_detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_eid and r.id<>v_row.id
       order by r.created_at desc limit 200
    ) x
    where x.similarity>=0.35
    limit 5;
  perform public._intake_success(
    v_eid,v_uid,'intake_request',v_row.id,'request.created','{}'::jsonb,to_jsonb(v_row),
    jsonb_build_object('duplicate_count',jsonb_array_length(v_duplicates))
  );
  return jsonb_build_object(
    'ok',true,'request_id',v_row.id,'request_no',v_row.request_no,
    'tracking_code',v_row.tracking_code,'sla_due_at',v_row.sla_due_at,
    'priority',v_priority,'duplicates',v_duplicates
  );
end;
$fn$;

create or replace function public.submit_public_intake(p_token text,p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_form public.intake_forms%rowtype;
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_type text:=public._intake_type(v_data->>'request_type');
  v_title text:=btrim(coalesce(v_data->>'title',''));
  v_detail text:=btrim(coalesce(v_data->>'detail',''));
  v_name text:=btrim(coalesce(v_data->>'requester_name',''));
  v_email text:=lower(btrim(coalesce(v_data->>'requester_email','')));
  v_consent boolean:=coalesce((v_data->>'consent')::boolean,false);
  v_priority jsonb:=public._intake_priority(v_data);
  v_row public.intake_requests%rowtype;
  v_count integer;
  v_hash text;
  v_duplicate_count integer;
begin
  select * into v_form from public.intake_forms
   where public_token=btrim(coalesce(p_token,'')) and active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_form','error','form not available');
  end if;
  if v_title='' or length(v_detail)<5 or v_name=''
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or not v_consent then
    return jsonb_build_object('ok',false,'code','invalid_input','error','valid contact, consent, title, and detail are required');
  end if;
  if cardinality(v_form.allowed_types)>0 and not (v_type=any(v_form.allowed_types)) then
    return jsonb_build_object('ok',false,'code','invalid_type','error','request type is not allowed on this form');
  end if;
  v_hash:=md5(v_email);
  select count(*) into v_count
    from public.intake_submission_attempts a
   where a.form_id=v_form.id and a.email_hash=v_hash
     and a.created_at>now()-interval '10 minutes';
  if v_count>=5 then
    insert into public.intake_security_audit(
      enterprise_id,actor_profile_id,operation,reason,payload
    ) values(v_form.enterprise_id,null,'submit_public_intake','rate limit',
      jsonb_build_object('form_id',v_form.id,'email_hash',v_hash));
    return jsonb_build_object('ok',false,'code','rate_limited','error','too many submissions; try again later');
  end if;
  insert into public.intake_submission_attempts(form_id,email_hash)
    values(v_form.id,v_hash);
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_name,requester_email,tracking_code,form_id,
    priority_score,priority_factors,sla_due_at,status
  ) values(
    v_form.enterprise_id,'public_form',v_type,v_title,v_detail,
    v_name,v_email,public._intake_tracking_code(),v_form.id,
    coalesce((v_priority->>'score')::numeric,0),v_priority->'factors',
    now()+public._intake_sla_interval(v_type),'submitted'
  ) returning * into v_row;
  perform public._intake_event(v_row.id,null,'request.created','','submitted',
    jsonb_build_object('source_type','public_form'));
  insert into public.intake_messages(
    request_id,author_label,visibility,body
  ) values(v_row.id,'System','public','Your request has been received and is waiting for triage.');
  perform public._intake_notify(
    v_row.id,'receipt','Request received',
    'Your request was received. Keep the tracking code and email address for status lookup.'
  );
  select count(*) into v_duplicate_count
    from (
      select public._intake_similarity(v_title||' '||v_detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_form.enterprise_id and r.id<>v_row.id
       order by r.created_at desc limit 200
    ) x where x.similarity>=0.35;
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'sla_due_at',v_row.sla_due_at,'duplicate_count',v_duplicate_count,
    'message','Submission received'
  );
end;
$fn$;

create or replace function public.get_public_intake_status(
  p_tracking_code text,p_email text
) returns jsonb
language plpgsql stable security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_row public.intake_requests%rowtype;
  v_messages jsonb;
begin
  select * into v_row from public.intake_requests
   where tracking_code=upper(btrim(coalesce(p_tracking_code,'')))
     and requester_email<>''
     and lower(btrim(requester_email))=lower(btrim(coalesce(p_email,'')));
  if not found then
    return jsonb_build_object('ok',false,'code','not_found','error','request not found');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'body',m.body,'created_at',m.created_at,'author_label',m.author_label
  ) order by m.created_at),'[]'::jsonb)
    into v_messages
    from public.intake_messages m
   where m.request_id=v_row.id and m.visibility='public';
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'request_type',v_row.request_type,'title',v_row.title,'status',v_row.status,
    'created_at',v_row.created_at,'sla_due_at',v_row.sla_due_at,
    'resolved_at',v_row.resolved_at,'messages',v_messages
  );
end;
$fn$;

create or replace function public.ingest_intake_email(
  p_alias_token text,p_from text,p_subject text,p_body text,
  p_request_type text default 'customer'
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_alias public.intake_email_aliases%rowtype;
  v_type text:=public._intake_type(p_request_type);
  v_from text:=lower(btrim(coalesce(p_from,'')));
  v_subject text:=btrim(coalesce(p_subject,''));
  v_body text:=btrim(coalesce(p_body,''));
  v_hash text;
  v_count integer;
  v_row public.intake_requests%rowtype;
  v_priority jsonb:=public._intake_priority('{}'::jsonb);
begin
  select * into v_alias from public.intake_email_aliases
   where alias_token=btrim(coalesce(p_alias_token,'')) and active;
  if not found then
    return jsonb_build_object('ok',false,'code','invalid_alias','error','email alias not available');
  end if;
  if v_from !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     or v_subject='' or length(v_body)<5 then
    return jsonb_build_object('ok',false,'code','invalid_input','error','sender, subject, and body are required');
  end if;
  v_hash:=md5(btrim(coalesce(p_alias_token,''))||v_from);
  select count(*) into v_count from public.intake_submission_attempts a
   where a.form_id is null and a.email_hash=v_hash
     and a.created_at>now()-interval '10 minutes';
  if v_count>=10 then
    return jsonb_build_object('ok',false,'code','rate_limited','error','too many messages');
  end if;
  insert into public.intake_submission_attempts(form_id,email_hash)
    values(null,v_hash);
  insert into public.intake_requests(
    enterprise_id,source_type,request_type,title,detail,
    requester_name,requester_email,tracking_code,
    priority_score,priority_factors,sla_due_at,status,source_ref
  ) values(
    v_alias.enterprise_id,'email',v_type,v_subject,v_body,
    split_part(v_from,'@',1),v_from,public._intake_tracking_code(),
    coalesce((v_priority->>'score')::numeric,0),v_priority->'factors',
    now()+public._intake_sla_interval(v_type),'submitted',v_alias.email_address
  ) returning * into v_row;
  perform public._intake_event(v_row.id,null,'request.created','','submitted',
    jsonb_build_object('source_type','email','alias',v_alias.email_address));
  insert into public.intake_messages(
    request_id,author_label,visibility,body
  ) values(v_row.id,'System','public','Your email was received and is waiting for triage.');
  perform public._intake_notify(
    v_row.id,'receipt','Email request received',
    'Your email was received. Keep the tracking code and email address for status lookup.'
  );
  return jsonb_build_object(
    'ok',true,'tracking_code',v_row.tracking_code,'request_no',v_row.request_no,
    'sla_due_at',v_row.sla_due_at
  );
end;
$fn$;

-- ---------------------------------------------------------- triage and messages
create or replace function public.triage_intake_request(
  p_request uuid,
  p_owner uuid default null,
  p_request_type text default null,
  p_priority_override numeric default null,
  p_reason text default '',
  p_status text default 'triage'
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_before jsonb;
  v_type text;
  v_status text:=lower(btrim(coalesce(p_status,'triage')));
  v_score numeric;
  v_reason text:=btrim(coalesce(p_reason,''));
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'triage_intake_request','projects.manage authority required');
  end if;
  if v_row.status='merged' then raise exception 'merged requests cannot be triaged'; end if;
  if v_status not in ('triage','in_progress','resolved','closed') then
    raise exception 'invalid triage status';
  end if;
  if p_owner is not null and not public._intake_is_member(v_row.enterprise_id,p_owner) then
    raise exception 'owner must be an active enterprise member';
  end if;
  if p_priority_override is not null and v_reason='' then
    raise exception 'priority override reason required';
  end if;
  if p_request_type is not null then
    v_type:=public._intake_type(p_request_type);
  else
    v_type:=v_row.request_type;
  end if;
  v_score:=case when p_priority_override is null then v_row.priority_score
    else public._intake_safe_number(p_priority_override::text,v_row.priority_score,0,100) end;
  v_before:=to_jsonb(v_row);
  update public.intake_requests set
    status=v_status,
    owner_profile_id=coalesce(p_owner,owner_profile_id),
    request_type=v_type,
    priority_score=v_score,
    priority_override=case when p_priority_override is null then priority_override else v_score end,
    priority_override_reason=case when p_priority_override is null then priority_override_reason else v_reason end,
    first_response_at=coalesce(first_response_at,now()),
    resolved_at=case when v_status in ('resolved','closed') then coalesce(resolved_at,now()) else resolved_at end,
    sla_due_at=case when p_request_type is null then sla_due_at
      else created_at+public._intake_sla_interval(v_type) end,
    version=version+1,
    updated_at=now()
  where id=p_request returning * into v_row;
  perform public._intake_event(
    p_request,v_uid,'request.triaged',v_before->>'status',v_status,
    jsonb_build_object('owner_profile_id',v_row.owner_profile_id,
      'request_type',v_row.request_type,'priority_score',v_score)
  );
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) select v_row.id,v_uid,coalesce(p.name,'Coordinator'),'public',
    'Request triaged. Current status: '||v_status||'.'
    from public.profiles p where p.id=v_uid;
  perform public._intake_notify(
    p_request,'status','Request status updated',
    'Your request status is now '||v_status||'.'
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'request.triaged',
    v_before,to_jsonb(v_row),jsonb_build_object('reason',v_reason)
  );
  return jsonb_build_object(
    'ok',true,'request_id',v_row.id,'status',v_row.status,
    'owner_profile_id',v_row.owner_profile_id,
    'request_type',v_row.request_type,'priority_score',v_row.priority_score
  );
end;
$fn$;

create or replace function public.add_intake_message(
  p_request uuid,p_body text,p_public boolean default true
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_body text:=btrim(coalesce(p_body,''));
  v_name text;
  v_manager boolean;
  v_requester boolean;
  v_visibility text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  v_manager:=public._intake_can_manage(v_row.enterprise_id,v_uid);
  v_requester:=v_row.requester_profile_id=v_uid;
  if not v_manager and not v_requester then
    return public._intake_denied(v_row.enterprise_id,v_uid,'add_intake_message','requester or manager authority required');
  end if;
  if v_body='' or length(v_body)>8000 then raise exception 'message is empty or too long'; end if;
  if p_public and length(v_body)>4000 then raise exception 'public message is too long'; end if;
  if not v_manager and not p_public then
    return public._intake_denied(v_row.enterprise_id,v_uid,'add_intake_message','only managers can add internal notes');
  end if;
  if v_row.status in ('closed','merged') then raise exception 'request is closed'; end if;
  v_visibility:=case when p_public then 'public' else 'internal' end;
  select coalesce(name,code,'Member') into v_name from public.profiles where id=v_uid;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(p_request,v_uid,coalesce(v_name,'Member'),v_visibility,v_body);
  if v_manager and v_visibility='public' then
    update public.intake_requests set
      first_response_at=coalesce(first_response_at,now()),version=version+1,updated_at=now()
    where id=p_request;
    perform public._intake_notify(
      p_request,'message','New reply to your request',v_body
    );
  end if;
  perform public._intake_event(
    p_request,v_uid,'message.'||v_visibility,'','',
    jsonb_build_object('body_length',length(v_body))
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'message.'||v_visibility,
    '{}'::jsonb,jsonb_build_object('visibility',v_visibility,'body',v_body)
  );
  return jsonb_build_object('ok',true,'request_id',p_request,'visibility',v_visibility);
end;
$fn$;

create or replace function public.find_intake_duplicates(
  p_request uuid,p_limit integer default 5
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_limit integer:=least(greatest(coalesce(p_limit,5),1),20);
begin
  select * into v_row from public.intake_requests where id=p_request;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'find_intake_duplicates','projects.manage authority required');
  end if;
  return jsonb_build_object('ok',true,'duplicates',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',x.id,'request_no',x.request_no,'title',x.title,
      'status',x.status,'similarity',x.similarity
    ) order by x.similarity desc),'[]'::jsonb)
    from (
      select r.id,r.request_no,r.title,r.status,
        public._intake_similarity(v_row.title||' '||v_row.detail,r.title||' '||r.detail) similarity
        from public.intake_requests r
       where r.enterprise_id=v_row.enterprise_id and r.id<>v_row.id
         and r.status<>'merged'
       order by r.created_at desc limit 200
    ) x where x.similarity>=0.3 order by x.similarity desc limit v_limit
  ));
end;
$fn$;

create or replace function public.merge_intake_request(
  p_source uuid,p_target uuid,p_note text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_source public.intake_requests%rowtype;
  v_target public.intake_requests%rowtype;
  v_before jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_source=p_target then raise exception 'cannot merge a request into itself'; end if;
  select * into v_source from public.intake_requests where id=p_source for update;
  if not found then raise exception 'source request not found'; end if;
  select * into v_target from public.intake_requests where id=p_target for update;
  if not found then raise exception 'target request not found'; end if;
  if v_source.enterprise_id<>v_target.enterprise_id then raise exception 'requests must belong to the same enterprise'; end if;
  if not public._intake_can_manage(v_source.enterprise_id,v_uid) then
    return public._intake_denied(v_source.enterprise_id,v_uid,'merge_intake_request','projects.manage authority required');
  end if;
  if v_source.status='merged' then raise exception 'source request is already merged'; end if;
  if v_target.status='merged' then raise exception 'target request is merged'; end if;
  v_before:=to_jsonb(v_source);
  insert into public.intake_links(request_id,linked_request_id,link_type,note,created_by)
    values(p_source,p_target,'duplicate',btrim(coalesce(p_note,'')),v_uid)
    on conflict (request_id,linked_request_id,link_type) do nothing;
  insert into public.intake_links(request_id,linked_request_id,link_type,note,created_by)
    values(p_target,p_source,'related',btrim(coalesce(p_note,'')),v_uid)
    on conflict (request_id,linked_request_id,link_type) do nothing;
  insert into public.intake_messages(
    request_id,source_request_id,author_profile_id,author_label,visibility,body,created_at
  )
  select p_target,p_source,m.author_profile_id,m.author_label,m.visibility,m.body,m.created_at
    from public.intake_messages m where m.request_id=p_source;
  update public.intake_requests set
    status='merged',merged_into_id=p_target,version=version+1,updated_at=now()
  where id=p_source;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_target,v_uid,'System','internal',
    'Merged source '||v_source.request_no||'. '||btrim(coalesce(p_note,''))
  );
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_source,v_uid,'System','public',
    'This request was merged into '||v_target.request_no||'.'
  );
  perform public._intake_event(
    p_source,v_uid,'request.merged',v_source.status,'merged',
    jsonb_build_object('target_request_id',p_target,'target_request_no',v_target.request_no)
  );
  perform public._intake_notify(
    p_source,'merged','Request merged',
    'Your request was merged into '||v_target.request_no||'.'
  );
  perform public._intake_success(
    v_source.enterprise_id,v_uid,'intake_request',p_source,'request.merged',
    v_before,to_jsonb(v_target),jsonb_build_object('target_request_id',p_target)
  );
  return jsonb_build_object(
    'ok',true,'source_id',p_source,'target_id',p_target,
    'target_request_no',v_target.request_no
  );
end;
$fn$;

-- ---------------------------------------------------------- conversion
create or replace function public.convert_intake_request(
  p_request uuid,p_kind text,p_data jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.intake_requests%rowtype;
  v_before jsonb;
  v_kind text:=lower(btrim(coalesce(p_kind,'')));
  v_data jsonb:=coalesce(p_data,'{}'::jsonb);
  v_project uuid;
  v_task uuid;
  v_presales uuid;
  v_employee uuid;
  v_project_boss uuid;
  v_project_name text;
  v_conversion uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.intake_requests where id=p_request for update;
  if not found then raise exception 'intake request not found'; end if;
  if not public._intake_can_manage(v_row.enterprise_id,v_uid) then
    return public._intake_denied(v_row.enterprise_id,v_uid,'convert_intake_request','projects.manage authority required');
  end if;
  if v_row.status in ('merged','closed') then raise exception 'request cannot be converted'; end if;
  if v_kind not in ('project','task','presales') then
    raise exception 'conversion kind must be project, task, or presales';
  end if;
  v_before:=to_jsonb(v_row);
  if v_kind='project' then
    if btrim(coalesce(v_data->>'name',''))='' then raise exception 'project name required'; end if;
    insert into public.projects(
      boss_id,name,owner,client,status,priority,start_date,due_date,
      budget,cost,progress,note
    ) values(
      v_uid,btrim(v_data->>'name'),coalesce(v_data->>'owner',''),
      coalesce(v_data->>'client',''),coalesce(v_data->>'status',U&'\8FDB\884C\4E2D'),
      coalesce(v_data->>'priority',U&'\4E2D'),
      nullif(v_data->>'start_date','')::date,
      nullif(v_data->>'due_date','')::date,
      coalesce((v_data->>'budget')::numeric,0),
      coalesce((v_data->>'cost')::numeric,0),0,
      coalesce(v_data->>'note',v_row.detail)
    ) returning id into v_project;
  elsif v_kind='task' then
    if btrim(coalesce(v_data->>'title',''))='' or not (v_data ? 'project_id')
       or not (v_data ? 'employee_id') or nullif(v_data->>'plan_date','') is null then
      raise exception 'task title, project, employee, and plan date are required';
    end if;
    select p.id,p.boss_id,p.name into v_project,v_project_boss,v_project_name
      from public.projects p where p.id=(v_data->>'project_id')::uuid;
    if v_project is null or not (
      exists(select 1 from public.enterprises e where e.id=v_row.enterprise_id and e.owner_profile_id=v_project_boss)
      or public._intake_is_member(v_row.enterprise_id,v_project_boss)
    ) then raise exception 'project does not belong to the enterprise'; end if;
    v_employee:=(v_data->>'employee_id')::uuid;
    if not public._intake_is_member(v_row.enterprise_id,v_employee) then
      raise exception 'employee is not an active enterprise member';
    end if;
    insert into public.tasks(
      boss_id,employee_id,title,detail,plan_date,est_hours,
      project_id,project_name,step_name,accept_status
    ) values(
      v_project_boss,v_employee,btrim(v_data->>'title'),
      coalesce(nullif(v_data->>'detail',''),v_row.detail),
      (v_data->>'plan_date')::date,
      greatest(coalesce((v_data->>'est_hours')::numeric,0),0),
      v_project,coalesce(v_project_name,''),coalesce(v_data->>'step_name',''),'pending'
    ) returning id into v_task;
  else
    if not (v_data ? 'owner_id') then raise exception 'presales owner required'; end if;
    v_employee:=(v_data->>'owner_id')::uuid;
    if not public._intake_is_member(v_row.enterprise_id,v_employee) then
      raise exception 'presales owner is not an active enterprise member';
    end if;
    insert into public.presales_opportunities(
      enterprise_id,request_id,title,customer_name,estimated_value,owner_profile_id,stage
    ) values(
      v_row.enterprise_id,p_request,v_row.title,
      coalesce(v_data->>'customer_name',''),
      greatest(coalesce((v_data->>'estimated_value')::numeric,0),0),
      v_employee,coalesce(v_data->>'stage','qualified')
    ) returning id into v_presales;
  end if;
  insert into public.intake_conversions(
    request_id,kind,linked_id,payload,created_by
  ) values(
    p_request,v_kind,
    case v_kind when 'project' then v_project
      when 'task' then v_task else v_presales end,
    v_data,v_uid
  ) returning id into v_conversion;
  update public.intake_requests set
    status='in_progress',
    converted_kind=v_kind,
    converted_at=now(),
    linked_project_id=case when v_kind='project' then v_project else linked_project_id end,
    linked_task_id=case when v_kind='task' then v_task else linked_task_id end,
    presales_owner_id=case when v_kind='presales' then v_employee else presales_owner_id end,
    owner_profile_id=coalesce(owner_profile_id,v_uid),
    first_response_at=coalesce(first_response_at,now()),
    version=version+1,
    updated_at=now()
  where id=p_request returning * into v_row;
  insert into public.intake_messages(
    request_id,author_profile_id,author_label,visibility,body
  ) values(
    p_request,v_uid,'System','public',
    'This request has been converted to '||v_kind||' and is now in progress.'
  );
  perform public._intake_event(
    p_request,v_uid,'request.converted','in_progress','in_progress',
    jsonb_build_object('kind',v_kind,'project_id',v_project,
      'task_id',v_task,'presales_id',v_presales)
  );
  perform public._intake_notify(
    p_request,'converted','Request converted',
    'Your request has been converted to '||v_kind||' and is now in progress.'
  );
  perform public._intake_success(
    v_row.enterprise_id,v_uid,'intake_request',p_request,'conversion.'||v_kind,
    v_before,to_jsonb(v_row),
    jsonb_build_object('project_id',v_project,'task_id',v_task,'presales_id',v_presales)
  );
  return jsonb_build_object(
    'ok',true,'request_id',p_request,'kind',v_kind,
    'project_id',v_project,'task_id',v_task,'presales_id',v_presales,
    'conversion_id',v_conversion,'status',v_row.status
  );
end;
$fn$;

-- ---------------------------------------------------------- settings and aliases
create or replace function public.upsert_intake_settings(p_data jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_row public.intake_settings%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'upsert_intake_settings','projects.manage authority required');
  end if;
  insert into public.intake_settings(enterprise_id,email_domain,public_form_base_url,updated_by)
  values(
    v_eid,coalesce(nullif(btrim(p_data->>'email_domain'),''),'inbound.projectrecorder.local'),
    btrim(coalesce(p_data->>'public_form_base_url','')),v_uid
  )
  on conflict (enterprise_id) do update set
    email_domain=coalesce(nullif(btrim(excluded.email_domain),''),public.intake_settings.email_domain),
    public_form_base_url=excluded.public_form_base_url,
    updated_by=excluded.updated_by,
    updated_at=now()
  returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_settings',v_eid,'settings.updated','{}'::jsonb,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'settings',to_jsonb(v_row));
end;
$fn$;

create or replace function public.create_intake_email_alias(p_label text default '')
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._intake_current_enterprise(auth.uid());
  v_settings public.intake_settings%rowtype;
  v_token text;
  v_domain text;
  v_address text;
  v_row public.intake_email_aliases%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'create_intake_email_alias','projects.manage authority required');
  end if;
  select * into v_settings from public.intake_settings where enterprise_id=v_eid;
  v_domain:=coalesce(nullif(v_settings.email_domain,''),'inbound.projectrecorder.local');
  loop
    v_token:=substr(public._intake_public_token(),1,16);
    exit when not exists(select 1 from public.intake_email_aliases a where a.alias_token=v_token);
  end loop;
  v_address:='intake+'||v_token||'@'||v_domain;
  insert into public.intake_email_aliases(
    enterprise_id,label,alias_token,email_address,created_by
  ) values(v_eid,btrim(coalesce(p_label,'')),v_token,v_address,v_uid)
  returning * into v_row;
  perform public._intake_success(
    v_eid,v_uid,'intake_email_alias',v_row.id,'alias.created','{}'::jsonb,to_jsonb(v_row));
  return jsonb_build_object('ok',true,'alias',to_jsonb(v_row));
end;
$fn$;

create or replace function public.intake_escalate_sla(p_enterprise uuid default null)
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=coalesce(p_enterprise,public._intake_current_enterprise(auth.uid()));
  v_count integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null or not public._intake_can_manage(v_eid,v_uid) then
    return public._intake_denied(v_eid,v_uid,'intake_escalate_sla','projects.manage authority required');
  end if;
  v_count:=public._intake_escalate_due(v_eid);
  return jsonb_build_object('ok',true,'escalated',v_count);
end;
$fn$;

-- ---------------------------------------------------------- privileges
revoke all on function public._intake_current_enterprise(uuid) from public, anon, authenticated;
revoke all on function public._intake_is_member(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_has_permission(uuid,uuid,text[]) from public, anon, authenticated;
revoke all on function public._intake_can_manage(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_is_executive(uuid,uuid) from public, anon, authenticated;
revoke all on function public._intake_safe_number(text,numeric,numeric,numeric) from public, anon, authenticated;
revoke all on function public._intake_type(text) from public, anon, authenticated;
revoke all on function public._intake_sla_interval(text) from public, anon, authenticated;
revoke all on function public._intake_priority(jsonb) from public, anon, authenticated;
revoke all on function public._intake_tracking_code() from public, anon, authenticated;
revoke all on function public._intake_public_token() from public, anon, authenticated;
revoke all on function public._intake_similarity(text,text) from public, anon, authenticated;
revoke all on function public._intake_denied(uuid,uuid,text,text,jsonb) from public, anon, authenticated;
revoke all on function public._intake_success(uuid,uuid,text,uuid,text,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public._intake_event(uuid,uuid,text,text,text,jsonb) from public, anon, authenticated;
revoke all on function public._intake_notify(uuid,text,text,text) from public, anon, authenticated;
revoke all on function public._intake_escalate_due(uuid) from public, anon, authenticated;

revoke all on function public.create_intake_form(jsonb) from public, anon, authenticated;
revoke all on function public.update_intake_form(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.get_intake_board(uuid) from public, anon, authenticated;
revoke all on function public.get_my_intake_requests() from public, anon, authenticated;
revoke all on function public.create_intake_request(jsonb) from public, anon, authenticated;
revoke all on function public.submit_public_intake(text,jsonb) from public, anon, authenticated;
revoke all on function public.get_public_intake_form(text) from public, anon, authenticated;
revoke all on function public.get_public_intake_status(text,text) from public, anon, authenticated;
revoke all on function public.ingest_intake_email(text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.triage_intake_request(uuid,uuid,text,numeric,text,text) from public, anon, authenticated;
revoke all on function public.add_intake_message(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.find_intake_duplicates(uuid,integer) from public, anon, authenticated;
revoke all on function public.merge_intake_request(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.convert_intake_request(uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.upsert_intake_settings(jsonb) from public, anon, authenticated;
revoke all on function public.create_intake_email_alias(text) from public, anon, authenticated;
revoke all on function public.intake_escalate_sla(uuid) from public, anon, authenticated;

grant execute on function public.create_intake_form(jsonb) to authenticated;
grant execute on function public.update_intake_form(uuid,jsonb) to authenticated;
grant execute on function public.get_intake_board(uuid) to authenticated;
grant execute on function public.get_my_intake_requests() to authenticated;
grant execute on function public.create_intake_request(jsonb) to authenticated;
grant execute on function public.triage_intake_request(uuid,uuid,text,numeric,text,text) to authenticated;
grant execute on function public.add_intake_message(uuid,text,boolean) to authenticated;
grant execute on function public.find_intake_duplicates(uuid,integer) to authenticated;
grant execute on function public.merge_intake_request(uuid,uuid,text) to authenticated;
grant execute on function public.convert_intake_request(uuid,text,jsonb) to authenticated;
grant execute on function public.upsert_intake_settings(jsonb) to authenticated;
grant execute on function public.create_intake_email_alias(text) to authenticated;
grant execute on function public.intake_escalate_sla(uuid) to authenticated;

grant execute on function public.submit_public_intake(text,jsonb) to anon, authenticated;
grant execute on function public.get_public_intake_form(text) to anon, authenticated;
grant execute on function public.get_public_intake_status(text,text) to anon, authenticated;
grant execute on function public.ingest_intake_email(text,text,text,text,text) to anon, authenticated;

-- Source rows are never deleted; merge preserves all source messages and links.
-- Internal notes are stored as internal messages; internal_note is never public.
-- The outbound mail worker sets Reply-To from the request alias.
