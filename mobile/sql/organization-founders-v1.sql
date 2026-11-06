-- ============================================================
-- ProjectRecorder organization founding and equity v1
-- Additive and idempotent. ASCII-only.
-- ============================================================

alter table public.profiles
  add column if not exists active_enterprise_id uuid;

do $do$
begin
  if exists(
    select 1 from pg_constraint
     where conrelid='public.enterprises'::regclass
       and conname='enterprises_owner_profile_id_key'
  ) then
    alter table public.enterprises drop constraint enterprises_owner_profile_id_key;
  end if;
end;
$do$;

do $do$
begin
  if not exists(
    select 1 from pg_constraint
     where conrelid='public.profiles'::regclass
       and conname='profiles_active_enterprise_fk'
  ) then
    alter table public.profiles
      add constraint profiles_active_enterprise_fk
      foreign key (active_enterprise_id) references public.enterprises(id)
      on delete set null;
  end if;
end;
$do$;

create table if not exists public.organization_foundations (
  enterprise_id uuid primary key references public.enterprises(id) on delete cascade,
  status text not null default 'founding'
    check (status in ('founding','active','dissolving','archived')),
  founder_limit integer not null default 20 check (founder_limit between 1 and 200),
  founding_deadline timestamptz not null default (now() + interval '7 days'),
  finalized_at timestamptz,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_founder_invites (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  inviter_profile_id uuid not null references public.profiles(id) on delete cascade,
  invitee_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'invited'
    check (status in ('invited','accepted','declined','expired','revoked')),
  expires_at timestamptz not null default (now() + interval '7 days'),
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists organization_founder_invite_open_idx
  on public.organization_founder_invites(enterprise_id,invitee_profile_id)
  where status='invited';
create index if not exists organization_founder_invitee_idx
  on public.organization_founder_invites(invitee_profile_id,status,created_at desc);

create table if not exists public.organization_founders (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'active' check (status in ('active','former')),
  is_original boolean not null default true,
  joined_at timestamptz not null default now(),
  approved_by uuid references public.profiles(id) on delete set null,
  primary key (enterprise_id,profile_id)
);

create table if not exists public.organization_share_lots (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  owner_profile_id uuid references public.profiles(id) on delete cascade,
  share_class text not null
    check (share_class in ('original','ordinary','employee_pool','employee_incentive')),
  units numeric(18,4) not null check (units > 0),
  voting_weight numeric(8,4) not null default 1.0 check (voting_weight >= 0),
  economic_weight numeric(8,4) not null default 1.0 check (economic_weight >= 0),
  status text not null default 'active'
    check (status in ('active','transferred','redeemed')),
  source_lot_id uuid references public.organization_share_lots(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists organization_share_lots_member_idx
  on public.organization_share_lots(enterprise_id,owner_profile_id,status);

create table if not exists public.organization_equity_motions (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  kind text not null
    check (kind in ('initial_split','share_change','founder_add','share_transfer',
                   'employee_pool','dissolution')),
  required_rule text not null
    check (required_rule in ('founder_unanimous','weighted_2_3','weighted_4_5')),
  payload jsonb not null default '{}'::jsonb,
  reason text not null default '',
  proposer_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'open'
    check (status in ('open','passed','rejected','cancelled')),
  opens_at timestamptz not null default now(),
  closes_at timestamptz not null,
  decided_at timestamptz,
  decision_reason text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists organization_equity_motion_idx
  on public.organization_equity_motions(enterprise_id,status,created_at desc);

create table if not exists public.organization_equity_votes (
  motion_id uuid not null references public.organization_equity_motions(id) on delete cascade,
  voter_profile_id uuid not null references public.profiles(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  voting_units_at_vote numeric(18,4) not null default 0,
  voted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (motion_id,voter_profile_id)
);

create table if not exists public.organization_employee_pools (
  enterprise_id uuid primary key references public.enterprises(id) on delete cascade,
  total_units numeric(18,4) not null check (total_units > 0),
  allocated_units numeric(18,4) not null default 0 check (allocated_units >= 0),
  max_bps integer not null default 1000 check (max_bps between 1 and 2000),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_employee_grants (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  units numeric(18,4) not null check (units > 0),
  vesting_start timestamptz not null default now(),
  cliff_months integer not null default 12 check (cliff_months between 0 and 120),
  total_months integer not null default 48 check (total_months between 1 and 240),
  status text not null default 'active'
    check (status in ('active','recovered','completed')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists organization_employee_grant_member_idx
  on public.organization_employee_grants(enterprise_id,profile_id,created_at desc);

create table if not exists public.organization_share_transfers (
  id uuid primary key default gen_random_uuid(),
  motion_id uuid unique references public.organization_equity_motions(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  seller_profile_id uuid not null references public.profiles(id) on delete cascade,
  buyer_profile_id uuid not null references public.profiles(id) on delete cascade,
  source_lot_id uuid not null references public.organization_share_lots(id) on delete restrict,
  units numeric(18,4) not null check (units > 0),
  price numeric(18,2) not null default 0 check (price >= 0),
  status text not null default 'completed'
    check (status in ('pending','completed','cancelled')),
  created_at timestamptz not null default now()
);

alter table public.organization_foundations enable row level security;
alter table public.organization_founder_invites enable row level security;
alter table public.organization_founders enable row level security;
alter table public.organization_share_lots enable row level security;
alter table public.organization_equity_motions enable row level security;
alter table public.organization_equity_votes enable row level security;
alter table public.organization_employee_pools enable row level security;
alter table public.organization_employee_grants enable row level security;
alter table public.organization_share_transfers enable row level security;

revoke all on public.organization_foundations from anon,authenticated;
revoke all on public.organization_founder_invites from anon,authenticated;
revoke all on public.organization_founders from anon,authenticated;
revoke all on public.organization_share_lots from anon,authenticated;
revoke all on public.organization_equity_motions from anon,authenticated;
revoke all on public.organization_equity_votes from anon,authenticated;
revoke all on public.organization_employee_pools from anon,authenticated;
revoke all on public.organization_employee_grants from anon,authenticated;
revoke all on public.organization_share_transfers from anon,authenticated;

create or replace function public._identity_owner_for_uid(p_uid uuid)
returns uuid language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select coalesce(
    (select e.owner_profile_id
       from public.profiles p
       join public.enterprises e on e.id=p.active_enterprise_id
      where p.id=p_uid),
    (select boss_id from public.profiles where id=p_uid),
    p_uid
  );
$fn$;

create or replace function public.identity_owner_id()
returns uuid language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select public._identity_owner_for_uid(auth.uid());
$fn$;

create or replace function public.identity_has_permission(p_permission text)
returns boolean language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_owner uuid;
  v_eid uuid;
  v_role text;
begin
  if v_uid is null then return false; end if;
  select active_enterprise_id,coalesce(boss_id,id),role
    into v_eid,v_owner,v_role
    from public.profiles where id=v_uid;
  if v_eid is null then
    select id into v_eid from public.enterprises
     where owner_profile_id=v_owner order by created_at limit 1;
  end if;
  if v_eid is null then
    return v_role='boss' or p_permission in ('identity.view','community.post');
  end if;
  return public._identity_role_permissions(v_eid,v_uid) ? p_permission;
end;
$fn$;

create or replace function public._organization_active_enterprise(p_uid uuid)
returns uuid language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select coalesce(
    (select p.active_enterprise_id
       from public.profiles p
      where p.id=p_uid
        and exists(select 1 from public.enterprise_members m
          where m.enterprise_id=p.active_enterprise_id
            and m.profile_id=p_uid and m.status='active')),
    (select m.enterprise_id from public.enterprise_members m
      where m.profile_id=p_uid and m.status='active'
      order by m.updated_at desc limit 1)
  );
$fn$;

create or replace function public._organization_is_founder(p_eid uuid,p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select p_uid is not null and p_uid=auth.uid() and exists(
    select 1 from public.organization_founders f
     where f.enterprise_id=p_eid and f.profile_id=p_uid and f.status='active'
  );
$fn$;

create or replace function public._organization_can_manage(p_eid uuid,p_uid uuid)
returns boolean language sql stable security definer
set search_path=public,auth,pg_temp as $fn$
  select p_uid is not null and p_uid=auth.uid()
    and public._identity_is_member(p_eid,p_uid)
    and (public.identity_has_permission('company.manage')
      or public.identity_has_permission('governance.manage'));
$fn$;

create or replace function public.list_my_organizations()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_active uuid:=public._organization_active_enterprise(v_uid);
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'ok',true,
    'active_enterprise_id',v_active,
    'organizations',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,'name',e.name,'owner_profile_id',e.owner_profile_id,
        'active',e.id=v_active,
        'founder',exists(select 1 from public.organization_founders f
          where f.enterprise_id=e.id and f.profile_id=v_uid
            and f.status='active'),
        'role_key',m.role_key,'title',m.title
      ) order by e.created_at)
      from public.enterprise_members m
      join public.enterprises e on e.id=m.enterprise_id
      where m.profile_id=v_uid and m.status='active'
    ),'[]'::jsonb)
  );
end;
$fn$;

create or replace function public.set_active_organization(p_enterprise uuid)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_owner uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not public._identity_is_member(p_enterprise,v_uid) then
    raise exception 'organization membership required';
  end if;
  select owner_profile_id into v_owner
    from public.enterprises where id=p_enterprise;
  update public.profiles
     set active_enterprise_id=p_enterprise,boss_id=v_owner
   where id=v_uid;
  return jsonb_build_object('ok',true,'enterprise_id',p_enterprise,
    'owner_profile_id',v_owner);
end;
$fn$;

create or replace function public.create_organization(
  p_name text,
  p_founder_codes text[] default '{}'
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid;
  v_name text:=btrim(coalesce(p_name,''));
  v_code text;
  v_profile uuid;
  v_founder_count integer:=1;
  v_invites integer:=0;
  v_lot uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if char_length(v_name)<1 or char_length(v_name)>120 then
    raise exception 'invalid organization name';
  end if;
  if coalesce(array_length(p_founder_codes,1),0)>19 then
    raise exception 'founder limit exceeded';
  end if;

  insert into public.enterprises(owner_profile_id,name)
    values(v_uid,v_name) returning id into v_eid;
  insert into public.enterprise_members(
    enterprise_id,profile_id,role_key,title,status,appointed_by,appointed_at
  ) values(v_eid,v_uid,'chairperson','Founder','active',v_uid,now());
  insert into public.organization_foundations(
    enterprise_id,status,created_by
  ) values(v_eid,'founding',v_uid);
  insert into public.organization_founders(
    enterprise_id,profile_id,status,is_original,approved_by
  ) values(v_eid,v_uid,'active',true,v_uid);

  foreach v_code in array coalesce(p_founder_codes,'{}'::text[]) loop
    v_code:=btrim(v_code);
    if v_code='' then continue; end if;
    select id into v_profile from public.profiles
     where coalesce(active,true) and (code=v_code or name=v_code)
     limit 1;
    if v_profile is null then
      raise exception 'founder profile not found: %',v_code;
    end if;
    if v_profile=v_uid then continue; end if;
    insert into public.organization_founder_invites(
      enterprise_id,inviter_profile_id,invitee_profile_id
    ) values(v_eid,v_uid,v_profile)
    on conflict (enterprise_id,invitee_profile_id)
      where status='invited' do nothing;
    v_founder_count:=v_founder_count+1;
    v_invites:=v_invites+1;
  end loop;

  update public.profiles
     set active_enterprise_id=v_eid,boss_id=v_uid
   where id=v_uid;

  if v_invites=0 then
    insert into public.enterprise_shareholders(
      enterprise_id,profile_id,shares,updated_by
    ) values(v_eid,v_uid,100,v_uid)
    on conflict (enterprise_id,profile_id) do update set
      shares=excluded.shares,updated_by=excluded.updated_by,updated_at=now();
    insert into public.organization_share_lots(
      enterprise_id,owner_profile_id,share_class,units,voting_weight,economic_weight
    ) values(v_eid,v_uid,'original',100,1.1,1.0)
    returning id into v_lot;
    update public.organization_foundations set
      status='active',finalized_at=now(),updated_at=now()
     where enterprise_id=v_eid;
  end if;

  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_eid,v_uid,'organization.created',jsonb_build_object(
    'name',v_name,'founder_codes',p_founder_codes,'founder_count',v_founder_count,
    'solo',v_invites=0
  ));
  return jsonb_build_object('ok',true,'enterprise_id',v_eid,
    'status',case when v_invites=0 then 'active' else 'founding' end,
    'invited',v_invites);
end;
$fn$;

create or replace function public.invite_organization_founder(
  p_enterprise uuid,p_code text
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_profile uuid;
  v_foundation public.organization_foundations%rowtype;
  v_id uuid;
begin
  if not public._organization_can_manage(p_enterprise,v_uid) then
    raise exception 'permission denied';
  end if;
  select * into v_foundation from public.organization_foundations
   where enterprise_id=p_enterprise;
  if v_foundation.status<>'founding' then
    raise exception 'organization is not in founding state';
  end if;
  if (select count(*) from public.organization_founders
      where enterprise_id=p_enterprise and status='active')
      >= v_foundation.founder_limit then
    raise exception 'founder limit reached';
  end if;
  select id into v_profile from public.profiles
   where coalesce(active,true) and (code=btrim(p_code) or name=btrim(p_code))
   limit 1;
  if v_profile is null then raise exception 'profile not found'; end if;
  if v_profile=v_uid then raise exception 'cannot invite yourself'; end if;
  insert into public.organization_founder_invites(
    enterprise_id,inviter_profile_id,invitee_profile_id,expires_at
  ) values(p_enterprise,v_uid,v_profile,now()+interval '7 days')
  returning id into v_id;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(p_enterprise,v_uid,'organization.founder_invited',v_profile,
    jsonb_build_object('invite_id',v_id));
  return jsonb_build_object('ok',true,'invite_id',v_id,
    'invitee_profile_id',v_profile,'expires_at',now()+interval '7 days');
end;
$fn$;

create or replace function public.respond_organization_founder_invite(
  p_invite uuid,p_accept boolean
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_row public.organization_founder_invites%rowtype;
  v_owner uuid;
begin
  select * into v_row from public.organization_founder_invites
   where id=p_invite and invitee_profile_id=v_uid for update;
  if not found then raise exception 'invite not found'; end if;
  if v_row.status<>'invited' then raise exception 'invite is not open'; end if;
  if v_row.expires_at<=now() then
    update public.organization_founder_invites set status='expired',
      responded_at=now() where id=p_invite;
    return jsonb_build_object('ok',false,'status','expired');
  end if;
  if not coalesce(p_accept,false) then
    update public.organization_founder_invites set status='declined',
      responded_at=now() where id=p_invite;
    return jsonb_build_object('ok',true,'status','declined');
  end if;
  select owner_profile_id into v_owner from public.enterprises
   where id=v_row.enterprise_id;
  insert into public.enterprise_members(
    enterprise_id,profile_id,role_key,title,status
  ) values(v_row.enterprise_id,v_uid,'employee','Founder invitee','active')
  on conflict (enterprise_id,profile_id) do update set
    status='active',updated_at=now();
  insert into public.organization_founders(
    enterprise_id,profile_id,status,is_original,approved_by
  ) values(v_row.enterprise_id,v_uid,'active',true,v_row.inviter_profile_id)
  on conflict (enterprise_id,profile_id) do update set
    status='active',is_original=true,approved_by=excluded.approved_by;
  update public.organization_founder_invites set status='accepted',
    responded_at=now() where id=p_invite;
  update public.profiles set active_enterprise_id=v_row.enterprise_id,
    boss_id=v_owner where id=v_uid;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_row.enterprise_id,v_uid,'organization.founder_accepted',v_uid,
    jsonb_build_object('invite_id',p_invite));
  return jsonb_build_object('ok',true,'status','accepted',
    'enterprise_id',v_row.enterprise_id);
end;
$fn$;

create or replace function public.get_organization_state()
returns jsonb language plpgsql stable security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._organization_active_enterprise(v_uid);
  v_result jsonb;
  v_total_units numeric:=0;
  v_voting_units numeric:=0;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_eid is null then
    return jsonb_build_object('ok',true,'organization',null,
      'organizations',(public.list_my_organizations()->'organizations'),
      'required_action','create_or_join');
  end if;
  select coalesce(sum(units),0),coalesce(sum(units*voting_weight),0)
    into v_total_units,v_voting_units
    from public.organization_share_lots
   where enterprise_id=v_eid and status='active';
  select jsonb_build_object(
    'ok',true,
    'organization',jsonb_build_object(
      'id',e.id,'name',e.name,'owner_profile_id',e.owner_profile_id,
      'created_at',e.created_at,
      'foundation_status',f.status,'finalized_at',f.finalized_at,
      'founding_deadline',f.founding_deadline,
      'active_enterprise_id',v_eid
    ),
    'me',jsonb_build_object(
      'profile_id',v_uid,
      'is_founder',public._organization_is_founder(v_eid,v_uid),
      'can_manage',public._organization_can_manage(v_eid,v_uid),
      'role_key',m.role_key,'title',m.title
    ),
    'organizations',(public.list_my_organizations()->'organizations'),
    'founders',coalesce((select jsonb_agg(jsonb_build_object(
      'profile_id',fo.profile_id,'name',p.name,'code',p.code,
      'status',fo.status,'is_original',fo.is_original,'joined_at',fo.joined_at,
      'role_key',m.role_key,'title',m.title
    ) order by fo.joined_at)
      from public.organization_founders fo
      join public.profiles p on p.id=fo.profile_id
      left join public.enterprise_members m
        on m.enterprise_id=fo.enterprise_id and m.profile_id=fo.profile_id
      where fo.enterprise_id=v_eid),'[]'::jsonb),
    'invites',coalesce((select jsonb_agg(jsonb_build_object(
      'id',i.id,'invitee_profile_id',i.invitee_profile_id,
      'invitee_name',p.name,'invitee_code',p.code,'status',i.status,
      'expires_at',i.expires_at,'created_at',i.created_at
    ) order by i.created_at desc)
      from public.organization_founder_invites i
      join public.profiles p on p.id=i.invitee_profile_id
      where i.enterprise_id=v_eid
        and (public._organization_can_manage(v_eid,v_uid)
          or i.invitee_profile_id=v_uid)),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(jsonb_build_object(
      'profile_id',m.profile_id,'name',p.name,'code',p.code,
      'role_key',m.role_key,'title',m.title,'department',m.department,
      'status',m.status
    ) order by p.name)
      from public.enterprise_members m join public.profiles p on p.id=m.profile_id
      where m.enterprise_id=v_eid),'[]'::jsonb),
    'share_lots',coalesce((select jsonb_agg(jsonb_build_object(
      'id',l.id,'owner_profile_id',l.owner_profile_id,'owner_name',p.name,
      'share_class',l.share_class,'units',l.units,
      'voting_weight',l.voting_weight,'economic_weight',l.economic_weight,
      'status',l.status,'created_at',l.created_at
    ) order by l.created_at,l.id)
      from public.organization_share_lots l
      left join public.profiles p on p.id=l.owner_profile_id
      where l.enterprise_id=v_eid and l.status='active'),'[]'::jsonb),
    'motions',coalesce((select jsonb_agg(jsonb_build_object(
      'id',m.id,'kind',m.kind,'required_rule',m.required_rule,
      'status',m.status,'reason',m.reason,'payload',m.payload,
      'proposer_profile_id',m.proposer_profile_id,
      'closes_at',m.closes_at,'decided_at',m.decided_at,
      'decision_reason',m.decision_reason,
      'yes_units',coalesce((select sum(v.voting_units_at_vote)
        from public.organization_equity_votes v
        where v.motion_id=m.id and v.choice='yes'),0),
      'no_units',coalesce((select sum(v.voting_units_at_vote)
        from public.organization_equity_votes v
        where v.motion_id=m.id and v.choice='no'),0),
      'abstain_units',coalesce((select sum(v.voting_units_at_vote)
        from public.organization_equity_votes v
        where v.motion_id=m.id and v.choice='abstain'),0),
      'vote_count',(select count(*) from public.organization_equity_votes v
        where v.motion_id=m.id),
      'my_vote',(select v.choice from public.organization_equity_votes v
        where v.motion_id=m.id and v.voter_profile_id=v_uid)
    ) order by m.created_at desc)
      from public.organization_equity_motions m
      where m.enterprise_id=v_eid),'[]'::jsonb),
    'employee_pool',(select jsonb_build_object(
      'total_units',p.total_units,'allocated_units',p.allocated_units,
      'max_bps',p.max_bps,'remaining_units',p.total_units-p.allocated_units
    ) from public.organization_employee_pools p where p.enterprise_id=v_eid),
    'employee_grants',case when public._organization_can_manage(v_eid,v_uid)
      then coalesce((select jsonb_agg(jsonb_build_object(
        'id',g.id,'profile_id',g.profile_id,'name',p.name,
        'units',g.units,'vesting_start',g.vesting_start,
        'cliff_months',g.cliff_months,'total_months',g.total_months,
        'status',g.status,
        'vested_units',round(g.units*least(1,greatest(0,
          extract(epoch from (now()-g.vesting_start))/86400/30.4375
          /greatest(g.total_months,1))),4)
      ) order by g.created_at desc)
        from public.organization_employee_grants g
        join public.profiles p on p.id=g.profile_id
        where g.enterprise_id=v_eid),'[]'::jsonb)
      else '[]'::jsonb end,
    'total_units',v_total_units,
    'voting_units',v_voting_units,
    'generated_at',now()
  ) into v_result
  from public.enterprises e
  join public.organization_foundations f on f.enterprise_id=e.id
  left join public.enterprise_members m
    on m.enterprise_id=e.id and m.profile_id=v_uid
  where e.id=v_eid;
  return v_result;
end;
$fn$;

create or replace function public._organization_rebuild_shareholders(p_eid uuid)
returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
begin
  delete from public.enterprise_shareholders where enterprise_id=p_eid;
  insert into public.enterprise_shareholders(
    enterprise_id,profile_id,shares,updated_by
  )
  select p_eid,l.owner_profile_id,sum(l.units),auth.uid()
    from public.organization_share_lots l
   where l.enterprise_id=p_eid and l.status='active'
     and l.owner_profile_id is not null
   group by l.owner_profile_id;
end;
$fn$;

create or replace function public._organization_apply_allocations(
  p_eid uuid,p_allocations jsonb,p_original boolean,
  p_preserve_original boolean default false
) returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_row jsonb;
  v_profile uuid;
  v_units numeric;
  v_original_units numeric;
  v_existing_original numeric;
  v_original_map jsonb:='{}'::jsonb;
  v_founder boolean;
begin
  select coalesce(jsonb_object_agg(owner_profile_id,total),'{}'::jsonb)
    into v_original_map
    from (select owner_profile_id,sum(units) total
      from public.organization_share_lots
      where enterprise_id=p_eid and status='active'
        and share_class='original' and owner_profile_id is not null
      group by owner_profile_id) original_rows;
  delete from public.organization_share_lots
   where enterprise_id=p_eid and status='active'
     and share_class in ('original','ordinary');
  for v_row in select * from jsonb_array_elements(coalesce(p_allocations,'[]'::jsonb)) loop
    v_profile:=(v_row->>'profile_id')::uuid;
    v_units:=coalesce((v_row->>'units')::numeric,0);
    if v_units<=0 then raise exception 'allocation units must be positive'; end if;
    v_founder:=exists(select 1 from public.organization_founders f
      where f.enterprise_id=p_eid and f.profile_id=v_profile
        and f.status='active');
    v_original_units:=0;
    if v_founder and p_original then
      if p_preserve_original then
        v_existing_original:=coalesce(
          (v_original_map->>v_profile::text)::numeric,0);
        v_original_units:=least(v_units,v_existing_original);
      else
        v_original_units:=v_units;
      end if;
    end if;
    if v_original_units>0 then
      insert into public.organization_share_lots(
        enterprise_id,owner_profile_id,share_class,units,
        voting_weight,economic_weight
      ) values(p_eid,v_profile,'original',v_original_units,1.1,1.0);
    end if;
    if v_units>v_original_units then
      insert into public.organization_share_lots(
        enterprise_id,owner_profile_id,share_class,units,
        voting_weight,economic_weight
      ) values(p_eid,v_profile,'ordinary',v_units-v_original_units,1.0,1.0);
    end if;
  end loop;
  perform public._organization_rebuild_shareholders(p_eid);
end;
$fn$;

create or replace function public._organization_apply_motion(p_motion uuid)
returns void language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_m public.organization_equity_motions%rowtype;
  v_payload jsonb;
  v_lot public.organization_share_lots%rowtype;
  v_buyer uuid;
  v_units numeric;
  v_price numeric;
  v_profile uuid;
begin
  select * into v_m from public.organization_equity_motions where id=p_motion;
  v_payload:=coalesce(v_m.payload,'{}'::jsonb);
  if v_m.kind='initial_split' then
    perform public._organization_apply_allocations(
      v_m.enterprise_id,v_payload->'allocations',true,false
    );
    update public.organization_foundations set status='active',
      finalized_at=now(),updated_at=now()
     where enterprise_id=v_m.enterprise_id;
  elsif v_m.kind='share_change' then
    perform public._organization_apply_allocations(
      v_m.enterprise_id,v_payload->'allocations',true,true
    );
  elsif v_m.kind='founder_add' then
    v_profile:=(v_payload->>'profile_id')::uuid;
    v_units:=coalesce((v_payload->>'units')::numeric,0);
    if v_profile is null or v_units<=0 then raise exception 'invalid founder allocation'; end if;
    insert into public.enterprise_members(
      enterprise_id,profile_id,role_key,title,status
    ) values(v_m.enterprise_id,v_profile,'employee','Founder','active')
    on conflict (enterprise_id,profile_id) do update set status='active';
    insert into public.organization_founders(
      enterprise_id,profile_id,status,is_original,approved_by
    ) values(v_m.enterprise_id,v_profile,'active',true,v_m.proposer_profile_id)
    on conflict (enterprise_id,profile_id) do update set
      status='active',is_original=true,approved_by=excluded.approved_by;
    insert into public.organization_share_lots(
      enterprise_id,owner_profile_id,share_class,units,voting_weight,economic_weight
    ) values(v_m.enterprise_id,v_profile,'original',v_units,1.1,1.0);
    perform public._organization_rebuild_shareholders(v_m.enterprise_id);
  elsif v_m.kind='share_transfer' then
    select * into v_lot from public.organization_share_lots
     where id=(v_payload->>'lot_id')::uuid
       and enterprise_id=v_m.enterprise_id
       and status='active' for update;
    if not found then raise exception 'share lot not found'; end if;
    v_buyer:=(v_payload->>'buyer_profile_id')::uuid;
    v_units:=coalesce((v_payload->>'units')::numeric,0);
    v_price:=coalesce((v_payload->>'price')::numeric,0);
    if v_buyer is null or v_units<=0 or v_units>v_lot.units then
      raise exception 'invalid transfer';
    end if;
    insert into public.enterprise_members(
      enterprise_id,profile_id,role_key,title,status
    ) values(v_m.enterprise_id,v_buyer,'employee','Shareholder','active')
    on conflict (enterprise_id,profile_id) do nothing;
    if v_units=v_lot.units then
      update public.organization_share_lots set status='transferred'
       where id=v_lot.id;
    else
      update public.organization_share_lots set units=units-v_units
       where id=v_lot.id;
    end if;
    insert into public.organization_share_lots(
      enterprise_id,owner_profile_id,share_class,units,voting_weight,
      economic_weight,source_lot_id
    ) values(v_m.enterprise_id,v_buyer,'ordinary',v_units,1.0,1.0,v_lot.id);
    insert into public.organization_share_transfers(
      motion_id,enterprise_id,seller_profile_id,buyer_profile_id,
      source_lot_id,units,price,status
    ) values(v_m.id,v_m.enterprise_id,v_lot.owner_profile_id,v_buyer,
      v_lot.id,v_units,v_price,'completed');
    perform public._organization_rebuild_shareholders(v_m.enterprise_id);
  elsif v_m.kind='employee_pool' then
    v_units:=coalesce((v_payload->>'units')::numeric,0);
    if v_units<=0 then raise exception 'invalid employee pool'; end if;
    insert into public.organization_employee_pools(
      enterprise_id,total_units,allocated_units,created_by
    ) values(v_m.enterprise_id,v_units,0,v_m.proposer_profile_id)
    on conflict (enterprise_id) do update set
      total_units=excluded.total_units,updated_at=now();
    insert into public.organization_share_lots(
      enterprise_id,owner_profile_id,share_class,units,voting_weight,economic_weight
    ) values(v_m.enterprise_id,null,'employee_pool',v_units,0,1.0);
  elsif v_m.kind='dissolution' then
    update public.organization_foundations set status='dissolving',
      updated_at=now() where enterprise_id=v_m.enterprise_id;
  end if;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_m.enterprise_id,v_m.proposer_profile_id,
    'organization.motion_applied',jsonb_build_object(
      'motion_id',v_m.id,'kind',v_m.kind,'payload',v_payload));
end;
$fn$;

create or replace function public.propose_initial_split(
  p_allocations jsonb,p_reason text default '',
  p_closes_at timestamptz default (now()+interval '3 days')
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._organization_active_enterprise(v_uid);
  v_total numeric;
  v_count integer;
  v_founders integer;
  v_all_founders integer;
  v_id uuid;
begin
  if not public._organization_can_manage(v_eid,v_uid) then raise exception 'permission denied'; end if;
  if not exists(select 1 from public.organization_foundations
    where enterprise_id=v_eid and status='founding') then
    raise exception 'organization is not in founding state';
  end if;
  if exists(select 1 from public.organization_founder_invites
    where enterprise_id=v_eid and status='invited' and expires_at>now()) then
    raise exception 'pending founder invites must be resolved';
  end if;
  select coalesce(sum((x->>'units')::numeric),0),count(*),count(distinct x->>'profile_id')
    into v_total,v_count,v_founders
    from jsonb_array_elements(coalesce(p_allocations,'[]'::jsonb)) x;
  select count(*) into v_all_founders from public.organization_founders
   where enterprise_id=v_eid and status='active';
  if v_count<>v_founders or v_founders<>v_all_founders
     or v_total<99.999 or v_total>100.001 then
    raise exception 'allocations must cover every founder and total 100 units';
  end if;
  if exists(select 1 from jsonb_array_elements(p_allocations) x
    where not exists(select 1 from public.organization_founders f
      where f.enterprise_id=v_eid and f.status='active'
        and f.profile_id=(x->>'profile_id')::uuid)) then
    raise exception 'allocation contains a non-founder';
  end if;
  insert into public.organization_equity_motions(
    enterprise_id,kind,required_rule,payload,reason,proposer_profile_id,closes_at
  ) values(v_eid,'initial_split','founder_unanimous',
    jsonb_build_object('allocations',p_allocations),
    btrim(coalesce(p_reason,'Initial equity split')),v_uid,p_closes_at)
  returning id into v_id;
  return jsonb_build_object('ok',true,'motion_id',v_id,
    'required_rule','founder_unanimous');
end;
$fn$;

create or replace function public.create_equity_motion(
  p_kind text,p_payload jsonb,p_reason text default '',
  p_closes_at timestamptz default (now()+interval '3 days')
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._organization_active_enterprise(v_uid);
  v_kind text:=lower(btrim(coalesce(p_kind,'')));
  v_rule text;
  v_id uuid;
  v_total numeric:=0;
  v_units numeric:=0;
  v_profile uuid;
begin
  if v_kind not in ('share_change','founder_add','share_transfer',
                    'employee_pool','dissolution') then
    raise exception 'invalid motion kind';
  end if;
  if v_kind='dissolution' then
    v_rule:='weighted_4_5';
    if not (public._organization_is_founder(v_eid,v_uid)
      or public._organization_can_manage(v_eid,v_uid)
      or exists(select 1 from public.enterprise_shareholders
        where enterprise_id=v_eid and profile_id=v_uid and shares>0)) then
      raise exception 'shareholder or governance authority required';
    end if;
  else
    v_rule:='founder_unanimous';
    if not public._organization_is_founder(v_eid,v_uid) then
      raise exception 'founder approval required';
    end if;
  end if;

  if v_kind='share_change' then
    select coalesce(sum((x->>'units')::numeric),0)
      into v_total from jsonb_array_elements(coalesce(p_payload->'allocations','[]'::jsonb)) x;
    if v_total<99.999 or v_total>100.001 then
      raise exception 'share allocations must total 100 units';
    end if;
    if exists(select 1 from jsonb_array_elements(p_payload->'allocations') x
      where not exists(select 1 from public.enterprise_members m
        where m.enterprise_id=v_eid and m.status='active'
          and m.profile_id=(x->>'profile_id')::uuid)) then
      raise exception 'share allocation contains a non-member';
    end if;
  elsif v_kind='founder_add' then
    v_profile:=(p_payload->>'profile_id')::uuid;
    v_units:=coalesce((p_payload->>'units')::numeric,0);
    if v_profile is null or v_units<=0 then raise exception 'invalid founder allocation'; end if;
  elsif v_kind='share_transfer' then
    select units into v_units from public.organization_share_lots
     where id=(p_payload->>'lot_id')::uuid and enterprise_id=v_eid and status='active';
    if v_units is null or coalesce((p_payload->>'units')::numeric,0)<=0
       or coalesce((p_payload->>'units')::numeric,0)>v_units then
      raise exception 'invalid transfer units';
    end if;
  elsif v_kind='employee_pool' then
    v_units:=coalesce((p_payload->>'units')::numeric,0);
    select coalesce(sum(units),0) into v_total
      from public.organization_share_lots
     where enterprise_id=v_eid and status='active';
    if v_units<=0 or v_units>v_total*0.10 then
      raise exception 'employee pool exceeds 10 percent';
    end if;
  end if;

  insert into public.organization_equity_motions(
    enterprise_id,kind,required_rule,payload,reason,proposer_profile_id,closes_at
  ) values(v_eid,v_kind,v_rule,coalesce(p_payload,'{}'::jsonb),
    btrim(coalesce(p_reason,'')),v_uid,p_closes_at)
  returning id into v_id;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_eid,v_uid,'organization.motion_created',jsonb_build_object(
    'motion_id',v_id,'kind',v_kind,'rule',v_rule,'payload',p_payload));
  return jsonb_build_object('ok',true,'motion_id',v_id,'required_rule',v_rule);
end;
$fn$;

create or replace function public.cast_equity_vote(
  p_motion uuid,p_choice text
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_m public.organization_equity_motions%rowtype;
  v_choice text:=lower(btrim(coalesce(p_choice,'')));
  v_units numeric:=0;
  v_total numeric:=0;
  v_yes numeric:=0;
  v_cast numeric:=0;
  v_founders integer:=0;
  v_yes_count integer:=0;
  v_no_count integer:=0;
  v_remaining numeric:=0;
  v_status text:='open';
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v_choice not in ('yes','no','abstain') then raise exception 'invalid vote'; end if;
  select * into v_m from public.organization_equity_motions where id=p_motion for update;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then raise exception 'motion is closed'; end if;
  if v_m.closes_at<=now() then raise exception 'motion has expired'; end if;
  if not public._identity_is_member(v_m.enterprise_id,v_uid) then
    raise exception 'organization membership required';
  end if;
  if v_m.required_rule='founder_unanimous' then
    if not exists(select 1 from public.organization_founders f
      where f.enterprise_id=v_m.enterprise_id and f.profile_id=v_uid and f.status='active') then
      raise exception 'only founders may vote';
    end if;
    v_units:=1;
  else
    select coalesce(sum(units*voting_weight),0) into v_units
      from public.organization_share_lots
     where enterprise_id=v_m.enterprise_id and status='active'
       and owner_profile_id=v_uid;
    if v_units<=0 then
      select shares into v_units from public.enterprise_shareholders
       where enterprise_id=v_m.enterprise_id and profile_id=v_uid;
      v_units:=coalesce(v_units,0);
    end if;
    if v_units<=0 then raise exception 'voting shares required'; end if;
  end if;
  insert into public.organization_equity_votes(
    motion_id,voter_profile_id,choice,voting_units_at_vote
  ) values(p_motion,v_uid,v_choice,v_units)
  on conflict (motion_id,voter_profile_id) do update set
    choice=excluded.choice,voting_units_at_vote=excluded.voting_units_at_vote,
    updated_at=now();

  if v_m.required_rule='founder_unanimous' then
    select count(*) into v_founders from public.organization_founders
     where enterprise_id=v_m.enterprise_id and status='active';
    select count(*) filter(where choice='yes'),count(*) filter(where choice='no')
      into v_yes_count,v_no_count
      from public.organization_equity_votes where motion_id=p_motion;
    if v_no_count>0 then v_status:='rejected';
    elsif v_yes_count>=v_founders then v_status:='passed'; end if;
  else
    select coalesce(sum(units*voting_weight),0) into v_total
      from public.organization_share_lots
     where enterprise_id=v_m.enterprise_id and status='active';
    if v_total<=0 then v_total:=100; end if;
    select coalesce(sum(voting_units_at_vote) filter(where choice='yes'),0),
           coalesce(sum(voting_units_at_vote),0)
      into v_yes,v_cast from public.organization_equity_votes
      where motion_id=p_motion;
    v_remaining:=greatest(0,v_total-v_cast);
    if v_m.required_rule='weighted_2_3' then
      if v_yes*3>v_total*2 then v_status:='passed';
      elsif (v_yes+v_remaining)*3<=v_total*2 then v_status:='rejected'; end if;
    else
      if v_yes*5>v_total*4 then v_status:='passed';
      elsif (v_yes+v_remaining)*5<=v_total*4 then v_status:='rejected'; end if;
    end if;
  end if;
  if v_status<>'open' then
    update public.organization_equity_motions set status=v_status,
      decided_at=now(),decision_reason='Vote resolved' where id=p_motion;
    if v_status='passed' then perform public._organization_apply_motion(p_motion); end if;
  end if;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_m.enterprise_id,v_uid,'organization.vote_cast',jsonb_build_object(
    'motion_id',p_motion,'choice',v_choice,'voting_units',v_units,
    'status',v_status));
  return jsonb_build_object('ok',true,'choice',v_choice,'status',v_status,
    'voting_units',v_units);
end;
$fn$;

create or replace function public.cancel_equity_motion(
  p_motion uuid,p_reason text default ''
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid(); v_m public.organization_equity_motions%rowtype;
begin
  select * into v_m from public.organization_equity_motions where id=p_motion;
  if not found then raise exception 'motion not found'; end if;
  if v_m.status<>'open' then raise exception 'motion is closed'; end if;
  if v_m.proposer_profile_id<>v_uid
     and not public._organization_can_manage(v_m.enterprise_id,v_uid) then
    raise exception 'permission denied';
  end if;
  update public.organization_equity_motions set status='cancelled',
    decided_at=now(),decision_reason=btrim(coalesce(p_reason,'Cancelled'))
   where id=p_motion;
  return jsonb_build_object('ok',true,'status','cancelled');
end;
$fn$;

create or replace function public.grant_employee_equity(
  p_profile uuid,p_units numeric,p_vesting_start timestamptz default now()
) returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare
  v_uid uuid:=auth.uid();
  v_eid uuid:=public._organization_active_enterprise(v_uid);
  v_pool public.organization_employee_pools%rowtype;
  v_id uuid;
begin
  if not public._organization_can_manage(v_eid,v_uid) then raise exception 'permission denied'; end if;
  select * into v_pool from public.organization_employee_pools
   where enterprise_id=v_eid for update;
  if not found then raise exception 'employee pool not found'; end if;
  if coalesce(p_units,0)<=0 or v_pool.allocated_units+coalesce(p_units,0)>v_pool.total_units then
    raise exception 'employee pool exhausted';
  end if;
  insert into public.enterprise_members(
    enterprise_id,profile_id,role_key,title,status
  ) values(v_eid,p_profile,'employee','Employee equity','active')
  on conflict (enterprise_id,profile_id) do update set status='active';
  insert into public.organization_employee_grants(
    enterprise_id,profile_id,units,vesting_start,created_by
  ) values(v_eid,p_profile,p_units,coalesce(p_vesting_start,now()),v_uid)
  returning id into v_id;
  update public.organization_employee_pools set
    allocated_units=allocated_units+p_units,updated_at=now()
   where enterprise_id=v_eid;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,target_profile_id,details
  ) values(v_eid,v_uid,'organization.employee_equity_granted',p_profile,
    jsonb_build_object('grant_id',v_id,'units',p_units));
  return jsonb_build_object('ok',true,'grant_id',v_id);
end;
$fn$;

revoke all on function public._identity_owner_for_uid(uuid) from public,anon,authenticated;
revoke all on function public.identity_owner_id() from public,anon,authenticated;
revoke all on function public._organization_active_enterprise(uuid) from public,anon,authenticated;
revoke all on function public._organization_is_founder(uuid,uuid) from public,anon,authenticated;
revoke all on function public._organization_can_manage(uuid,uuid) from public,anon,authenticated;
revoke all on function public._organization_rebuild_shareholders(uuid) from public,anon,authenticated;
revoke all on function public._organization_apply_allocations(uuid,jsonb,boolean,boolean) from public,anon,authenticated;
revoke all on function public._organization_apply_motion(uuid) from public,anon,authenticated;

revoke all on function public.list_my_organizations() from public,anon,authenticated;
revoke all on function public.set_active_organization(uuid) from public,anon,authenticated;
revoke all on function public.create_organization(text,text[]) from public,anon,authenticated;
revoke all on function public.invite_organization_founder(uuid,text) from public,anon,authenticated;
revoke all on function public.respond_organization_founder_invite(uuid,boolean) from public,anon,authenticated;
revoke all on function public.get_organization_state() from public,anon,authenticated;
revoke all on function public.propose_initial_split(jsonb,text,timestamptz) from public,anon,authenticated;
revoke all on function public.create_equity_motion(text,jsonb,text,timestamptz) from public,anon,authenticated;
revoke all on function public.cast_equity_vote(uuid,text) from public,anon,authenticated;
revoke all on function public.cancel_equity_motion(uuid,text) from public,anon,authenticated;
revoke all on function public.grant_employee_equity(uuid,numeric,timestamptz) from public,anon,authenticated;

grant execute on function public.identity_owner_id() to authenticated;
grant execute on function public.list_my_organizations() to authenticated;
grant execute on function public.set_active_organization(uuid) to authenticated;
grant execute on function public.create_organization(text,text[]) to authenticated;
grant execute on function public.invite_organization_founder(uuid,text) to authenticated;
grant execute on function public.respond_organization_founder_invite(uuid,boolean) to authenticated;
grant execute on function public.get_organization_state() to authenticated;
grant execute on function public.propose_initial_split(jsonb,text,timestamptz) to authenticated;
grant execute on function public.create_equity_motion(text,jsonb,text,timestamptz) to authenticated;
grant execute on function public.cast_equity_vote(uuid,text) to authenticated;
grant execute on function public.cancel_equity_motion(uuid,text) to authenticated;
grant execute on function public.grant_employee_equity(uuid,numeric,timestamptz) to authenticated;

-- Existing enterprises become founder-owned companies.
insert into public.organization_foundations(
  enterprise_id,status,created_by,finalized_at
)
select e.id,'active',e.owner_profile_id,coalesce(e.created_at,now())
  from public.enterprises e
 where not exists(select 1 from public.organization_foundations f
   where f.enterprise_id=e.id)
on conflict (enterprise_id) do nothing;

insert into public.organization_founders(
  enterprise_id,profile_id,status,is_original,approved_by,joined_at
)
select e.id,e.owner_profile_id,'active',true,e.owner_profile_id,e.created_at
  from public.enterprises e
 where not exists(select 1 from public.organization_founders f
   where f.enterprise_id=e.id and f.profile_id=e.owner_profile_id)
on conflict (enterprise_id,profile_id) do nothing;

insert into public.enterprise_shareholders(
  enterprise_id,profile_id,shares,updated_by
)
select e.id,e.owner_profile_id,100,e.owner_profile_id
  from public.enterprises e
 where exists(select 1 from public.enterprise_members m
   where m.enterprise_id=e.id and m.profile_id=e.owner_profile_id)
   and not exists(select 1 from public.enterprise_shareholders s
     where s.enterprise_id=e.id and s.profile_id=e.owner_profile_id)
on conflict (enterprise_id,profile_id) do nothing;

insert into public.organization_share_lots(
  enterprise_id,owner_profile_id,share_class,units,voting_weight,economic_weight
)
select s.enterprise_id,s.profile_id,'original',s.shares,1.1,1.0
  from public.enterprise_shareholders s
  join public.enterprises e on e.id=s.enterprise_id
 where s.profile_id=e.owner_profile_id and s.shares>0
   and not exists(select 1 from public.organization_share_lots l
     where l.enterprise_id=s.enterprise_id and l.owner_profile_id=s.profile_id
       and l.share_class='original' and l.status='active');

insert into public.organization_share_lots(
  enterprise_id,owner_profile_id,share_class,units,voting_weight,economic_weight
)
select s.enterprise_id,s.profile_id,'ordinary',s.shares,1.0,1.0
  from public.enterprise_shareholders s
  join public.enterprises e on e.id=s.enterprise_id
 where s.profile_id<>e.owner_profile_id and s.shares>0
   and not exists(select 1 from public.organization_share_lots l
     where l.enterprise_id=s.enterprise_id and l.owner_profile_id=s.profile_id
       and l.status='active');
