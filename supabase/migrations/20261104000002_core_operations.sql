-- Core operations: products, inventory ledger, customers, daily reports,
-- sales, stock counts/discrepancies and daily targets.
--
-- Rules carried over from the plan:
--   * Stock is an append-only ledger. Balances are derived (trigger-maintained
--     cache) and never written by clients.
--   * Every client-originated command carries a client_op_id; replays return
--     the stored result instead of applying twice.
--   * Timestamps come from the server. The business date is the server date
--     in the company timezone, except for late offline syncs (§1.5 of plan).
--   * Agents' oversold sales are accepted and flagged, never dropped.

-- ---------------------------------------------------------------------------
-- Onboarding hardening: only email accounts may create a company. Phone
-- accounts are created by companies through invite-member.
-- ---------------------------------------------------------------------------

create or replace function public.create_company(p_name text, p_full_name text, p_phone text default null)
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
  if not exists (select 1 from auth.users where id = v_uid and email is not null) then
    raise exception 'email_account_required' using errcode = '42501';
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

-- ---------------------------------------------------------------------------
-- Shared infrastructure: idempotency and rate limits
-- ---------------------------------------------------------------------------

create table public.idempotency_keys (
  company_id     uuid not null references public.companies (id) on delete cascade,
  client_op_id   uuid not null,
  command        text not null,
  result         jsonb,
  created_at     timestamptz not null default now(),
  primary key (company_id, client_op_id)
);

-- Claims an operation id. Returns the stored result for a replay, or null
-- when the caller should go ahead (and later call app.finish_op).
create function app.begin_op(p_company uuid, p_op uuid, p_command text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_row public.idempotency_keys;
begin
  if p_op is null then
    raise exception 'validation_failed' using errcode = '22023', detail = 'client_op_id is required';
  end if;
  insert into public.idempotency_keys (company_id, client_op_id, command)
  values (p_company, p_op, p_command)
  on conflict do nothing;
  if found then return null; end if;

  select * into v_row from public.idempotency_keys where company_id = p_company and client_op_id = p_op;
  if v_row.command <> p_command then
    raise exception 'idempotency_key_reused' using errcode = '22023';
  end if;
  return v_row.result;
end;
$$;

create function app.finish_op(p_company uuid, p_op uuid, p_result jsonb)
returns jsonb
language sql security definer set search_path = ''
as $$
  update public.idempotency_keys set result = p_result
  where company_id = p_company and client_op_id = p_op;
  select p_result;
$$;

create table public.rate_limits (
  user_id       uuid not null,
  bucket        text not null,
  window_start  timestamptz not null,
  count         int not null default 0,
  primary key (user_id, bucket, window_start)
);

create function app.consume_rate(p_bucket text, p_max int, p_window_seconds int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_count int;
begin
  insert into public.rate_limits (user_id, bucket, window_start, count)
  values (auth.uid(), p_bucket, v_window, 1)
  on conflict (user_id, bucket, window_start) do update set count = public.rate_limits.count + 1
  returning count into v_count;
  if v_count > p_max then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
end;
$$;

-- Today's date in the company's timezone.
create function app.business_date(p_company uuid)
returns date
language sql stable security definer set search_path = ''
as $$ select (now() at time zone c.timezone)::date from public.companies c where c.id = p_company $$;

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------

create table public.products (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id) on delete cascade,
  sku         text,
  name        text not null check (length(trim(name)) between 1 and 120),
  aliases     text[] not null default '{}',
  unit_price  numeric(12, 2) not null check (unit_price >= 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, id)
);

create unique index products_company_name on public.products (company_id, lower(name));
create unique index products_company_sku on public.products (company_id, sku) where sku is not null;
create trigger products_touch before update on public.products
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Inventory ledger
-- ---------------------------------------------------------------------------

create type app.location_kind as enum ('store', 'agent', 'customer', 'write_off', 'external', 'adjustment');
create type app.movement_type as enum
  ('receipt', 'issue', 'return', 'sale', 'sale_void', 'damage', 'loss', 'adjustment');

create table public.stock_locations (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id) on delete cascade,
  kind        app.location_kind not null,
  agent_id    uuid references auth.users (id),
  name        text not null,
  unique (company_id, id),
  check ((kind = 'agent') = (agent_id is not null))
);

create unique index stock_locations_system on public.stock_locations (company_id, kind) where kind <> 'agent';
create unique index stock_locations_agent on public.stock_locations (company_id, agent_id) where kind = 'agent';

create table public.stock_movements (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies (id) on delete cascade,
  product_id        uuid not null,
  quantity          int not null check (quantity > 0),
  from_location_id  uuid not null,
  to_location_id    uuid not null,
  movement_type     app.movement_type not null,
  sale_id           uuid,
  report_id         uuid,
  reason            text,
  performed_by      uuid references auth.users (id),
  approved_by       uuid references auth.users (id),
  client_op_id      uuid,
  created_at        timestamptz not null default now(),
  check (from_location_id <> to_location_id),
  foreign key (company_id, product_id) references public.products (company_id, id),
  foreign key (company_id, from_location_id) references public.stock_locations (company_id, id),
  foreign key (company_id, to_location_id) references public.stock_locations (company_id, id)
);

create index stock_movements_company_created on public.stock_movements (company_id, created_at desc);
create index stock_movements_from on public.stock_movements (from_location_id, product_id);
create index stock_movements_to on public.stock_movements (to_location_id, product_id);

-- Derived cache of quantities held at store and agent locations.
create table public.stock_balances (
  company_id   uuid not null references public.companies (id) on delete cascade,
  location_id  uuid not null references public.stock_locations (id) on delete cascade,
  product_id   uuid not null references public.products (id) on delete cascade,
  quantity     int not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (location_id, product_id)
);

create function app.apply_movement_to_balances()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.stock_balances (company_id, location_id, product_id, quantity)
  select new.company_id, l.id, new.product_id,
         case when l.id = new.from_location_id then -new.quantity else new.quantity end
  from public.stock_locations l
  where l.id in (new.from_location_id, new.to_location_id) and l.kind in ('store', 'agent')
  on conflict (location_id, product_id) do update
    set quantity = public.stock_balances.quantity + excluded.quantity, updated_at = now();
  return new;
end;
$$;

create trigger stock_movements_balances after insert on public.stock_movements
  for each row execute function app.apply_movement_to_balances();

create function app.reject_change()
returns trigger language plpgsql set search_path = ''
as $$ begin raise exception '% is append-only', tg_table_name using errcode = '42501'; end; $$;

create trigger stock_movements_append_only before update or delete on public.stock_movements
  for each row execute function app.reject_change();

-- System locations for every company (and for companies created before this migration).
create function app.create_system_locations()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.stock_locations (company_id, kind, name)
  values (new.id, 'store', 'Company store'), (new.id, 'customer', 'Customers'),
         (new.id, 'write_off', 'Written off'), (new.id, 'external', 'Supplier'),
         (new.id, 'adjustment', 'Adjustments');
  return new;
end;
$$;

create trigger companies_system_locations after insert on public.companies
  for each row execute function app.create_system_locations();

insert into public.stock_locations (company_id, kind, name)
select c.id, k.kind::app.location_kind, k.name
from public.companies c
cross join (values ('store', 'Company store'), ('customer', 'Customers'), ('write_off', 'Written off'),
                   ('external', 'Supplier'), ('adjustment', 'Adjustments')) as k(kind, name)
on conflict do nothing;

create function app.system_location(p_company uuid, p_kind app.location_kind)
returns uuid
language sql stable security definer set search_path = ''
as $$ select id from public.stock_locations where company_id = p_company and kind = p_kind $$;

