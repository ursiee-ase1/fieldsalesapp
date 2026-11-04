-- Conversational reporting assistant: sessions, turns, context and quotas.
--
-- The assistant Edge Function calls these as the signed-in agent, so the
-- same tenant and role rules apply as for the form. The LLM never writes
-- here directly: the function stores a validated draft, and the final
-- report still goes through public.submit_report.

create table public.report_sessions (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies (id) on delete cascade,
  agent_id            uuid not null references auth.users (id),
  business_date       date not null,
  channel             text not null check (channel in ('app_text', 'app_voice', 'phone', 'whatsapp')),
  language            text not null default 'en' check (language in ('en', 'tw')),
  status              text not null default 'active'
                        check (status in ('active', 'awaiting_confirmation', 'submitted', 'abandoned')),
  draft               jsonb not null default '{}'::jsonb,
  draft_version       int not null default 0,
  context             jsonb not null default '{}'::jsonb,
  client_op_id        uuid not null default gen_random_uuid(), -- makes the final submit idempotent
  report_id           uuid,
  started_at          timestamptz not null default now(),
  last_turn_at        timestamptz not null default now(),
  unique (company_id, id)
);

-- At most one open session per agent per day, so "resume" is unambiguous.
create unique index report_sessions_one_open on public.report_sessions (agent_id, business_date)
  where status in ('active', 'awaiting_confirmation');

create table public.conversation_turns (
  id                    bigint generated always as identity primary key,
  company_id            uuid not null references public.companies (id) on delete cascade,
  session_id            uuid not null,
  role                  text not null check (role in ('agent', 'assistant')),
  text                  text not null,          -- what was said, in the language used
  english_text          text,                   -- translation used by the engine, when different
  language              text not null default 'en',
  input_mode            text check (input_mode in ('text', 'voice')),
  stt_provider          text,
  translation_provider  text,
  llm_provider          text,
  tokens_in             int,
  tokens_out            int,
  latency_ms            int,
  meta                  jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  foreign key (company_id, session_id) references public.report_sessions (company_id, id) on delete cascade
);

create index conversation_turns_session on public.conversation_turns (session_id, id);

alter table public.report_sessions enable row level security;
alter table public.conversation_turns enable row level security;
revoke all on public.report_sessions, public.conversation_turns from anon, authenticated;
grant select on public.report_sessions, public.conversation_turns to authenticated;

create policy sessions_read on public.report_sessions for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or agent_id = (select auth.uid())));

create policy turns_read on public.conversation_turns for select to authenticated
  using (company_id = (select app.current_company_id())
         and ((select app.is_manager()) or exists (
           select 1 from public.report_sessions s
           where s.id = conversation_turns.session_id and s.agent_id = (select auth.uid()))));

-- ---------------------------------------------------------------------------
-- Context: what the assistant may know about this agent today
-- ---------------------------------------------------------------------------

create function app.assistant_context(p_company uuid, p_agent uuid, p_date date)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'today', p_date,
    'weekday', trim(to_char(p_date, 'Day')),
    'agent_first_name', split_part(coalesce((select full_name from public.profiles where user_id = p_agent), ''), ' ', 1),
    'report_state', coalesce((
      select case when r.sales_count > 0 then 'with_sales' else 'zero_sales' end
      from public.daily_reports r
      where r.company_id = p_company and r.agent_id = p_agent and r.business_date = p_date), 'none'),
    'twi_voice_enabled', coalesce((select (settings ->> 'twi_voice_enabled')::boolean
                                   from public.companies where id = p_company), false),
    'products', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', p.id, 'name', p.name, 'aliases', p.aliases, 'unit_price', p.unit_price) order by p.name), '[]')
                 from public.products p where p.company_id = p_company and p.active),
    -- Stock the agent holds, with their most recent earlier count for context
    -- ("Yesterday you reported having five copies of Book A...").
    'held', (select coalesce(jsonb_agg(jsonb_build_object(
               'product_id', p.id, 'name', p.name, 'quantity', b.quantity,
               'last_count', (select jsonb_build_object('date', c.business_date, 'quantity', c.reported_qty)
                              from public.stock_counts c
                              where c.agent_id = p_agent and c.product_id = p.id and c.business_date < p_date
                              order by c.business_date desc limit 1)) order by p.name), '[]')
             from public.stock_balances b
             join public.stock_locations l on l.id = b.location_id
             join public.products p on p.id = b.product_id
             where l.company_id = p_company and l.agent_id = p_agent and b.quantity <> 0),
    'follow_ups_due', (select coalesce(jsonb_agg(jsonb_build_object(
                         'id', f.id, 'customer_name', c.full_name, 'due_date', f.due_date, 'note', f.note)
                         order by f.due_date), '[]')
                       from public.follow_ups f
                       join public.customers c on c.id = f.customer_id
                       where f.agent_id = p_agent and f.company_id = p_company
                         and f.status = 'open' and f.due_date <= p_date)
  )
$$;

-- Opens today's session, or resumes the open one. Returns the session and
-- its recent turns.
create function public.assistant_start(p_channel text, p_language text default 'en')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_agent uuid := auth.uid();
  v_date date := app.business_date(v_company);
  v_session public.report_sessions;
  v_resumed boolean := true;
