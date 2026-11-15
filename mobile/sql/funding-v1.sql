-- ============================================================
-- Funding v1: requests, approval chain, pools and settlement.
-- Currency: CNY only. Additive and idempotent. ASCII-only.
-- ============================================================

alter table public.enterprise_members
  add column if not exists reports_to_profile_id uuid
    references public.profiles(id) on delete set null;

create table if not exists public.funding_settings (
  enterprise_id uuid primary key references public.enterprises(id) on delete cascade,
  tier1_max numeric(18,2) not null default 500,
  tier2_max numeric(18,2) not null default 5000,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.funding_pools (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  name text not null,
  purpose text not null default '',
  total_amount numeric(18,2) not null default 0,
  used_amount numeric(18,2) not null default 0,
  project_id uuid,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.funding_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  applicant_profile_id uuid not null references public.profiles(id) on delete cascade,
  request_type text not null check (request_type in ('reimbursement','advance','special')),
  status text not null default 'pending'
    check (status in ('draft','pending','approved','paid','settled','rejected','cancelled')),
  amount numeric(18,2) not null check (amount > 0),
  reason text not null default '',
  category text not null default '',
  project_id uuid,
  pool_id uuid references public.funding_pools(id) on delete set null,
  budget_subject text not null default '',
  payee text not null default '',
  payment_method text not null default '',
  expected_date date,
  attachment_path text not null default '',
  receipt_path text not null default '',
  current_step integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz,
  settled_at timestamptz
);

create table if not exists public.funding_approvals (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.funding_requests(id) on delete cascade,
  step_order integer not null,
  step_kind text not null check (step_kind in ('manager','finance','owner','board')),
  approver_profile_id uuid references public.profiles(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','skipped')),
  note text not null default '',
  decided_at timestamptz,
  unique (request_id, step_order)
);

create index if not exists funding_requests_scope_idx
  on public.funding_requests(enterprise_id, created_at desc);
create index if not exists funding_approvals_pending_idx
  on public.funding_approvals(approver_profile_id, status);

alter table public.funding_settings enable row level security;
alter table public.funding_pools enable row level security;
alter table public.funding_requests enable row level security;
alter table public.funding_approvals enable row level security;

revoke all on public.funding_settings from public, anon, authenticated;
revoke all on public.funding_pools from public, anon, authenticated;
revoke all on public.funding_requests from public, anon, authenticated;
revoke all on public.funding_approvals from public, anon, authenticated;

create or replace function public._funding_eid()
returns uuid language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid(); v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not public._identity_is_member(v_eid,v_uid) then
    raise exception 'not an enterprise member';
  end if;
  return v_eid;
end;
$fn$;
revoke all on function public._funding_eid() from public,anon,authenticated;

create or replace function public._funding_can_manage(p_eid uuid,p_uid uuid)
returns boolean language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_owner uuid; v_perms jsonb;
begin
  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  v_perms:=public._identity_role_permissions(p_eid,p_uid);
  return p_uid=v_owner or v_perms ? 'finance.manage' or v_perms ? 'finance.approve_company';
end;
$fn$;
revoke all on function public._funding_can_manage(uuid,uuid) from public,anon,authenticated;

create or replace function public._funding_can_view_all(p_eid uuid,p_uid uuid)
returns boolean language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_owner uuid; v_perms jsonb;
begin
  select owner_profile_id into v_owner from public.enterprises where id=p_eid;
  v_perms:=public._identity_role_permissions(p_eid,p_uid);
  return p_uid=v_owner or v_perms ? 'finance.manage'
    or v_perms ? 'finance.view' or v_perms ? 'finance.approve_company'
    or public._identity_is_board_director(p_eid,p_uid);
end;
$fn$;
revoke all on function public._funding_can_view_all(uuid,uuid) from public,anon,authenticated;

create or replace function public.get_funding_settings()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_row public.funding_settings%rowtype;
begin
  select * into v_row from public.funding_settings where enterprise_id=v_eid;
  if not found then
    insert into public.funding_settings(enterprise_id) values(v_eid)
      on conflict (enterprise_id) do nothing;
    select * into v_row from public.funding_settings where enterprise_id=v_eid;
  end if;
  return jsonb_build_object('ok',true,'tier1_max',v_row.tier1_max,
    'tier2_max',v_row.tier2_max,'can_manage',public._funding_can_manage(v_eid,auth.uid()));
end;
$fn$;
grant execute on function public.get_funding_settings() to authenticated;
revoke all on function public.get_funding_settings() from public,anon;

create or replace function public.set_funding_settings(p_tier1 numeric,p_tier2 numeric)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid();
begin
  if not public._funding_can_manage(v_eid,v_uid) then
    raise exception 'not allowed to change funding settings';
  end if;
  insert into public.funding_settings(enterprise_id,tier1_max,tier2_max,updated_by,updated_at)
  values(v_eid,greatest(0,coalesce(p_tier1,500)),greatest(coalesce(p_tier2,5000),coalesce(p_tier1,500)),v_uid,now())
  on conflict (enterprise_id) do update set
    tier1_max=excluded.tier1_max,tier2_max=excluded.tier2_max,
    updated_by=excluded.updated_by,updated_at=now();
  return jsonb_build_object('ok',true);
end;
$fn$;
grant execute on function public.set_funding_settings(numeric,numeric) to authenticated;
revoke all on function public.set_funding_settings(numeric,numeric) from public,anon;

create or replace function public.create_funding_pool(p_name text,p_purpose text,p_total numeric,p_project uuid default null)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid(); v_id uuid;
begin
  if not public._funding_can_manage(v_eid,v_uid) then raise exception 'not allowed'; end if;
  if char_length(trim(coalesce(p_name,'')))<1 then raise exception 'pool name is required'; end if;
  insert into public.funding_pools(enterprise_id,name,purpose,total_amount,project_id,created_by)
  values(v_eid,trim(p_name),left(coalesce(p_purpose,''),1000),greatest(coalesce(p_total,0),0),p_project,v_uid)
  returning id into v_id;
  return jsonb_build_object('ok',true,'pool_id',v_id);
end;
$fn$;
grant execute on function public.create_funding_pool(text,text,numeric,uuid) to authenticated;
revoke all on function public.create_funding_pool(text,text,numeric,uuid) from public,anon;

create or replace function public.list_funding_pools()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_rows jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'name',p.name,'purpose',p.purpose,
    'total_amount',p.total_amount,'used_amount',p.used_amount,
    'remaining',p.total_amount-p.used_amount,'project_id',p.project_id,
    'active',p.active,'created_at',p.created_at
  ) order by p.created_at desc),'[]'::jsonb) into v_rows
  from public.funding_pools p where p.enterprise_id=v_eid;
  return jsonb_build_object('ok',true,'pools',v_rows);