-- The agent's holding location, created on first use.
create function app.agent_location(p_company uuid, p_agent uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.stock_locations
  where company_id = p_company and kind = 'agent' and agent_id = p_agent;
  if v_id is null then
    if not exists (select 1 from public.memberships
                   where company_id = p_company and user_id = p_agent and role = 'agent') then
      raise exception 'not_found' using errcode = 'P0002', detail = 'agent';
    end if;
    insert into public.stock_locations (company_id, kind, agent_id, name)
    values (p_company, 'agent', p_agent,
            coalesce((select full_name from public.profiles where user_id = p_agent), 'Agent'))
    on conflict do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.stock_locations
      where company_id = p_company and kind = 'agent' and agent_id = p_agent;
    end if;
  end if;
  return v_id;
end;
$$;

create function app.balance(p_location uuid, p_product uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select coalesce((select quantity from public.stock_balances
                   where location_id = p_location and product_id = p_product), 0)
$$;

create function app.move(
  p_company uuid, p_product uuid, p_qty int, p_from uuid, p_to uuid, p_type app.movement_type,
  p_reason text default null, p_sale uuid default null, p_report uuid default null,
  p_op uuid default null, p_approved_by uuid default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.stock_movements (company_id, product_id, quantity, from_location_id, to_location_id,
    movement_type, reason, sale_id, report_id, client_op_id, performed_by, approved_by)
  values (p_company, p_product, p_qty, p_from, p_to, p_type, nullif(trim(p_reason), ''),
          p_sale, p_report, p_op, auth.uid(), p_approved_by)
  returning id into v_id;
  return v_id;
end;
$$;

-- Raises unless the product is an active product of the company.
create function app.require_product(p_company uuid, p_product uuid)
returns public.products
language plpgsql stable security definer set search_path = ''
as $$
declare
  v public.products;
begin
  select * into v from public.products where id = p_product and company_id = p_company;
  if not found then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown product ' || coalesce(p_product::text, 'null');
  end if;
  if not v.active then
    raise exception 'validation_failed' using errcode = '22023', detail = 'product ' || v.name || ' is inactive';
  end if;
  return v;
end;
$$;

create function app.require_positive_qty(p_qty int)
returns int
language plpgsql immutable set search_path = ''
as $$
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'quantity must be a positive whole number';
  end if;
  return p_qty;
end;
$$;

-- ---------------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------------

create table public.customers (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies (id) on delete cascade,
  full_name           text not null check (length(trim(full_name)) between 2 and 120),
  phone_e164          text check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  location_text       text,
  notes               text,
  interest_product_id uuid,
  consent_given       boolean not null default false,
  consent_method      text,
  consent_at          timestamptz,
  created_by          uuid references auth.users (id),
  assigned_agent_id   uuid references auth.users (id),
  merged_into_id      uuid references public.customers (id),
  version             int not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, interest_product_id) references public.products (company_id, id),
  check (phone_e164 is null or consent_given)
);

-- Not unique: family members often share one phone.
create index customers_company_phone on public.customers (company_id, phone_e164);
create trigger customers_touch before update on public.customers
  for each row execute function app.touch_updated_at();

create table public.customer_interactions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies (id) on delete cascade,
  customer_id  uuid not null,
  agent_id     uuid references auth.users (id),
  report_id    uuid,
  kind         text not null check (kind in ('sale', 'prospect', 'follow_up', 'note')),
  product_id   uuid,
  notes        text,
  created_at   timestamptz not null default now(),
  foreign key (company_id, customer_id) references public.customers (company_id, id)
);

create index customer_interactions_customer on public.customer_interactions (customer_id, created_at desc);
create index customer_interactions_agent on public.customer_interactions (agent_id, customer_id);

create table public.follow_ups (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies (id) on delete cascade,
  customer_id       uuid not null,
  agent_id          uuid not null references auth.users (id),
  due_date          date not null,
  note              text,
  status            text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  outcome           text check (outcome in ('contacted', 'not_reached', 'sold', 'not_interested')),
  source_report_id  uuid,
  created_at        timestamptz not null default now(),
  closed_at         timestamptz,
  foreign key (company_id, customer_id) references public.customers (company_id, id)
);

create index follow_ups_agent_open on public.follow_ups (agent_id, due_date) where status = 'open';

create table public.customer_match_reviews (
  id                     uuid primary key default gen_random_uuid(),
  company_id             uuid not null references public.companies (id) on delete cascade,
  new_customer_id        uuid not null,
  candidate_customer_id  uuid not null,
  state                  text not null default 'pending' check (state in ('pending', 'same', 'different')),
  resolved_by            uuid references auth.users (id),
  resolved_at            timestamptz,
  created_at             timestamptz not null default now(),
  unique (new_customer_id, candidate_customer_id),
  foreign key (company_id, new_customer_id) references public.customers (company_id, id),
  foreign key (company_id, candidate_customer_id) references public.customers (company_id, id)
);

-- ---------------------------------------------------------------------------
-- Daily reports, sales, stock counts
-- ---------------------------------------------------------------------------

create table public.daily_reports (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies (id) on delete cascade,
  agent_id            uuid not null references auth.users (id),
  business_date       date not null,
  no_sales_declared   boolean not null default false,
  sales_count         int not null default 0,
  units_sold          int not null default 0,
  total_amount        numeric(12, 2) not null default 0,
  prospects_count     int,
  missing_counts      int not null default 0,
  comments            text,
  late_sync           boolean not null default false,
  first_received_at   timestamptz not null default now(),
  last_received_at    timestamptz not null default now(),
  unique (company_id, agent_id, business_date),
  unique (company_id, id)
);

create index daily_reports_company_date on public.daily_reports (company_id, business_date);

-- Every submission as received, for audit and replays.
create table public.report_submissions (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies (id) on delete cascade,
  report_id           uuid not null,
  client_op_id        uuid not null,
  source              text not null check (source in ('form', 'conversation')),
  payload             jsonb not null,
  client_captured_at  timestamptz,
  client_time_used    boolean not null,
  received_at         timestamptz not null default now(),
  unique (company_id, client_op_id),
  foreign key (company_id, report_id) references public.daily_reports (company_id, id)
);

create table public.sales (
  id              uuid primary key,             -- generated by the client
  company_id      uuid not null references public.companies (id) on delete cascade,
  agent_id        uuid not null references auth.users (id),
  report_id       uuid not null,
  customer_id     uuid,
  product_id      uuid not null,
  quantity        int not null check (quantity > 0),
  unit_price      numeric(12, 2) not null check (unit_price >= 0),
  catalog_price   numeric(12, 2) not null,
  total_amount    numeric(12, 2) not null,
  price_override  boolean not null default false,
  price_flagged   boolean not null default false, -- discount beyond the company threshold
  stock_flagged   boolean not null default false, -- agent's ledger balance went negative
  payment_method  text not null check (payment_method in ('cash', 'momo')),
  payment_status  text not null default 'paid' check (payment_status = 'paid'), -- credit later (D2)
  recorded_at     timestamptz not null default now(),
  voided_at       timestamptz,
  voided_by       uuid references auth.users (id),
  void_reason     text,
  unique (company_id, id),
  foreign key (company_id, report_id) references public.daily_reports (company_id, id),
  foreign key (company_id, product_id) references public.products (company_id, id),
  foreign key (company_id, customer_id) references public.customers (company_id, id)
);

create index sales_company_recorded on public.sales (company_id, recorded_at desc);
create index sales_report on public.sales (report_id);

create table public.stock_counts (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies (id) on delete cascade,
  agent_id       uuid not null references auth.users (id),
  product_id     uuid not null,
  business_date  date not null,
  report_id      uuid not null,
  reported_qty   int not null check (reported_qty >= 0),
  expected_qty   int not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (company_id, agent_id, product_id, business_date),
  foreign key (company_id, product_id) references public.products (company_id, id),
  foreign key (company_id, report_id) references public.daily_reports (company_id, id)
);

create table public.stock_discrepancies (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references public.companies (id) on delete cascade,
  stock_count_id          uuid not null unique references public.stock_counts (id),
  agent_id                uuid not null references auth.users (id),
  product_id              uuid not null,
  business_date           date not null,
  expected_qty            int not null,
  reported_qty            int not null,
  difference              int generated always as (reported_qty - expected_qty) stored,
  status                  text not null default 'open' check (status in ('open', 'resolved', 'written_off', 'dismissed')),
  resolution_movement_id  uuid references public.stock_movements (id),
  resolved_by             uuid references auth.users (id),
  resolved_at             timestamptz,
  note                    text,
  created_at              timestamptz not null default now(),
  foreign key (company_id, product_id) references public.products (company_id, id)
);

create index stock_discrepancies_open on public.stock_discrepancies (company_id, status);

-- ---------------------------------------------------------------------------
-- Daily targets
-- ---------------------------------------------------------------------------

create table public.daily_targets (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies (id) on delete cascade,
  scope           text not null check (scope in ('company', 'team', 'agent')),
  team_id         uuid,
  agent_id        uuid references auth.users (id),
  product_id      uuid,
  metric          text not null check (metric in ('units', 'amount')),
  value           numeric(12, 2) not null check (value > 0),
  effective_from  date not null,
  effective_to    date,
  created_by      uuid references auth.users (id),
  created_at      timestamptz not null default now(),
  check ((scope = 'team') = (team_id is not null)),
  check ((scope = 'agent') = (agent_id is not null)),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (company_id, team_id) references public.teams (company_id, id),
  foreign key (company_id, product_id) references public.products (company_id, id)
);

create index daily_targets_lookup on public.daily_targets (company_id, scope, effective_from);

-- Most specific target wins per (metric, product): agent > team > company.
create function app.effective_targets(p_company uuid, p_agent uuid, p_date date)
returns table (target_id uuid, metric text, product_id uuid, value numeric, scope text)
language sql stable security definer set search_path = ''
as $$
  select distinct on (t.metric, t.product_id) t.id, t.metric, t.product_id, t.value, t.scope
  from public.daily_targets t
  left join public.memberships m on m.user_id = p_agent and m.company_id = p_company
  where t.company_id = p_company
    and t.effective_from <= p_date and (t.effective_to is null or t.effective_to >= p_date)
    and (t.scope = 'company'
         or (t.scope = 'team' and t.team_id = m.team_id)
         or (t.scope = 'agent' and t.agent_id = p_agent))
  order by t.metric, t.product_id, case t.scope when 'agent' then 0 when 'team' then 1 else 2 end
$$;

-- ---------------------------------------------------------------------------
-- Row-level security (reads only; writes go through functions)
-- ---------------------------------------------------------------------------

alter table public.idempotency_keys      enable row level security;
alter table public.rate_limits           enable row level security;
alter table public.products              enable row level security;
alter table public.stock_locations       enable row level security;
alter table public.stock_movements       enable row level security;
alter table public.stock_balances        enable row level security;
alter table public.customers             enable row level security;
alter table public.customer_interactions enable row level security;
alter table public.follow_ups            enable row level security;
alter table public.customer_match_reviews enable row level security;
alter table public.daily_reports         enable row level security;
alter table public.report_submissions    enable row level security;
alter table public.sales                 enable row level security;
alter table public.stock_counts          enable row level security;
alter table public.stock_discrepancies   enable row level security;
alter table public.daily_targets         enable row level security;

revoke all on public.idempotency_keys, public.rate_limits, public.products, public.stock_locations,
              public.stock_movements, public.stock_balances, public.customers, public.customer_interactions,
              public.follow_ups, public.customer_match_reviews, public.daily_reports, public.report_submissions,
              public.sales, public.stock_counts, public.stock_discrepancies, public.daily_targets
  from anon, authenticated;

grant select on public.products, public.stock_locations, public.stock_movements, public.stock_balances,
                public.customers, public.customer_interactions, public.follow_ups,
                public.customer_match_reviews, public.daily_reports, public.sales, public.stock_counts,
                public.stock_discrepancies, public.daily_targets
  to authenticated;

-- Shorthands used by the policies below.
create function app.is_manager()
returns boolean language sql stable security definer set search_path = ''
as $$ select app.has_role('admin', 'manager') $$;
grant execute on function app.is_manager to authenticated;

create policy products_read on public.products for select to authenticated
  using (company_id = (select app.current_company_id()));

create policy locations_read on public.stock_locations for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy balances_read on public.stock_balances for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or exists (
           select 1 from public.stock_locations l
           where l.id = stock_balances.location_id and l.agent_id = (select auth.uid()))));