begin
  perform app.consume_rate('assistant_start', 30, 3600);

  select * into v_session from public.report_sessions
  where agent_id = v_agent and business_date = v_date and status in ('active', 'awaiting_confirmation')
  for update;

  if not found then
    v_resumed := false;
    insert into public.report_sessions (company_id, agent_id, business_date, channel, language, context)
    values (v_company, v_agent, v_date, p_channel, coalesce(p_language, 'en'),
            app.assistant_context(v_company, v_agent, v_date))
    returning * into v_session;
  else
    -- Refresh context (stock or follow-ups may have changed) but keep the draft.
    update public.report_sessions
    set context = app.assistant_context(v_company, v_agent, v_date),
        channel = p_channel, language = coalesce(p_language, language)
    where id = v_session.id
    returning * into v_session;
  end if;

  return jsonb_build_object(
    'resumed', v_resumed,
    'session', to_jsonb(v_session),
    'turns', (select coalesce(jsonb_agg(jsonb_build_object('role', t.role, 'text', t.text) order by t.id), '[]')
              from (select * from public.conversation_turns where session_id = v_session.id
                    order by id desc limit 40) t));
end;
$$;

-- Loads a session for a new turn: checks ownership and the turn rate limit.
create function public.assistant_load(p_session uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_session public.report_sessions;
begin
  perform app.consume_rate('assistant_turn', 150, 3600);
  select * into v_session from public.report_sessions
  where id = p_session and company_id = v_company and agent_id = auth.uid();
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_session.status not in ('active', 'awaiting_confirmation') then
    raise exception 'session_closed' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'session', to_jsonb(v_session),
    'recent_turns', (select coalesce(jsonb_agg(jsonb_build_object('role', t.role, 'text', coalesce(t.english_text, t.text))
                                               order by t.id), '[]')
                     from (select * from public.conversation_turns where session_id = p_session
                           order by id desc limit 8) t));
end;
$$;

-- Saves the validated draft (optimistic concurrency on draft_version) and
-- appends the turns. p_turns: [{role, text, english_text, language, ...}]
create function public.assistant_save(
  p_session uuid, p_expected_version int, p_draft jsonb, p_status text, p_turns jsonb
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_version int;
  v_turn jsonb;
begin
  if p_status not in ('active', 'awaiting_confirmation', 'abandoned') then
    raise exception 'validation_failed' using errcode = '22023', detail = 'invalid status';
  end if;
  update public.report_sessions
  set draft = p_draft, status = p_status, draft_version = draft_version + 1, last_turn_at = now()
  where id = p_session and company_id = v_company and agent_id = auth.uid()
    and draft_version = p_expected_version and status in ('active', 'awaiting_confirmation')
  returning draft_version into v_version;
  if v_version is null then
    raise exception 'conflict' using errcode = '40001', detail = 'the conversation changed; reload it';
  end if;

  for v_turn in select * from jsonb_array_elements(coalesce(p_turns, '[]')) loop
    insert into public.conversation_turns (company_id, session_id, role, text, english_text, language, input_mode,
      stt_provider, translation_provider, llm_provider, tokens_in, tokens_out, latency_ms, meta)
    values (v_company, p_session, v_turn ->> 'role', v_turn ->> 'text', v_turn ->> 'english_text',
      coalesce(v_turn ->> 'language', 'en'), v_turn ->> 'input_mode', v_turn ->> 'stt_provider',
      v_turn ->> 'translation_provider', v_turn ->> 'llm_provider', (v_turn ->> 'tokens_in')::int,
      (v_turn ->> 'tokens_out')::int, (v_turn ->> 'latency_ms')::int, coalesce(v_turn -> 'meta', '{}'));
  end loop;
  return v_version;
end;
$$;

create function public.assistant_mark_submitted(p_session uuid, p_report_id uuid)
returns void
language sql security definer set search_path = ''
as $$
  update public.report_sessions
  set status = 'submitted', report_id = p_report_id, last_turn_at = now()
  where id = p_session and agent_id = auth.uid() and company_id = app.require_role('agent')
$$;

-- Monthly per-company cap on Khaya calls (settings.khaya_monthly_calls,
-- default 100 to match the free developer plan).
create function public.consume_khaya_quota(p_calls int default 1)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_company uuid := app.require_role('agent');
  v_max int;
  v_used int;
begin
  select coalesce((settings ->> 'khaya_monthly_calls')::int, 100) into v_max
  from public.companies where id = v_company;
  insert into public.rate_limits (user_id, bucket, window_start, count)
  values (v_company, 'khaya', date_trunc('month', now()), p_calls)
  on conflict (user_id, bucket, window_start) do update set count = public.rate_limits.count + p_calls
  returning count into v_used;
  if v_used > v_max then
    raise exception 'quota_exceeded' using errcode = 'P0001', detail = 'Twi language service limit reached for this month';
  end if;
  return v_max - v_used;
end;
$$;

-- Lets agents choose their assistant language (en / tw) themselves.
-- (update_my_profile already exists; this only documents intended use.)

revoke all on function public.assistant_start, public.assistant_load, public.assistant_save,
  public.assistant_mark_submitted, public.consume_khaya_quota from public, anon;
grant execute on function public.assistant_start, public.assistant_load, public.assistant_save,
  public.assistant_mark_submitted, public.consume_khaya_quota to authenticated;
revoke all on function app.assistant_context from public, anon, authenticated;
