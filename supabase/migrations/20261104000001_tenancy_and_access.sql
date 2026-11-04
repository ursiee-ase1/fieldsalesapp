-- Tenancy, identity, roles and audit.
--
-- Isolation model:
--   * Every tenant table carries company_id and has RLS enabled.
--   * A user's company and role are resolved from `memberships` on every
--     request (not from JWT claims), so suspension takes effect immediately.
--   * Clients may read through RLS; writes that matter go through
--     SECURITY DEFINER functions that re-check role and membership.
--   * MVP: a user belongs to at most one company (enforced by unique index).

create schema if not exists app;
grant usage on schema app to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type app.member_role as enum ('admin', 'manager', 'agent');
create type app.member_status as enum ('active', 'suspended');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 2 and 120),
  country     text not null default 'GH' check (country ~ '^[A-Z]{2}$'),
  timezone    text not null default 'Africa/Accra',
  currency    text not null default 'GHS' check (currency ~ '^[A-Z]{3}$'),
  plan        text not null default 'mvp',
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.profiles (
  user_id             uuid primary key references auth.users (id) on delete cascade,
  full_name           text not null check (length(trim(full_name)) between 2 and 120),
  phone_e164          text check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  preferred_language  text not null default 'en' check (preferred_language in ('en', 'tw')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 80),
  created_at  timestamptz not null default now(),
  unique (company_id, name),
  unique (company_id, id)
);

create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        app.member_role not null,
  status      app.member_status not null default 'active',
  team_id     uuid,
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (company_id, team_id) references public.teams (company_id, id)
);

-- One company per user in the MVP.
create unique index memberships_one_company_per_user on public.memberships (user_id);
create index memberships_company_role on public.memberships (company_id, role);

create table public.audit_log (
  id          bigint generated always as identity primary key,
  company_id  uuid not null references public.companies (id) on delete cascade,
  actor_id    uuid references auth.users (id),
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  before      jsonb,
  after       jsonb,
  created_at  timestamptz not null default now()
);

create index audit_log_company_created on public.audit_log (company_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------

-- The caller's active membership, or no row. SECURITY DEFINER so policies can
-- use it without recursing into memberships' own RLS.
create function app.current_membership()
returns table (company_id uuid, role app.member_role)
language sql stable security definer set search_path = ''
as $$
  select m.company_id, m.role
  from public.memberships m
  where m.user_id = auth.uid() and m.status = 'active'
$$;

create function app.current_company_id()
returns uuid
language sql stable security definer set search_path = ''
as $$ select company_id from app.current_membership() $$;

create function app.current_role()
returns app.member_role
language sql stable security definer set search_path = ''
as $$ select role from app.current_membership() $$;

create function app.has_role(variadic roles app.member_role[])
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(app.current_role() = any (roles), false) $$;

-- Raises unless the caller is an active member with one of the given roles.
-- Returns the caller's company_id.
create function app.require_role(variadic roles app.member_role[])
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid;
  v_role app.member_role;
begin
  select company_id, role into v_company, v_role from app.current_membership();
  if v_company is null or not (v_role = any (roles)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return v_company;
end;
$$;

create function app.write_audit(
  p_company uuid, p_action text, p_entity text, p_entity_id uuid,
  p_before jsonb default null, p_after jsonb default null
) returns void
language sql security definer set search_path = ''
as $$
  insert into public.audit_log (company_id, actor_id, action, entity, entity_id, before, after)
  values (p_company, auth.uid(), p_action, p_entity, p_entity_id, p_before, p_after)
$$;

-- Ghana-first phone normalisation. Returns E.164 or raises.
-- Accepts 0XXXXXXXXX, 233XXXXXXXXX, +233XXXXXXXXX, with spaces/dashes.
create function app.normalize_phone(p_raw text, p_country text default 'GH')
returns text
language plpgsql immutable set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_raw, ''), '[\s\-().]', '', 'g');
begin
  if p_country <> 'GH' then
    if v ~ '^\+[1-9][0-9]{7,14}$' then return v; end if;
    raise exception 'invalid_phone' using errcode = '22023';
  end if;
  if v ~ '^0[235][0-9]{8}$' then return '+233' || substr(v, 2); end if;
  if v ~ '^233[235][0-9]{8}$' then return '+' || v; end if;
  if v ~ '^\+233[235][0-9]{8}$' then return v; end if;
  raise exception 'invalid_phone' using errcode = '22023';