create policy movements_read on public.stock_movements for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or exists (
           select 1 from public.stock_locations l
           where l.id in (stock_movements.from_location_id, stock_movements.to_location_id)
             and l.agent_id = (select auth.uid()))));

-- D4: agents see customers they created, are assigned, or have interacted with.
create policy customers_read on public.customers for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager())
              or created_by = (select auth.uid())
              or assigned_agent_id = (select auth.uid())
              or exists (select 1 from public.customer_interactions i
                         where i.customer_id = customers.id and i.agent_id = (select auth.uid()))));

create policy interactions_read on public.customer_interactions for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy follow_ups_read on public.follow_ups for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy match_reviews_read on public.customer_match_reviews for select to authenticated
  using (company_id = (select app.current_company_id()) and (select app.is_manager()));

create policy reports_read on public.daily_reports for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy sales_read on public.sales for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy counts_read on public.stock_counts for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy discrepancies_read on public.stock_discrepancies for select to authenticated
  using (company_id = (select app.current_company_id()) and (select app.is_manager()));

create policy targets_read on public.daily_targets for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid()) or scope <> 'agent'));

-- ---------------------------------------------------------------------------
-- Commands: products
-- ---------------------------------------------------------------------------

create function public.save_product(
  p_id uuid, p_name text, p_unit_price numeric, p_sku text default null,
  p_aliases text[] default '{}', p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_old public.products;
  v_id uuid;
begin
  if p_unit_price is null or p_unit_price < 0 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'price must be zero or more';
  end if;
  if p_id is null then
    insert into public.products (company_id, name, unit_price, sku, aliases, active)
    values (v_company, trim(p_name), p_unit_price, nullif(trim(p_sku), ''),
            coalesce(p_aliases, '{}'), coalesce(p_active, true))
    returning id into v_id;
    perform app.write_audit(v_company, 'product.created', 'product', v_id, null,
      jsonb_build_object('name', trim(p_name), 'unit_price', p_unit_price));
  else
    select * into v_old from public.products where id = p_id and company_id = v_company for update;
    if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
    update public.products
    set name = trim(p_name), unit_price = p_unit_price, sku = nullif(trim(p_sku), ''),
        aliases = coalesce(p_aliases, '{}'), active = coalesce(p_active, true)
    where id = p_id;
    v_id := p_id;
    perform app.write_audit(v_company, 'product.updated', 'product', v_id,
      jsonb_build_object('name', v_old.name, 'unit_price', v_old.unit_price, 'active', v_old.active),
      jsonb_build_object('name', trim(p_name), 'unit_price', p_unit_price, 'active', coalesce(p_active, true)));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Commands: stock operations (managers)
-- ---------------------------------------------------------------------------

-- p_lines: [{"product_id": uuid, "quantity": int}]
-- p_kind: receipt (supplier → store), issue (store → agent), return (agent → store)
create function public.record_stock_transfer(
  p_client_op_id uuid, p_kind text, p_lines jsonb, p_agent_id uuid default null, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_prior jsonb;
  v_store uuid;
  v_from uuid;
  v_to uuid;
  v_line jsonb;
  v_product public.products;
  v_qty int;
  v_ids uuid[] := '{}';
begin
  v_prior := app.begin_op(v_company, p_client_op_id, 'stock.' || p_kind);
  if v_prior is not null then return v_prior; end if;

  if p_kind not in ('receipt', 'issue', 'return') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown transfer kind';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'at least one line is required';
  end if;

  v_store := app.system_location(v_company, 'store');
  case p_kind
    when 'receipt' then v_from := app.system_location(v_company, 'external'); v_to := v_store;
    when 'issue'   then v_from := v_store; v_to := app.agent_location(v_company, p_agent_id);
    when 'return'  then v_from := app.agent_location(v_company, p_agent_id); v_to := v_store;
  end case;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_product := app.require_product(v_company, (v_line ->> 'product_id')::uuid);
    v_qty := app.require_positive_qty((v_line ->> 'quantity')::int);
    -- Managers are online and hold the goods, so a transfer larger than the
    -- source balance is a data-entry error, not a field reality.
    if p_kind <> 'receipt' and app.balance(v_from, v_product.id) < v_qty then
      raise exception 'insufficient_stock' using errcode = '22023',
        detail = format('%s: only %s available', v_product.name, app.balance(v_from, v_product.id));
    end if;
    v_ids := v_ids || app.move(v_company, v_product.id, v_qty, v_from, v_to,
                               p_kind::app.movement_type, p_note, null, null, p_client_op_id);
  end loop;

  perform app.write_audit(v_company, 'stock.' || p_kind, 'stock_movement', v_ids[1], null,
    jsonb_build_object('agent_id', p_agent_id, 'lines', p_lines, 'note', p_note));
  return app.finish_op(v_company, p_client_op_id, jsonb_build_object('movement_ids', to_jsonb(v_ids)));
end;
$$;

-- Damage or loss, from the store (p_agent_id null) or an agent's holding.
create function public.record_write_off(
  p_client_op_id uuid, p_type text, p_product_id uuid, p_quantity int, p_reason text,
  p_agent_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_prior jsonb;
  v_from uuid;
  v_id uuid;
begin
  v_prior := app.begin_op(v_company, p_client_op_id, 'stock.write_off');
  if v_prior is not null then return v_prior; end if;
  if p_type not in ('damage', 'loss') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'type must be damage or loss';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'validation_failed' using errcode = '22023', detail = 'a reason is required';
  end if;
  perform app.require_product(v_company, p_product_id);
  perform app.require_positive_qty(p_quantity);

  v_from := case when p_agent_id is null then app.system_location(v_company, 'store')
                 else app.agent_location(v_company, p_agent_id) end;
  if app.balance(v_from, p_product_id) < p_quantity then
    raise exception 'insufficient_stock' using errcode = '22023',
      detail = format('only %s available', app.balance(v_from, p_product_id));
  end if;

  v_id := app.move(v_company, p_product_id, p_quantity, v_from, app.system_location(v_company, 'write_off'),
                   p_type::app.movement_type, p_reason, null, null, p_client_op_id, auth.uid());
  perform app.write_audit(v_company, 'stock.' || p_type, 'stock_movement', v_id, null,
    jsonb_build_object('agent_id', p_agent_id, 'product_id', p_product_id, 'quantity', p_quantity, 'reason', p_reason));
  return app.finish_op(v_company, p_client_op_id, jsonb_build_object('movement_id', v_id));
end;
$$;

-- Correction with an audit trail. Positive delta adds stock, negative removes.
create function public.adjust_stock(
  p_client_op_id uuid, p_product_id uuid, p_delta int, p_reason text, p_agent_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_prior jsonb;
  v_loc uuid;
  v_adj uuid;
  v_id uuid;
begin
  v_prior := app.begin_op(v_company, p_client_op_id, 'stock.adjust');
  if v_prior is not null then return v_prior; end if;
  if p_delta is null or p_delta = 0 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'adjustment cannot be zero';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'validation_failed' using errcode = '22023', detail = 'a reason is required';
  end if;
  perform app.require_product(v_company, p_product_id);

  v_loc := case when p_agent_id is null then app.system_location(v_company, 'store')
                else app.agent_location(v_company, p_agent_id) end;
  v_adj := app.system_location(v_company, 'adjustment');
  v_id := app.move(v_company, p_product_id, abs(p_delta),
                   case when p_delta > 0 then v_adj else v_loc end,
                   case when p_delta > 0 then v_loc else v_adj end,
                   'adjustment', p_reason, null, null, p_client_op_id, auth.uid());
  perform app.write_audit(v_company, 'stock.adjusted', 'stock_movement', v_id, null,
    jsonb_build_object('agent_id', p_agent_id, 'product_id', p_product_id, 'delta', p_delta, 'reason', p_reason));
  return app.finish_op(v_company, p_client_op_id, jsonb_build_object('movement_id', v_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- Commands: daily report (agents)
-- ---------------------------------------------------------------------------

-- Payload (same shape for the form now and the AI assistant in Phase 4):
-- {
--   "no_sales": bool,
--   "customers": [{"ref": "c1", "customer_id": uuid}                       -- existing
--               | {"ref": "c2", "full_name", "phone", "consent", "location",
--                  "interest_product_id", "notes", "not_same_as": [uuid]}], -- new
--   "sales": [{"id": uuid, "product_id", "quantity", "unit_price"?, "payment_method", "customer_ref"?}],
--   "stock_counts": [{"product_id", "quantity"}],
--   "prospects_count": int,
--   "follow_ups": [{"customer_ref", "due_date", "note"}],
--   "follow_up_outcomes": [{"follow_up_id", "outcome"}],
--   "comments": text
-- }
create function public.submit_report(
  p_client_op_id uuid, p_payload jsonb, p_client_captured_at timestamptz default null,
  p_source text default 'form'
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_agent uuid := auth.uid();
  v_prior jsonb;
  v_today date;
  v_date date;
  v_client_time_used boolean := false;
  v_tz text;
  v_report public.daily_reports;
  v_is_new_report boolean;
  v_agent_loc uuid;
  v_customer_loc uuid;
  v_refs jsonb := '{}';          -- customer ref -> customer id
  v_item jsonb;
  v_product public.products;
  v_qty int;
  v_price numeric;
  v_customer uuid;
  v_sale_id uuid;
  v_max_discount numeric;
  v_sales jsonb := '[]';
  v_new_customers jsonb := '[]';
  v_reviews jsonb := '[]';
  v_discrepancies jsonb := '[]';
  v_count_id uuid;
  v_expected int;
  v_phone text;
  v_candidate uuid;
  v_result jsonb;
begin
  v_prior := app.begin_op(v_company, p_client_op_id, 'report.submit');
  if v_prior is not null then return v_prior; end if;

  if p_source not in ('form', 'conversation') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown source';
  end if;
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'validation_failed' using errcode = '22023', detail = 'payload must be an object';
  end if;

  -- Business date: server date, unless a late offline sync carries a
  -- plausible capture time within the last 72 hours.
  select timezone, coalesce((settings ->> 'max_discount_pct')::numeric, 20)
  into v_tz, v_max_discount from public.companies where id = v_company;
  v_today := (now() at time zone v_tz)::date;
  v_date := v_today;
  if p_client_captured_at is not null
     and p_client_captured_at <= now() + interval '5 minutes'
     and p_client_captured_at >= now() - interval '72 hours' then
    v_date := (p_client_captured_at at time zone v_tz)::date;
    v_client_time_used := true;
  end if;

  select * into v_report from public.daily_reports
  where company_id = v_company and agent_id = v_agent and business_date = v_date
  for update;
  v_is_new_report := not found;

  if coalesce((p_payload ->> 'no_sales')::boolean, false)
     and jsonb_array_length(coalesce(p_payload -> 'sales', '[]')) > 0 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'cannot declare no sales and list sales';
  end if;
  if v_is_new_report
     and not coalesce((p_payload ->> 'no_sales')::boolean, false)
     and jsonb_array_length(coalesce(p_payload -> 'sales', '[]')) = 0 then
    raise exception 'validation_failed' using errcode = '22023',
      detail = 'record your sales, or say you made no sales today';
  end if;

  if v_is_new_report then
    insert into public.daily_reports (company_id, agent_id, business_date, late_sync)
    values (v_company, v_agent, v_date, v_date <> v_today)
    returning * into v_report;
  end if;

  v_agent_loc := app.agent_location(v_company, v_agent);
  v_customer_loc := app.system_location(v_company, 'customer');

  -- Customers: resolve existing references, create new ones.
  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'customers', '[]')) loop
    if coalesce(v_item ->> 'ref', '') = '' then
      raise exception 'validation_failed' using errcode = '22023', detail = 'each customer needs a ref';
    end if;
    if v_item ? 'customer_id' then
      v_customer := (v_item ->> 'customer_id')::uuid;
      if not exists (select 1 from public.customers where id = v_customer and company_id = v_company
                     and merged_into_id is null) then
        raise exception 'validation_failed' using errcode = '22023', detail = 'unknown customer';
      end if;
    else
      if length(trim(coalesce(v_item ->> 'full_name', ''))) < 2 then
        raise exception 'validation_failed' using errcode = '22023', detail = 'new customers need a name';
      end if;
      v_phone := case when nullif(trim(v_item ->> 'phone'), '') is null then null
                      else app.normalize_phone(v_item ->> 'phone') end;
      if v_phone is not null and not coalesce((v_item ->> 'consent')::boolean, false) then
        raise exception 'validation_failed' using errcode = '22023',
          detail = 'the customer must agree before their phone number is saved';
      end if;
      if v_item ? 'interest_product_id' then
        perform app.require_product(v_company, (v_item ->> 'interest_product_id')::uuid);
      end if;
      insert into public.customers (company_id, full_name, phone_e164, location_text, notes,
        interest_product_id, consent_given, consent_method, consent_at, created_by, assigned_agent_id)
      values (v_company, trim(v_item ->> 'full_name'), v_phone, nullif(trim(v_item ->> 'location'), ''),
              nullif(trim(v_item ->> 'notes'), ''), (v_item ->> 'interest_product_id')::uuid,
              v_phone is not null, case when v_phone is not null then 'verbal_via_agent' end,
              case when v_phone is not null then now() end, v_agent, v_agent)
      returning id into v_customer;
      v_new_customers := v_new_customers || jsonb_build_object('ref', v_item ->> 'ref', 'customer_id', v_customer);

      -- Same phone as an existing customer: a manager decides. Never auto-merge.
      if v_phone is not null then
        for v_candidate in
          select c.id from public.customers c
          where c.company_id = v_company and c.phone_e164 = v_phone and c.id <> v_customer
            and c.merged_into_id is null
            and not (c.id::text in (select jsonb_array_elements_text(coalesce(v_item -> 'not_same_as', '[]'))))
        loop
          insert into public.customer_match_reviews (company_id, new_customer_id, candidate_customer_id)
          values (v_company, v_customer, v_candidate);
          v_reviews := v_reviews || jsonb_build_object('new_customer_id', v_customer, 'candidate_customer_id', v_candidate);
        end loop;
      end if;
    end if;
    v_refs := v_refs || jsonb_build_object(v_item ->> 'ref', v_customer);
    if not exists (select 1 from jsonb_array_elements(coalesce(p_payload -> 'sales', '[]')) s
                   where s ->> 'customer_ref' = v_item ->> 'ref') then
      insert into public.customer_interactions (company_id, customer_id, agent_id, report_id, kind, product_id, notes)
      values (v_company, v_customer, v_agent, v_report.id, 'prospect',
              (v_item ->> 'interest_product_id')::uuid, nullif(trim(v_item ->> 'notes'), ''));
    end if;
  end loop;

  -- Sales
  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'sales', '[]')) loop
    v_sale_id := (v_item ->> 'id')::uuid;
    if v_sale_id is null then
      raise exception 'validation_failed' using errcode = '22023', detail = 'each sale needs an id';
    end if;
    if exists (select 1 from public.sales where id = v_sale_id) then
      raise exception 'duplicate_sale' using errcode = '23505', detail = v_sale_id::text;
    end if;
    v_product := app.require_product(v_company, (v_item ->> 'product_id')::uuid);
    v_qty := app.require_positive_qty((v_item ->> 'quantity')::int);
    v_price := coalesce((v_item ->> 'unit_price')::numeric, v_product.unit_price);
    if v_price < 0 then
      raise exception 'validation_failed' using errcode = '22023', detail = 'price cannot be negative';
    end if;
    if coalesce(v_item ->> 'payment_method', '') not in ('cash', 'momo') then
      raise exception 'validation_failed' using errcode = '22023', detail = 'payment method must be cash or momo';
    end if;
    v_customer := null;
    if v_item ? 'customer_ref' then
      v_customer := (v_refs ->> (v_item ->> 'customer_ref'))::uuid;
      if v_customer is null then
        raise exception 'validation_failed' using errcode = '22023', detail = 'sale refers to an unknown customer';
      end if;
    end if;

    insert into public.sales (id, company_id, agent_id, report_id, customer_id, product_id, quantity,
      unit_price, catalog_price, total_amount, price_override, price_flagged, payment_method)
    values (v_sale_id, v_company, v_agent, v_report.id, v_customer, v_product.id, v_qty,
      v_price, v_product.unit_price, round(v_price * v_qty, 2), v_price <> v_product.unit_price,
      v_product.unit_price > 0 and v_price < v_product.unit_price * (1 - v_max_discount / 100),
      v_item ->> 'payment_method');

    perform app.move(v_company, v_product.id, v_qty, v_agent_loc, v_customer_loc, 'sale',
                     null, v_sale_id, v_report.id, p_client_op_id);
    if app.balance(v_agent_loc, v_product.id) < 0 then
      update public.sales set stock_flagged = true where id = v_sale_id;
    end if;
    if v_customer is not null then
      insert into public.customer_interactions (company_id, customer_id, agent_id, report_id, kind, product_id)
      values (v_company, v_customer, v_agent, v_report.id, 'sale', v_product.id);
    end if;
    v_sales := v_sales || to_jsonb(v_sale_id);
  end loop;

  -- Closing stock counts: observations compared with the ledger, never written into it.
  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'stock_counts', '[]')) loop
    v_product := app.require_product(v_company, (v_item ->> 'product_id')::uuid);
    v_qty := (v_item ->> 'quantity')::int;
    if v_qty is null or v_qty < 0 then
      raise exception 'validation_failed' using errcode = '22023', detail = 'stock count must be zero or more';
    end if;
    v_expected := app.balance(v_agent_loc, v_product.id);

    insert into public.stock_counts (company_id, agent_id, product_id, business_date, report_id, reported_qty, expected_qty)
    values (v_company, v_agent, v_product.id, v_date, v_report.id, v_qty, v_expected)
    on conflict (company_id, agent_id, product_id, business_date)
      do update set reported_qty = excluded.reported_qty, expected_qty = excluded.expected_qty, updated_at = now()
    returning id into v_count_id;

    if v_qty <> v_expected then
      insert into public.stock_discrepancies (company_id, stock_count_id, agent_id, product_id, business_date,
                                              expected_qty, reported_qty)
      values (v_company, v_count_id, v_agent, v_product.id, v_date, v_expected, v_qty)
      -- A recount that still mismatches reopens the item with the new figures;
      -- the earlier resolution stays in the audit log.
      on conflict (stock_count_id) do update
        set expected_qty = excluded.expected_qty, reported_qty = excluded.reported_qty,
            status = 'open', resolution_movement_id = null, resolved_by = null, resolved_at = null, note = null;
      v_discrepancies := v_discrepancies || jsonb_build_object(
        'product_id', v_product.id, 'expected', v_expected, 'reported', v_qty);
    else
      -- A recount that now matches closes an open discrepancy.
      update public.stock_discrepancies
      set status = 'resolved', resolved_at = now(), note = 'Matched on recount',
          expected_qty = v_expected, reported_qty = v_qty
      where stock_count_id = v_count_id and status = 'open';
    end if;
  end loop;

  -- Follow-ups
  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'follow_ups', '[]')) loop
    v_customer := (v_refs ->> (v_item ->> 'customer_ref'))::uuid;
    if v_customer is null then
      raise exception 'validation_failed' using errcode = '22023', detail = 'follow-up refers to an unknown customer';
    end if;
    if (v_item ->> 'due_date')::date not between v_date and v_date + 90 then
      raise exception 'validation_failed' using errcode = '22023', detail = 'follow-up date must be within 90 days';
    end if;
    insert into public.follow_ups (company_id, customer_id, agent_id, due_date, note, source_report_id)
    values (v_company, v_customer, v_agent, (v_item ->> 'due_date')::date, nullif(trim(v_item ->> 'note'), ''), v_report.id);
    insert into public.customer_interactions (company_id, customer_id, agent_id, report_id, kind, notes)
    values (v_company, v_customer, v_agent, v_report.id, 'follow_up', nullif(trim(v_item ->> 'note'), ''));
  end loop;

  for v_item in select * from jsonb_array_elements(coalesce(p_payload -> 'follow_up_outcomes', '[]')) loop
    if coalesce(v_item ->> 'outcome', '') not in ('contacted', 'not_reached', 'sold', 'not_interested') then
      raise exception 'validation_failed' using errcode = '22023', detail = 'unknown follow-up outcome';
    end if;
    update public.follow_ups
    set status = case when v_item ->> 'outcome' = 'not_reached' then 'open' else 'done' end,
        outcome = v_item ->> 'outcome',
        closed_at = case when v_item ->> 'outcome' = 'not_reached' then null else now() end
    where id = (v_item ->> 'follow_up_id')::uuid and agent_id = v_agent and company_id = v_company;
    if not found then
      raise exception 'validation_failed' using errcode = '22023', detail = 'unknown follow-up';
    end if;
  end loop;

  -- Report totals are recomputed from the records, never trusted from the client.
  update public.daily_reports r
  set no_sales_declared = case when s.cnt > 0 then false
                               else r.no_sales_declared or coalesce((p_payload ->> 'no_sales')::boolean, false) end,
      sales_count = s.cnt, units_sold = s.units, total_amount = s.amount,
      prospects_count = coalesce((p_payload ->> 'prospects_count')::int, r.prospects_count),
      comments = case when nullif(trim(p_payload ->> 'comments'), '') is null then r.comments
                      else concat_ws(E'\n', r.comments, trim(p_payload ->> 'comments')) end,
      missing_counts = (
        select count(*) from public.stock_balances b
        where b.location_id = v_agent_loc and b.quantity <> 0
          and not exists (select 1 from public.stock_counts c
                          where c.agent_id = v_agent and c.product_id = b.product_id and c.business_date = v_date)),
      last_received_at = now()
  from (select count(*) as cnt, coalesce(sum(quantity), 0) as units, coalesce(sum(total_amount), 0) as amount
        from public.sales where report_id = v_report.id and voided_at is null) s
  where r.id = v_report.id
  returning r.* into v_report;

  insert into public.report_submissions (company_id, report_id, client_op_id, source, payload,
                                         client_captured_at, client_time_used)
  values (v_company, v_report.id, p_client_op_id, p_source, p_payload, p_client_captured_at, v_client_time_used);

  v_result := jsonb_build_object(
    'report_id', v_report.id,
    'business_date', v_report.business_date,
    'late_sync', v_report.late_sync,
    'state', case when v_report.sales_count > 0 then 'with_sales' else 'zero_sales' end,
    'sales', v_sales,
    'new_customers', v_new_customers,
    'match_reviews', v_reviews,
    'discrepancies', v_discrepancies,
    'missing_counts', v_report.missing_counts);
  return app.finish_op(v_company, p_client_op_id, v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- Commands: sales, discrepancies, customers, targets (managers)
-- ---------------------------------------------------------------------------

create function public.void_sale(p_sale_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_sale public.sales;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception 'validation_failed' using errcode = '22023', detail = 'a reason is required';
  end if;
  select * into v_sale from public.sales where id = p_sale_id and company_id = v_company for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_sale.voided_at is not null then raise exception 'already_voided' using errcode = '22023'; end if;

  update public.sales set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason)
  where id = p_sale_id;
  perform app.move(v_company, v_sale.product_id, v_sale.quantity,
                   app.system_location(v_company, 'customer'), app.agent_location(v_company, v_sale.agent_id),
                   'sale_void', p_reason, v_sale.id, v_sale.report_id, null, auth.uid());
  update public.daily_reports r
  set sales_count = s.cnt, units_sold = s.units, total_amount = s.amount
  from (select count(*) as cnt, coalesce(sum(quantity), 0) as units, coalesce(sum(total_amount), 0) as amount
        from public.sales where report_id = v_sale.report_id and voided_at is null) s
  where r.id = v_sale.report_id;
  perform app.write_audit(v_company, 'sale.voided', 'sale', v_sale.id,
    jsonb_build_object('quantity', v_sale.quantity, 'total_amount', v_sale.total_amount),
    jsonb_build_object('reason', trim(p_reason)));
end;
$$;

-- action: adjust (set the ledger to the counted quantity), write_off (record
-- a shortage as loss), dismiss (no stock change, e.g. counting error).
create function public.resolve_discrepancy(p_id uuid, p_action text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_d public.stock_discrepancies;
  v_loc uuid;
  v_delta int;
  v_movement uuid;
begin
  select * into v_d from public.stock_discrepancies where id = p_id and company_id = v_company for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_d.status <> 'open' then raise exception 'already_resolved' using errcode = '22023'; end if;

  v_loc := app.agent_location(v_company, v_d.agent_id);
  -- Use the difference observed at count time. Sales recorded after the count
  -- moved both the shelf and the ledger, so the gap between them is unchanged.
  v_delta := v_d.reported_qty - v_d.expected_qty;

  if p_action = 'adjust' then
    v_movement := app.move(v_company, v_d.product_id, abs(v_delta),
      case when v_delta > 0 then app.system_location(v_company, 'adjustment') else v_loc end,
      case when v_delta > 0 then v_loc else app.system_location(v_company, 'adjustment') end,
      'adjustment', coalesce(p_note, 'Stock count reconciliation'), null, null, null, auth.uid());
  elsif p_action = 'write_off' then
    if v_delta >= 0 then
      raise exception 'validation_failed' using errcode = '22023', detail = 'only shortages can be written off';
    end if;
    v_movement := app.move(v_company, v_d.product_id, -v_delta, v_loc, app.system_location(v_company, 'write_off'),
      'loss', coalesce(p_note, 'Stock count shortage'), null, null, null, auth.uid());
  elsif p_action <> 'dismiss' then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown action';
  end if;

  update public.stock_discrepancies
  set status = case p_action when 'adjust' then 'resolved' when 'write_off' then 'written_off' else 'dismissed' end,
      resolution_movement_id = v_movement, resolved_by = auth.uid(), resolved_at = now(), note = p_note
  where id = p_id;
  perform app.write_audit(v_company, 'discrepancy.' || p_action, 'stock_discrepancy', p_id,
    jsonb_build_object('expected', v_d.expected_qty, 'reported', v_d.reported_qty),
    jsonb_build_object('movement_id', v_movement, 'note', p_note));
  return jsonb_build_object('movement_id', v_movement);
end;
$$;

-- Manager edit with optimistic concurrency (offline conflict rule: server wins).
create function public.update_customer(
  p_id uuid, p_expected_version int, p_full_name text, p_phone text, p_location text,
  p_notes text, p_consent boolean, p_assigned_agent_id uuid default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_old public.customers;
  v_phone text := case when nullif(trim(p_phone), '') is null then null else app.normalize_phone(p_phone) end;
begin
  select * into v_old from public.customers where id = p_id and company_id = v_company for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_old.version <> p_expected_version then
    raise exception 'conflict' using errcode = '40001', detail = 'customer was changed by someone else';
  end if;
  if v_phone is not null and not coalesce(p_consent, false) then
    raise exception 'validation_failed' using errcode = '22023',
      detail = 'the customer must agree before their phone number is saved';
  end if;
  if p_assigned_agent_id is not null and not exists (
      select 1 from public.memberships where company_id = v_company and user_id = p_assigned_agent_id and role = 'agent') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown agent';
  end if;

  update public.customers
  set full_name = trim(p_full_name), phone_e164 = v_phone, location_text = nullif(trim(p_location), ''),
      notes = nullif(trim(p_notes), ''), consent_given = coalesce(p_consent, false) and v_phone is not null,
      consent_method = case when v_phone is not null and not v_old.consent_given then 'recorded_by_manager'
                            else consent_method end,
      consent_at = case when v_phone is not null and not v_old.consent_given then now() else consent_at end,
      assigned_agent_id = p_assigned_agent_id, version = version + 1
  where id = p_id;
  perform app.write_audit(v_company, 'customer.updated', 'customer', p_id,
    jsonb_build_object('full_name', v_old.full_name, 'phone', v_old.phone_e164),
    jsonb_build_object('full_name', trim(p_full_name), 'phone', v_phone));
  return v_old.version + 1;
end;
$$;

-- Lets an agent recognise a customer by phone without browsing the customer
-- list. Agents get a first name and masked number only; rate-limited.
create function public.find_customer_by_phone(p_phone text)
returns table (customer_id uuid, first_name text, masked_phone text)
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager', 'agent');
  v_phone text := app.normalize_phone(p_phone);
begin
  perform app.consume_rate('phone_lookup', 30, 3600);
  return query
  select c.id, split_part(c.full_name, ' ', 1),
         '0' || substr(c.phone_e164, 5, 2) || ' *** **' || right(c.phone_e164, 2)
  from public.customers c
  where c.company_id = v_company and c.phone_e164 = v_phone and c.merged_into_id is null
  order by c.created_at;
end;
$$;

-- same = true: fold the new record into the existing customer.
create function public.resolve_customer_match(p_review_id uuid, p_same boolean)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_r public.customer_match_reviews;
begin
  select * into v_r from public.customer_match_reviews where id = p_review_id and company_id = v_company for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_r.state <> 'pending' then raise exception 'already_resolved' using errcode = '22023'; end if;

  update public.customer_match_reviews
  set state = case when p_same then 'same' else 'different' end, resolved_by = auth.uid(), resolved_at = now()
  where id = p_review_id;

  if p_same then
    update public.sales set customer_id = v_r.candidate_customer_id where customer_id = v_r.new_customer_id;
    update public.customer_interactions set customer_id = v_r.candidate_customer_id where customer_id = v_r.new_customer_id;
    update public.follow_ups set customer_id = v_r.candidate_customer_id where customer_id = v_r.new_customer_id;
    update public.customers set merged_into_id = v_r.candidate_customer_id, version = version + 1
    where id = v_r.new_customer_id;
    -- Other pending reviews for the merged record no longer apply.
    update public.customer_match_reviews set state = 'different', resolved_by = auth.uid(), resolved_at = now()
    where new_customer_id = v_r.new_customer_id and state = 'pending';
  end if;
  perform app.write_audit(v_company, 'customer.match_' || case when p_same then 'merged' else 'kept_separate' end,
    'customer', v_r.new_customer_id, null, jsonb_build_object('candidate', v_r.candidate_customer_id));
  return case when p_same then v_r.candidate_customer_id else v_r.new_customer_id end;
end;
$$;

-- Sets a daily target from p_effective_from, closing the previous target
-- for the same scope, subject, product and metric.
create function public.set_daily_target(
  p_scope text, p_metric text, p_value numeric, p_effective_from date default null,
  p_agent_id uuid default null, p_team_id uuid default null, p_product_id uuid default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_from date := coalesce(p_effective_from, app.business_date(v_company));
  v_id uuid;
begin
  if p_agent_id is not null and not exists (
      select 1 from public.memberships where company_id = v_company and user_id = p_agent_id and role = 'agent') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'unknown agent';
  end if;
  if p_product_id is not null then perform app.require_product(v_company, p_product_id); end if;

  update public.daily_targets
  set effective_to = v_from - 1
  where company_id = v_company and scope = p_scope and metric = p_metric
    and agent_id is not distinct from p_agent_id and team_id is not distinct from p_team_id
    and product_id is not distinct from p_product_id
    and (effective_to is null or effective_to >= v_from) and effective_from < v_from;
  delete from public.daily_targets
  where company_id = v_company and scope = p_scope and metric = p_metric
    and agent_id is not distinct from p_agent_id and team_id is not distinct from p_team_id
    and product_id is not distinct from p_product_id and effective_from >= v_from;

  insert into public.daily_targets (company_id, scope, team_id, agent_id, product_id, metric, value,
                                    effective_from, created_by)
  values (v_company, p_scope, p_team_id, p_agent_id, p_product_id, p_metric, p_value, v_from, auth.uid())
  returning id into v_id;
  perform app.write_audit(v_company, 'target.set', 'daily_target', v_id, null,
    jsonb_build_object('scope', p_scope, 'agent_id', p_agent_id, 'team_id', p_team_id,
                       'product_id', p_product_id, 'metric', p_metric, 'value', p_value, 'from', v_from));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------

create function app.target_progress(p_company uuid, p_agent uuid, p_date date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'metric', t.metric, 'product_id', t.product_id, 'product_name', p.name, 'scope', t.scope,
    'target', t.value, 'achieved', a.achieved,
    'progress_pct', least(round(a.achieved / t.value * 100), 999),
    'remaining', greatest(t.value - a.achieved, 0)) order by t.metric, p.name nulls first), '[]')
  from app.effective_targets(p_company, p_agent, p_date) t
  left join public.products p on p.id = t.product_id
  cross join lateral (
    select coalesce(sum(case when t.metric = 'units' then s.quantity else s.total_amount end), 0) as achieved
    from public.sales s
    join public.daily_reports r on r.id = s.report_id
    where r.agent_id = p_agent and r.business_date = p_date and s.voided_at is null
      and (t.product_id is null or s.product_id = t.product_id)
  ) a
$$;

create function public.agent_home()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_agent uuid := auth.uid();
  v_date date := app.business_date(v_company);
  v_report public.daily_reports;
begin
  select * into v_report from public.daily_reports
  where company_id = v_company and agent_id = v_agent and business_date = v_date;

  return jsonb_build_object(
    'business_date', v_date,
    'report', jsonb_build_object(
      'state', case when v_report.id is null then 'none'
                    when v_report.sales_count > 0 then 'with_sales' else 'zero_sales' end,
      'last_received_at', v_report.last_received_at,
      'missing_counts', coalesce(v_report.missing_counts, 0)),
    'sales', jsonb_build_object('count', coalesce(v_report.sales_count, 0),
                                'units', coalesce(v_report.units_sold, 0),
                                'amount', coalesce(v_report.total_amount, 0)),
    'targets', app.target_progress(v_company, v_agent, v_date),
    'stock', (select coalesce(jsonb_agg(jsonb_build_object(
                'product_id', p.id, 'name', p.name, 'quantity', b.quantity, 'unit_price', p.unit_price)
                order by p.name), '[]')
              from public.stock_balances b
              join public.stock_locations l on l.id = b.location_id
              join public.products p on p.id = b.product_id
              where l.company_id = v_company and l.agent_id = v_agent and b.quantity <> 0),
    'follow_ups', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', f.id, 'customer_id', c.id, 'customer_name', c.full_name, 'phone', c.phone_e164,
                     'due_date', f.due_date, 'note', f.note) order by f.due_date), '[]')
                   from public.follow_ups f
                   join public.customers c on c.id = f.customer_id
                   where f.agent_id = v_agent and f.company_id = v_company and f.status = 'open'
                     and f.due_date <= v_date + 7));