end;
$fn$;
grant execute on function public.list_funding_pools() to authenticated;
revoke all on function public.list_funding_pools() from public,anon;

create or replace function public.create_funding_request(
  p_type text,p_amount numeric,p_reason text,p_category text,
  p_project uuid,p_pool uuid,p_budget_subject text,p_payee text,
  p_payment_method text,p_expected_date date
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_eid uuid:=public._funding_eid();
  v_uid uuid:=auth.uid();
  v_req uuid;
  v_t1 numeric; v_t2 numeric;
  v_manager uuid; v_finance uuid; v_owner uuid; v_board uuid;
  v_step integer:=0;
begin
  if p_amount is null or p_amount<=0 then raise exception 'amount must be positive'; end if;
  if p_type not in ('reimbursement','advance','special') then raise exception 'invalid request type'; end if;
  select tier1_max,tier2_max into v_t1,v_t2 from public.funding_settings where enterprise_id=v_eid;
  v_t1:=coalesce(v_t1,500); v_t2:=coalesce(v_t2,5000);
  select owner_profile_id into v_owner from public.enterprises where id=v_eid;
  select coalesce(m.reports_to_profile_id, dm.profile_id) into v_manager
    from public.enterprise_members m
    left join lateral (
      select m2.profile_id from public.enterprise_members m2
      join public.enterprise_role_catalog r on r.key=m2.role_key
      where m2.enterprise_id=v_eid and m2.status='active' and m2.role_key='department_manager'
        and m2.department=m.department order by m2.profile_id limit 1
    ) dm on true
   where m.enterprise_id=v_eid and m.profile_id=v_uid;
  select profile_id into v_finance from public.enterprise_members
   where enterprise_id=v_eid and status='active' and role_key='finance' limit 1;
  v_finance:=coalesce(v_finance,v_owner);
  select profile_id into v_board from public.enterprise_members
   where enterprise_id=v_eid and status='active' and role_key in ('chairperson','director')
   order by case when role_key='chairperson' then 0 else 1 end limit 1;
  v_board:=coalesce(v_board,v_owner);

  insert into public.funding_requests(
    enterprise_id,applicant_profile_id,request_type,amount,reason,category,
    project_id,pool_id,budget_subject,payee,payment_method,expected_date,status
  ) values (
    v_eid,v_uid,p_type,round(p_amount,2),left(coalesce(p_reason,''),2000),
    left(coalesce(p_category,''),100),p_project,p_pool,left(coalesce(p_budget_subject,''),200),
    left(coalesce(p_payee,''),200),left(coalesce(p_payment_method,''),50),p_expected_date,'pending'
  ) returning id into v_req;

  if v_manager is not null and v_manager<>v_uid then
    v_step:=v_step+1;
    insert into public.funding_approvals(request_id,step_order,step_kind,approver_profile_id)
    values(v_req,v_step,'manager',v_manager);
  end if;
  v_step:=v_step+1;
  insert into public.funding_approvals(request_id,step_order,step_kind,approver_profile_id)
  values(v_req,v_step,'finance',v_finance);
  if p_amount>v_t1 then
    v_step:=v_step+1;
    insert into public.funding_approvals(request_id,step_order,step_kind,approver_profile_id)
    values(v_req,v_step,'owner',v_owner);
  end if;
  if p_amount>v_t2 then
    v_step:=v_step+1;
    insert into public.funding_approvals(request_id,step_order,step_kind,approver_profile_id)
    values(v_req,v_step,'board',v_board);
  end if;
  update public.funding_requests set current_step=1 where id=v_req;
  return jsonb_build_object('ok',true,'request_id',v_req);
end;
$fn$;
grant execute on function public.create_funding_request(text,numeric,text,text,uuid,uuid,text,text,text,date) to authenticated;
revoke all on function public.create_funding_request(text,numeric,text,text,uuid,uuid,text,text,text,date) from public,anon;

create or replace function public.set_funding_attachment(p_request uuid,p_path text)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid();
begin
  update public.funding_requests set attachment_path=left(coalesce(p_path,''),500),updated_at=now()
   where id=p_request and enterprise_id=v_eid and applicant_profile_id=v_uid;
  if not found then raise exception 'request not found or not allowed'; end if;
  return jsonb_build_object('ok',true);
end;
$fn$;
grant execute on function public.set_funding_attachment(uuid,text) to authenticated;
revoke all on function public.set_funding_attachment(uuid,text) from public,anon;

create or replace function public.list_funding_requests(p_scope text default 'mine')
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid(); v_rows jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'request_type',r.request_type,'status',r.status,'amount',r.amount,
    'reason',r.reason,'category',r.category,'project_id',r.project_id,
    'pool_id',r.pool_id,'budget_subject',r.budget_subject,'payee',r.payee,
    'payment_method',r.payment_method,'expected_date',r.expected_date,
    'attachment_path',r.attachment_path,'receipt_path',r.receipt_path,
    'current_step',r.current_step,'created_at',r.created_at,
    'applicant_name',ap.name,'is_applicant',r.applicant_profile_id=v_uid,
    'can_pay',public._funding_can_manage(v_eid,v_uid) and r.status='approved',
    'approvals',coalesce((
      select jsonb_agg(jsonb_build_object(
        'step_order',a.step_order,'step_kind',a.step_kind,'status',a.status,
        'note',a.note,'approver_name',pp.name,'decided_at',a.decided_at
      ) order by a.step_order)
      from public.funding_approvals a
      left join public.profiles pp on pp.id=a.approver_profile_id
      where a.request_id=r.id
    ),'[]'::jsonb),
    'my_pending',exists(select 1 from public.funding_approvals a
      where a.request_id=r.id and a.status='pending' and a.approver_profile_id=v_uid)
  ) order by r.created_at desc),'[]'::jsonb) into v_rows
  from public.funding_requests r
  join public.profiles ap on ap.id=r.applicant_profile_id
  where r.enterprise_id=v_eid
    and (
      p_scope='all'
      or (p_scope='mine' and r.applicant_profile_id=v_uid)
      or (p_scope='pending' and exists(select 1 from public.funding_approvals a
        where a.request_id=r.id and a.status='pending' and a.approver_profile_id=v_uid))
    )
    and (public._funding_can_view_all(v_eid,v_uid) or r.applicant_profile_id=v_uid
      or exists(select 1 from public.funding_approvals a
        where a.request_id=r.id and a.approver_profile_id=v_uid));
  return jsonb_build_object('ok',true,'requests',v_rows);
