-- Manager dashboards and reports, conversation transcripts, company settings.
-- All read models are SECURITY DEFINER functions that first require an
-- admin or manager of the caller's company, then filter by that company.

-- ---------------------------------------------------------------------------
-- Overview: one business day at a glance
-- ---------------------------------------------------------------------------

create function public.dashboard_overview(p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_date date := coalesce(p_date, app.business_date(v_company));
  v_tz text := (select timezone from public.companies where id = v_company);
begin
  return jsonb_build_object(
    'date', v_date,
    'today', (select jsonb_build_object(
                'sales_count', coalesce(sum(r.sales_count), 0),
                'units', coalesce(sum(r.units_sold), 0),
                'amount', coalesce(sum(r.total_amount), 0))
              from public.daily_reports r where r.company_id = v_company and r.business_date = v_date),
    'week', (select jsonb_build_object(
               'sales_count', coalesce(sum(r.sales_count), 0),
               'units', coalesce(sum(r.units_sold), 0),
               'amount', coalesce(sum(r.total_amount), 0))
             from public.daily_reports r
             where r.company_id = v_company and r.business_date between v_date - 6 and v_date),
    'week_by_day', (select jsonb_agg(jsonb_build_object('date', d::date, 'amount', coalesce(x.amount, 0),
                                                        'units', coalesce(x.units, 0)) order by d)
                    from generate_series(v_date - 6, v_date, interval '1 day') d
                    left join (select business_date, sum(total_amount) as amount, sum(units_sold) as units
                               from public.daily_reports where company_id = v_company
                               group by business_date) x on x.business_date = d::date),
    -- Every active agent with today's report state: none / zero_sales / with_sales.
    'agents', (select coalesce(jsonb_agg(a order by a ->> 'state' = 'none' desc, a ->> 'name'), '[]')
               from (select jsonb_build_object(
                       'agent_id', m.user_id,
                       'name', p.full_name,
                       'state', case when r.id is null then 'none'
                                     when r.sales_count > 0 then 'with_sales' else 'zero_sales' end,
                       'last_report_at', r.last_received_at,
                       'last_report_any', (select max(x.last_received_at) from public.daily_reports x
                                           where x.company_id = v_company and x.agent_id = m.user_id),
                       'sales_count', coalesce(r.sales_count, 0),
                       'units', coalesce(r.units_sold, 0),
                       'amount', coalesce(r.total_amount, 0),
                       'missing_counts', coalesce(r.missing_counts, 0),
                       'targets', app.target_progress(v_company, m.user_id, v_date)) as a
                     from public.memberships m
                     join public.profiles p on p.user_id = m.user_id
                     left join public.daily_reports r
                       on r.company_id = v_company and r.agent_id = m.user_id and r.business_date = v_date
                     where m.company_id = v_company and m.role = 'agent' and m.status = 'active') s),
    'customers', jsonb_build_object(
      'new_today', (select count(*) from public.customers c where c.company_id = v_company and c.merged_into_id is null
                    and (c.created_at at time zone v_tz)::date = v_date),
      'new_week', (select count(*) from public.customers c where c.company_id = v_company and c.merged_into_id is null
                   and (c.created_at at time zone v_tz)::date between v_date - 6 and v_date),
      'follow_ups_due', (select count(*) from public.follow_ups f
                         where f.company_id = v_company and f.status = 'open' and f.due_date <= v_date)),
    'attention', jsonb_build_object(
      'open_discrepancies', (select count(*) from public.stock_discrepancies d
                             where d.company_id = v_company and d.status = 'open'),
      'duplicate_reviews', (select count(*) from public.customer_match_reviews m
                            where m.company_id = v_company and m.state = 'pending'),
      'flagged_sales_today', (select count(*) from public.sales s join public.daily_reports r on r.id = s.report_id
                              where s.company_id = v_company and r.business_date = v_date and s.voided_at is null
                                and (s.price_flagged or s.stock_flagged))),
    'stock', (select jsonb_build_object(
                'in_store', coalesce(sum(b.quantity) filter (where l.kind = 'store'), 0),
                'with_agents', coalesce(sum(b.quantity) filter (where l.kind = 'agent'), 0))
              from public.stock_balances b join public.stock_locations l on l.id = b.location_id
              where b.company_id = v_company)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Sales report over a date range, with optional agent / product filters
-- ---------------------------------------------------------------------------

create function public.sales_report(
  p_from date, p_to date, p_agent_ids uuid[] default null, p_product_ids uuid[] default null
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
  v_tz text := (select timezone from public.companies where id = v_company);
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'validation_failed' using errcode = '22023', detail = 'choose a valid date range';
  end if;
  if p_to - p_from > 366 then
    raise exception 'validation_failed' using errcode = '22023', detail = 'the range can be at most a year';
  end if;

  return (
    with s as (
      select s.*, r.business_date
      from public.sales s
      join public.daily_reports r on r.id = s.report_id
      where s.company_id = v_company and s.voided_at is null
        and r.business_date between p_from and p_to
        and (p_agent_ids is null or s.agent_id = any (p_agent_ids))
        and (p_product_ids is null or s.product_id = any (p_product_ids))
    ),
    agents as (
      select m.user_id, p.full_name
      from public.memberships m join public.profiles p on p.user_id = m.user_id
      where m.company_id = v_company and m.role = 'agent'
        and (p_agent_ids is null or m.user_id = any (p_agent_ids))
        and (m.status = 'active' or exists (select 1 from s where s.agent_id = m.user_id))
    )
    select jsonb_build_object(
      'from', p_from, 'to', p_to, 'days', p_to - p_from + 1,
      'totals', (select jsonb_build_object('sales_count', count(*), 'units', coalesce(sum(quantity), 0),
                                           'amount', coalesce(sum(total_amount), 0)) from s),
      'by_day', (select jsonb_agg(jsonb_build_object('date', d::date, 'sales_count', coalesce(x.n, 0),
                                                     'units', coalesce(x.units, 0), 'amount', coalesce(x.amount, 0))
                                  order by d)
                 from generate_series(p_from, p_to, interval '1 day') d
                 left join (select business_date, count(*) as n, sum(quantity) as units, sum(total_amount) as amount
                            from s group by business_date) x on x.business_date = d::date),
      'by_product', (select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name,
                                                                  'units', x.units, 'amount', x.amount)
                                               order by x.amount desc, p.name), '[]')
                     from (select product_id, sum(quantity) as units, sum(total_amount) as amount
                           from s group by product_id) x
                     join public.products p on p.id = x.product_id),
      -- Activity counts reports regardless of the product filter: a report
      -- with zero sales is still a report.
      'by_agent', (select coalesce(jsonb_agg(jsonb_build_object(
                     'agent_id', a.user_id, 'name', a.full_name,
                     'sales_count', coalesce(x.n, 0), 'units', coalesce(x.units, 0), 'amount', coalesce(x.amount, 0),
                     'days_reported', coalesce(r.days, 0), 'zero_sale_days', coalesce(r.zero_days, 0),
                     'last_report_at', r.last_at)
                     order by coalesce(x.amount, 0) desc, a.full_name), '[]')
                   from agents a
                   left join (select agent_id, count(*) as n, sum(quantity) as units, sum(total_amount) as amount
                              from s group by agent_id) x on x.agent_id = a.user_id
                   left join (select agent_id, count(*) as days, count(*) filter (where sales_count = 0) as zero_days,
                                     max(last_received_at) as last_at
                              from public.daily_reports
                              where company_id = v_company and business_date between p_from and p_to
                              group by agent_id) r on r.agent_id = a.user_id),
      'customers_by_day', (select jsonb_agg(jsonb_build_object('date', d::date, 'count', coalesce(x.n, 0)) order by d)
                           from generate_series(p_from, p_to, interval '1 day') d
                           left join (select (c.created_at at time zone v_tz)::date as day, count(*) as n
                                      from public.customers c
                                      where c.company_id = v_company and c.merged_into_id is null
                                        and (p_agent_ids is null or c.created_by = any (p_agent_ids))
                                      group by 1) x on x.day = d::date)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Conversation transcripts (supervision and translation checks)
-- ---------------------------------------------------------------------------

create function public.list_conversations(p_from date, p_to date, p_agent uuid default null)
returns table (session_id uuid, business_date date, agent_name text, channel text, language text, status text,
               turns int, started_at timestamptz, last_turn_at timestamptz, report_id uuid)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  return query
  select s.id, s.business_date, p.full_name, s.channel, s.language, s.status,
         (select count(*)::int from public.conversation_turns t where t.session_id = s.id),
         s.started_at, s.last_turn_at, s.report_id
  from public.report_sessions s
  join public.profiles p on p.user_id = s.agent_id
  where s.company_id = v_company and s.business_date between p_from and p_to
    and (p_agent is null or s.agent_id = p_agent)
  order by s.last_turn_at desc
  limit 300;
end;
$$;

create function public.conversation_transcript(p_session uuid)
returns table (role text, text text, english_text text, language text, input_mode text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin', 'manager');
begin
  if not exists (select 1 from public.report_sessions where id = p_session and company_id = v_company) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  return query
  select t.role, t.text, t.english_text, t.language, t.input_mode, t.created_at
  from public.conversation_turns t
  where t.session_id = p_session
  order by t.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Company settings (admins). Only known keys, each validated.
-- ---------------------------------------------------------------------------

create function public.company_settings()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'twi_voice_enabled', coalesce((c.settings ->> 'twi_voice_enabled')::boolean, false),
    'khaya_monthly_calls', coalesce((c.settings ->> 'khaya_monthly_calls')::int, 100),
    'max_discount_pct', coalesce((c.settings ->> 'max_discount_pct')::numeric, 20),
    'khaya_calls_used_this_month', coalesce((select r.count from public.rate_limits r
                                             where r.user_id = c.id and r.bucket = 'khaya'
                                               and r.window_start = date_trunc('month', now())), 0))
  from public.companies c
  where c.id = app.require_role('admin', 'manager')
$$;

create function public.update_company_settings(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('admin');
  v_key text;
  v_before jsonb;
begin
  if jsonb_typeof(p_patch) <> 'object' then
    raise exception 'validation_failed' using errcode = '22023', detail = 'settings must be an object';
  end if;
  for v_key in select jsonb_object_keys(p_patch) loop
    case v_key
      when 'twi_voice_enabled' then
        if jsonb_typeof(p_patch -> v_key) <> 'boolean' then
          raise exception 'validation_failed' using errcode = '22023', detail = 'twi_voice_enabled must be true or false';
        end if;
      when 'khaya_monthly_calls' then
        if jsonb_typeof(p_patch -> v_key) <> 'number' or (p_patch ->> v_key)::numeric not between 0 and 1000000
           or (p_patch ->> v_key)::numeric <> trunc((p_patch ->> v_key)::numeric) then
          raise exception 'validation_failed' using errcode = '22023', detail = 'the Twi allowance must be a whole number from 0';
        end if;
      when 'max_discount_pct' then
        if jsonb_typeof(p_patch -> v_key) <> 'number' or (p_patch ->> v_key)::numeric not between 0 and 100 then
          raise exception 'validation_failed' using errcode = '22023', detail = 'the discount limit must be between 0 and 100';
        end if;
      else
        raise exception 'validation_failed' using errcode = '22023', detail = 'unknown setting ' || v_key;
    end case;
  end loop;

  select settings into v_before from public.companies where id = v_company for update;
  update public.companies set settings = settings || p_patch where id = v_company;
  perform app.write_audit(v_company, 'company.settings_updated', 'company', v_company, v_before, p_patch);
  return public.company_settings();
end;
$$;

revoke all on function public.dashboard_overview, public.sales_report, public.list_conversations,
  public.conversation_transcript, public.company_settings, public.update_company_settings from public, anon;
grant execute on function public.dashboard_overview, public.sales_report, public.list_conversations,
  public.conversation_transcript, public.company_settings, public.update_company_settings to authenticated;