end;
$$;

create function app.touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end; $$;

create trigger companies_touch before update on public.companies
  for each row execute function app.touch_updated_at();
create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();
create trigger memberships_touch before update on public.memberships
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.companies   enable row level security;
alter table public.profiles    enable row level security;
alter table public.teams       enable row level security;
alter table public.memberships enable row level security;
alter table public.audit_log   enable row level security;

-- Clients get read access only; every write goes through functions below.
revoke all on public.companies, public.profiles, public.teams,
              public.memberships, public.audit_log from anon, authenticated;
grant select on public.companies, public.profiles, public.teams,
                public.memberships to authenticated;
grant select on public.audit_log to authenticated;

create policy companies_member_read on public.companies for select to authenticated
  using (id = (select app.current_company_id()));

create policy teams_member_read on public.teams for select to authenticated
  using (company_id = (select app.current_company_id()));

-- Admins and managers see all memberships in their company; agents see their own.
create policy memberships_read on public.memberships for select to authenticated
  using (
    user_id = (select auth.uid())
    or (company_id = (select app.current_company_id())
        and (select app.has_role('admin', 'manager')))
  );

-- Own profile, or profiles of members of the same company for admins/managers.
create policy profiles_read on public.profiles for select to authenticated
  using (
    user_id = (select auth.uid())
    or ((select app.has_role('admin', 'manager')) and exists (
      select 1 from public.memberships m
      where m.user_id = profiles.user_id
        and m.company_id = (select app.current_company_id())
    ))
  );

create policy audit_admin_read on public.audit_log for select to authenticated
  using (company_id = (select app.current_company_id())
         and (select app.has_role('admin', 'manager')));

-- ---------------------------------------------------------------------------
-- Commands (RPC)
-- ---------------------------------------------------------------------------