end;
$$;

create function public.inventory_summary()
returns table (product_id uuid, name text, unit_price numeric, active boolean,
               in_store int, with_agents int, total int)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select p.id, p.name, p.unit_price, p.active,
         coalesce(sum(b.quantity) filter (where l.kind = 'store'), 0)::int,
         coalesce(sum(b.quantity) filter (where l.kind = 'agent'), 0)::int,
         coalesce(sum(b.quantity), 0)::int
  from public.products p
  left join public.stock_balances b on b.product_id = p.id
  left join public.stock_locations l on l.id = b.location_id
  where p.company_id = v_company
  group by p.id
  order by p.active desc, p.name;
end;
$$;

create function public.stock_by_agent()
returns table (agent_id uuid, agent_name text, product_id uuid, product_name text, quantity int)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select l.agent_id, pr.full_name, p.id, p.name, b.quantity
  from public.stock_balances b
  join public.stock_locations l on l.id = b.location_id and l.kind = 'agent'
  join public.products p on p.id = b.product_id
  join public.profiles pr on pr.user_id = l.agent_id
  where l.company_id = v_company and b.quantity <> 0
  order by pr.full_name, p.name;
end;
$$;

create function public.list_movements(p_limit int default 100)
returns table (id uuid, created_at timestamptz, movement_type app.movement_type, product_name text,
               quantity int, from_name text, to_name text, reason text, performed_by_name text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select m.id, m.created_at, m.movement_type, p.name, m.quantity, lf.name, lt.name, m.reason, pr.full_name
  from public.stock_movements m
  join public.products p on p.id = m.product_id
  join public.stock_locations lf on lf.id = m.from_location_id
  join public.stock_locations lt on lt.id = m.to_location_id
  left join public.profiles pr on pr.user_id = m.performed_by
  where m.company_id = v_company
  order by m.created_at desc
  limit least(greatest(p_limit, 1), 500);
end;
$$;

create function public.list_discrepancies(p_status text default 'open')
returns table (id uuid, business_date date, agent_name text, product_name text,
               expected_qty int, reported_qty int, difference int, status text, note text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select d.id, d.business_date, pr.full_name, p.name, d.expected_qty, d.reported_qty, d.difference, d.status, d.note
  from public.stock_discrepancies d
  join public.products p on p.id = d.product_id
  join public.profiles pr on pr.user_id = d.agent_id
  where d.company_id = v_company and (p_status is null or d.status = p_status)
  order by d.business_date desc, pr.full_name;
end;
$$;

create function public.list_sales(p_from date, p_to date)
returns table (id uuid, recorded_at timestamptz, business_date date, agent_name text, product_name text,
               quantity int, unit_price numeric, total_amount numeric, payment_method text,
               customer_name text, price_override boolean, price_flagged boolean, stock_flagged boolean,
               voided_at timestamptz, void_reason text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select s.id, s.recorded_at, r.business_date, pr.full_name, p.name, s.quantity, s.unit_price, s.total_amount,
         s.payment_method, c.full_name, s.price_override, s.price_flagged, s.stock_flagged, s.voided_at, s.void_reason
  from public.sales s
  join public.daily_reports r on r.id = s.report_id
  join public.products p on p.id = s.product_id
  join public.profiles pr on pr.user_id = s.agent_id
  left join public.customers c on c.id = s.customer_id
  where s.company_id = v_company and r.business_date between p_from and p_to
  order by s.recorded_at desc
  limit 500;
end;
$$;

-- Runs as the caller, so RLS decides which customers each role sees.
create function public.list_customers(p_search text default null)
returns table (id uuid, full_name text, phone_e164 text, location_text text, notes text,
               consent_given boolean, version int, assigned_agent_id uuid, created_at timestamptz,
               last_interaction_at timestamptz, open_follow_ups int, next_follow_up date)
language sql stable security invoker set search_path = ''
as $$
  select c.id, c.full_name, c.phone_e164, c.location_text, c.notes, c.consent_given, c.version,
         c.assigned_agent_id, c.created_at,
         (select max(i.created_at) from public.customer_interactions i where i.customer_id = c.id),
         (select count(*)::int from public.follow_ups f where f.customer_id = c.id and f.status = 'open'),
         (select min(f.due_date) from public.follow_ups f where f.customer_id = c.id and f.status = 'open')
  from public.customers c
  where c.merged_into_id is null
    and (nullif(trim(p_search), '') is null
         or c.full_name ilike '%' || trim(p_search) || '%'
         or (regexp_replace(p_search, '\D', '', 'g') <> ''
             and c.phone_e164 like '%' || regexp_replace(p_search, '\D', '', 'g') || '%'))
  order by c.full_name
  limit 300
$$;

create function public.list_match_reviews()
returns table (id uuid, created_at timestamptz, new_customer_id uuid, new_name text, new_created_by text,
               candidate_customer_id uuid, candidate_name text, phone_e164 text)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select r.id, r.created_at, n.id, n.full_name, pr.full_name, c.id, c.full_name, n.phone_e164
  from public.customer_match_reviews r
  join public.customers n on n.id = r.new_customer_id
  join public.customers c on c.id = r.candidate_customer_id
  left join public.profiles pr on pr.user_id = n.created_by
  where r.company_id = v_company and r.state = 'pending'
  order by r.created_at;
end;
$$;

create function public.list_targets()
returns table (id uuid, scope text, agent_id uuid, agent_name text, team_id uuid, team_name text,
               product_id uuid, product_name text, metric text, value numeric, effective_from date)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select t.id, t.scope, t.agent_id, pr.full_name, t.team_id, tm.name, t.product_id, p.name, t.metric, t.value,
         t.effective_from
  from public.daily_targets t
  left join public.profiles pr on pr.user_id = t.agent_id
  left join public.teams tm on tm.id = t.team_id
  left join public.products p on p.id = t.product_id
  where t.company_id = v_company
    and t.effective_from <= app.business_date(v_company) + 365
    and (t.effective_to is null or t.effective_to >= app.business_date(v_company))
  order by case t.scope when 'company' then 0 when 'team' then 1 else 2 end, pr.full_name, p.name, t.metric;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke all on function
  public.save_product, public.record_stock_transfer, public.record_write_off, public.adjust_stock,
  public.submit_report, public.void_sale, public.resolve_discrepancy, public.update_customer,
  public.find_customer_by_phone, public.resolve_customer_match, public.set_daily_target,
  public.agent_home, public.inventory_summary, public.stock_by_agent, public.list_movements,
  public.list_discrepancies, public.list_sales, public.list_customers, public.list_match_reviews,
  public.list_targets
  from public, anon;
grant execute on function
  public.save_product, public.record_stock_transfer, public.record_write_off, public.adjust_stock,
  public.submit_report, public.void_sale, public.resolve_discrepancy, public.update_customer,
  public.find_customer_by_phone, public.resolve_customer_match, public.set_daily_target,
  public.agent_home, public.inventory_summary, public.stock_by_agent, public.list_movements,
  public.list_discrepancies, public.list_sales, public.list_customers, public.list_match_reviews,
  public.list_targets
  to authenticated;

revoke all on function
  app.begin_op, app.finish_op, app.consume_rate, app.business_date, app.system_location, app.agent_location,
  app.balance, app.move, app.require_product, app.require_positive_qty, app.effective_targets,
  app.target_progress, app.apply_movement_to_balances, app.create_system_locations, app.reject_change
  from public, anon, authenticated;