end;
$fn$;
grant execute on function public.list_funding_requests(text) to authenticated;
revoke all on function public.list_funding_requests(text) from public,anon;

create or replace function public.decide_funding_approval(p_request uuid,p_approve boolean,p_note text default '')
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid();
  v_row public.funding_requests%rowtype; v_step public.funding_approvals%rowtype;
  v_next integer;
begin
  select * into v_row from public.funding_requests where id=p_request and enterprise_id=v_eid for update;
  if not found then raise exception 'request not found'; end if;
  if v_row.status<>'pending' then raise exception 'request is not pending'; end if;
  select * into v_step from public.funding_approvals
   where request_id=p_request and status='pending' order by step_order limit 1;
  if not found then raise exception 'no pending approval'; end if;
  if v_step.approver_profile_id<>v_uid and not public._funding_can_manage(v_eid,v_uid) then
    raise exception 'not allowed to approve this step';
  end if;
  if coalesce(p_approve,false) then
    update public.funding_approvals set status='approved',note=left(coalesce(p_note,''),1000),decided_at=now() where id=v_step.id;
    select min(step_order) into v_next from public.funding_approvals where request_id=p_request and status='pending';
    if v_next is null then
      update public.funding_requests set status='approved',updated_at=now() where id=p_request;
    else
      update public.funding_requests set current_step=v_next,updated_at=now() where id=p_request;
    end if;
  else
    update public.funding_approvals set status='rejected',note=left(coalesce(p_note,''),1000),decided_at=now() where id=v_step.id;
    update public.funding_requests set status='rejected',updated_at=now() where id=p_request;
  end if;
  return jsonb_build_object('ok',true);