-- Self-serve onboarding: the signed-in user creates a company and becomes admin.
create function public.create_company(p_name text, p_full_name text, p_phone text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_company uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if exists (select 1 from public.memberships where user_id = v_uid) then
    raise exception 'already_member' using errcode = '23505';
  end if;

  insert into public.companies (name) values (trim(p_name)) returning id into v_company;

  insert into public.profiles (user_id, full_name, phone_e164)
  values (v_uid, trim(p_full_name),
          case when nullif(trim(p_phone), '') is null then null
               else app.normalize_phone(p_phone) end)
  on conflict (user_id) do update set full_name = excluded.full_name,
                                      phone_e164 = coalesce(excluded.phone_e164, public.profiles.phone_e164);

  insert into public.memberships (company_id, user_id, role, created_by)
  values (v_company, v_uid, 'admin', v_uid);

  perform app.write_audit(v_company, 'company.created', 'company', v_company,
                          null, jsonb_build_object('name', trim(p_name)));
  return v_company;
end;
$$;

-- Called by the invite-member Edge Function (service role) after it creates the
-- auth user. p_inviter is the authenticated caller the function verified.
create function public.admin_add_member(
  p_inviter uuid, p_user uuid, p_role app.member_role, p_full_name text,
  p_phone text default null, p_team uuid default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid;
  v_inviter_role app.member_role;
  v_membership uuid;
begin
  select company_id, role into v_company, v_inviter_role
  from public.memberships where user_id = p_inviter and status = 'active';

  if v_company is null
     or v_inviter_role = 'agent'
     or (v_inviter_role = 'manager' and p_role <> 'agent') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  insert into public.profiles (user_id, full_name, phone_e164)
  values (p_user, trim(p_full_name),
          case when p_phone is null then null else app.normalize_phone(p_phone) end)
  on conflict (user_id) do update set full_name = excluded.full_name,
                                      phone_e164 = excluded.phone_e164;

  insert into public.memberships (company_id, user_id, role, team_id, created_by)
  values (v_company, p_user, p_role, p_team, p_inviter)
  returning id into v_membership;

  perform app.write_audit(v_company, 'member.added', 'membership', v_membership, null,
    jsonb_build_object('user_id', p_user, 'role', p_role, 'invited_by', p_inviter));
  return v_membership;
end;
$$;

revoke all on function public.admin_add_member from public, anon, authenticated;
grant execute on function public.admin_add_member to service_role;

-- Change role or status. Admins manage anyone except themselves;
-- managers may only suspend/reactivate agents.
create function public.update_member(p_membership uuid, p_role app.member_role default null,
                                     p_status app.member_status default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_caller_role app.member_role := app.current_role();
  v_old public.memberships;
begin
  select * into v_old from public.memberships
  where id = p_membership and company_id = v_company
  for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_old.user_id = auth.uid() then
    raise exception 'cannot_modify_self' using errcode = '42501';
  end if;
  if v_caller_role = 'manager' and (v_old.role <> 'agent' or p_role is not null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.memberships
  set role = coalesce(p_role, role), status = coalesce(p_status, status)
  where id = p_membership;

  perform app.write_audit(v_company, 'member.updated', 'membership', p_membership,
    jsonb_build_object('role', v_old.role, 'status', v_old.status),
    jsonb_build_object('role', coalesce(p_role, v_old.role), 'status', coalesce(p_status, v_old.status)));
end;
$$;

create function public.update_my_profile(p_full_name text default null,
                                         p_preferred_language text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.profiles
  set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
      preferred_language = coalesce(p_preferred_language, preferred_language)
  where user_id = auth.uid();
end;
$$;

create function public.create_team(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_team uuid;
begin
  insert into public.teams (company_id, name) values (v_company, trim(p_name)) returning id into v_team;
  perform app.write_audit(v_company, 'team.created', 'team', v_team, null, jsonb_build_object('name', trim(p_name)));
  return v_team;
end;
$$;

-- Session bootstrap for the app: who am I, which company, which role.
create function public.my_context()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'full_name', p.full_name,
    'preferred_language', coalesce(p.preferred_language, 'en'),
    'membership', case when m.id is null then null else jsonb_build_object(
      'id', m.id, 'company_id', m.company_id, 'company_name', c.name,
      'role', m.role, 'status', m.status) end
  )
  from (select auth.uid() as uid) me
  left join public.profiles p on p.user_id = me.uid
  left join public.memberships m on m.user_id = me.uid
  left join public.companies c on c.id = m.company_id
$$;

revoke all on function public.create_company, public.update_member, public.update_my_profile,
                       public.create_team, public.my_context from public, anon;
grant execute on function public.create_company, public.update_member, public.update_my_profile,
                          public.create_team, public.my_context to authenticated;

-- Helpers are not part of the client API.
revoke all on function app.current_membership, app.current_company_id, app.current_role,
                       app.has_role, app.require_role, app.write_audit
  from public, anon;
grant execute on function app.current_membership, app.current_company_id, app.current_role,
                          app.has_role, app.require_role
  to authenticated, service_role;
grant execute on function app.normalize_phone to authenticated, service_role;

-- Member directory for admins and managers (memberships joined to profiles).
create function public.list_members()
returns table (membership_id uuid, user_id uuid, full_name text, phone_e164 text,
               role app.member_role, status app.member_status, team_id uuid, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select m.id, m.user_id, p.full_name, p.phone_e164, m.role, m.status, m.team_id, m.created_at
  from public.memberships m
  join public.profiles p on p.user_id = m.user_id
  where m.company_id = v_company
  order by m.role, p.full_name;
end;
$$;

revoke all on function public.list_members from public, anon;
grant execute on function public.list_members to authenticated;