end;
$fn$;
grant execute on function public.decide_funding_approval(uuid,boolean,text) to authenticated;
revoke all on function public.decide_funding_approval(uuid,boolean,text) from public,anon;

create or replace function public.mark_funding_paid(p_request uuid)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid();
begin
  if not public._funding_can_manage(v_eid,v_uid) then raise exception 'not allowed'; end if;
  update public.funding_requests set status='paid',paid_at=now(),updated_at=now()
   where id=p_request and enterprise_id=v_eid and status='approved';
  if not found then raise exception 'request not payable'; end if;
  return jsonb_build_object('ok',true);
end;
$fn$;
grant execute on function public.mark_funding_paid(uuid) to authenticated;
revoke all on function public.mark_funding_paid(uuid) from public,anon;

create or replace function public.settle_funding_request(p_request uuid,p_receipt text default '')
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_eid uuid:=public._funding_eid(); v_uid uuid:=auth.uid();
begin
  if not public._funding_can_manage(v_eid,v_uid) then raise exception 'not allowed'; end if;
  update public.funding_requests
     set status='settled',receipt_path=left(coalesce(p_receipt,''),500),settled_at=now(),updated_at=now()
   where id=p_request and enterprise_id=v_eid and status in ('approved','paid');
  if not found then raise exception 'request not settlable'; end if;
  return jsonb_build_object('ok',true);
end;
$fn$;
grant execute on function public.settle_funding_request(uuid,text) to authenticated;
revoke all on function public.settle_funding_request(uuid,text) from public,anon;

insert into storage.buckets(id,name,public) values('funding-attachments','funding-attachments',false)
on conflict (id) do nothing;
drop policy if exists "funding files owner insert" on storage.objects;
create policy "funding files owner insert" on storage.objects for insert to authenticated
  with check (bucket_id='funding-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "funding files read" on storage.objects;
create policy "funding files read" on storage.objects for select to authenticated
  using (bucket_id='funding-attachments' and (
    (storage.foldername(name))[1]=auth.uid()::text
    or public.identity_has_permission('finance.view')
    or public.identity_has_permission('finance.manage')
    or public.identity_has_permission('governance.manage')
  ));

insert into public.app_migrations(version,name,notes)
values('funding-v1','Funding','Funding requests, approval chain, pools and settlement')
on conflict (version) do update set notes=excluded.notes;
