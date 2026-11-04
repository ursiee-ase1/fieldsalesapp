# Phase 1 — Product & Technical Plan

**Product:** AI-powered field sales & operations platform (multi-tenant SaaS, Ghana first)
**Status:** Decisions D1–D12 answered (2026-11-04). Translation-first Twi design added (§4.5). No application code written yet
**Date:** 2026-11-04

---

## 0. Recommendations at a glance

| Area | Recommendation | Why |
|---|---|---|
| Client | One Flutter app (Android, iOS, web). Riverpod, go_router, drift (SQLite) | One codebase. drift gives a typed local DB that also runs on web |
| Backend | **Supabase**: Postgres, Auth, RLS, Storage, Edge Functions, pg_cron | Relational data fits the ledger and reports. RLS enforces tenant isolation in the database. Cheap to start. It is plain Postgres, so we can leave later |
| Business writes | Transactional **Postgres functions (RPC)**. AI and secret-bearing calls go through **Edge Functions** | Rules live next to the data, run in one transaction, and are idempotent |
| Conversation engine | One server-side engine. Text and voice are only different I/O adapters around it | Required: a single engine, one set of rules, one data model |
| Voice architecture | **STT → engine → TTS pipeline**, turn-based. Not a realtime speech-to-speech API | Lets us swap STT/TTS per language (needed for Twi), keeps extraction deterministic, and costs less |
| LLM | Provider abstraction. Start-candidates: **Claude Haiku 5.5** and **Gemini 3.1 Flash-Lite**. Escalate to Claude Sonnet 5.5 for hard turns. Final pick after a Twi/English eval | Lowest verified prices with structured output. Neither has been proven on Twi, so we test first |
| English speech | Commodity STT/TTS (Google Chirp 3 / Deepgram / ElevenLabs), chosen by bake-off | Mature options, roughly $0.004–$0.016 per minute STT |
| Twi speech | **Khaya** (GhanaNLP) for Twi STT, TTS and translation; **Abena AI** as second candidate. Both behind adapters, chosen by testing. Text is the guaranteed path | Google STT, Google TTS, Azure Speech and ElevenLabs STT do **not** list Twi/Akan (checked on their docs 2026-11-04) |
| Twi language handling | **Translation layer:** Twi input is translated to English before the LLM; English replies are translated to Twi. The LLM only works in English. Numbers, names and phones are protected from translation (§4.5) | Your choice. It lets the LLM work in the language it is strongest in, and keeps Twi quality in a swappable, Ghana-specialised provider |
| Offline | Local drift DB, an outbox of idempotent commands, a structured offline report form | Agents in low-connectivity areas can always file a report |

**Biggest risk:** Twi voice quality. Research shows fine-tuned Akan ASR at roughly 30–40% word error rate, and zero-shot models fail badly (§4.3). So the MVP must make **text a first-class equal to voice**, and voice in Twi ships only after it passes testing with real speakers.

---

## 1. Requirements analysis — what actually drives the design

1. **The reporting engine is the product.** Everything else (sales, stock, customers, targets) is data the engine must collect correctly. The engine is the main design focus.
2. **Never let the LLM write data.** The LLM proposes *operations on a draft*. Deterministic code validates them. The agent confirms a summary rendered by the backend (not by the LLM). A transactional function then commits.
3. **Inventory is a ledger, not a number.** All balances are derived from append-only movements. A reported closing count is an *observation* that is compared against the ledger. It never overwrites it.
4. **Three report states must be distinguishable:** no report, zero-sales report, report with sales. This needs a `daily_reports` row per agent per business day. A missing row means "no report".
5. **Offline vs "trusted server time" conflict.** Timestamps must come from the server, but an offline report may sync a day later. Proposed rule (decision D5): the server records `received_at`. `business_date` is the server date unless the device-captured time is within a configured window (default 72h) and passes a clock-skew check. Late syncs are flagged for managers. The client time is stored as untrusted metadata only.
6. **Stock availability vs reality.** If an agent says they sold 3 but the ledger shows 2, rejecting the sale loses the truth. In conversation the AI asks the agent to re-check. If they confirm, or the report arrives via offline sync, the sale is **accepted and flagged** as a discrepancy. It is never silently dropped and never silently adjusted.
7. **The customer phone number is the identity key, but not unique.** Shared family phones are common. So the system detects possible matches, the agent or manager confirms, and nothing auto-merges.
8. **Agents need to recognise a customer without browsing the whole customer list.** A guarded lookup returns only a first name and a masked number when the phone matches. Lookups are rate-limited to stop enumeration.

---

## 2. Decisions

D1–D5 answered by the product owner on 2026-11-04. D6–D12 use the defaults below unless changed.

| # | Decision | Outcome |
|---|---|---|
| D1 | Which Akan varieties count as "Twi"? | **Decided:** Asante + Akuapem Twi. Fante later |
| D2 | Payment methods to support | **Decided:** Cash and Mobile Money only. Assumption: sales are paid in full at the time of sale, so there is no credit or partial-payment tracking in the MVP. The schema keeps a `payment_status` column so credit can be added later |
| D3 | Can agents sell below the catalog price? | **Decided:** Yes. The catalog price is the default; the agent may state a different price. Overrides more than X% off (company setting) are flagged for managers |
| D4 | Which customers can an agent see? | **Decided:** Customers the agent created, has interacted with, or is assigned to. Everything else only via the masked phone lookup |
| D5 | Business-date rule for late offline syncs | **Decided:** As in §1.5 (72h window, flagged) |
| D6 | Stock locations | One company store plus one holding per agent. Multiple warehouses supported by the schema, but no UI for them in MVP |
| D7 | Company onboarding | Self-serve signup creates company + admin. You can disable this and onboard companies manually |
| D8 | Agent login | Admin creates agent accounts. Agent logs in with **phone number + password**. Avoids SMS OTP cost and dependence. SMS OTP optional later |
| D9 | Teams in MVP | Minimal `teams` table so targets can be set by team. No team-lead role yet |
| D10 | SaaS billing of tenants | Out of MVP scope. Schema has a `plan` field on companies |
| D11 | Data protection | Ghana Data Protection Act, 2012 (Act 843) applies. Hosting region and cross-border transfer need legal review before real customer data. Supabase region chosen by measured latency from Ghana |
| D12 | Twi testing budget | You recruit ~12–20 paid testers (see §12). I provide the test kit and the scoring tooling |

---

## 3. Backend comparison

| Criterion | **Supabase** (recommended) | Firebase | Custom (e.g. NestJS/Go + managed Postgres) |
|---|---|---|---|
| Data model | Postgres: relational, joins, constraints, transactions | Firestore: document store. Ledger sums, joins and reporting are awkward and cost a read per document | Postgres. Full control |
| Tenant isolation | Row-Level Security inside the DB. Defence in depth even if an API bug occurs | Security Rules. Workable, but weaker for relational checks | You implement it in app code (and can add RLS) |
| Auth | Built in: email, phone, password. Custom JWT claims via auth hook | Built in, excellent | Build it or buy it (Auth0/Clerk) |
| Server logic | Postgres functions + Edge Functions (Deno/TypeScript) | Cloud Functions | Anything |
| Background jobs | pg_cron + Edge Functions | Scheduled functions | Queue + workers (more ops) |
| Realtime | Postgres changes / broadcast | Excellent | Build it (websockets) |
| Offline sync | Not built in. We build an outbox (needed anyway for idempotent commands) | Firestore offline cache built in, but its last-write-wins model is unsafe for stock | Build it |
| Cost to start | Free tier for dev. Pro **$25/month** incl. $10 compute credit (third-party sources; verify on supabase.com/pricing) | Pay-per-read/write. Hard to predict for dashboards | VM + DB ≈ similar or more, plus your ops time |
| Lock-in | Low: standard Postgres, SQL migrations | High | None |

**Verdict:** Supabase. Firebase's built-in offline sync is tempting, but last-write-wins documents are the wrong primitive for an inventory ledger. A custom backend adds ops burden a small team doesn't need yet. If we outgrow Edge Functions (long-lived voice streams, heavy workers), we add one small container service (e.g. Cloud Run or Fly.io) next to Supabase without migrating the data.

---

## 4. AI providers

### 4.1 LLM (understanding, extraction, response phrasing)

Prices are USD per 1M tokens (input / output), standard tier.

| Model | Price | Source / confidence | Notes |
|---|---|---|---|
| Claude Haiku 5.5 | $0.10 / $0.50 (prompts ≤100K tokens) | Anthropic model reference, cached 2026-10-06 | Structured outputs + strict tool schemas. Cheapest verified option |
| Claude Sonnet 5.5 | $2 / $10 | Same | Escalation model for ambiguous or long turns |
| Gemini 3.1 Flash-Lite | $0.25 / $1.50 (audio input $0.50) | Google AI Studio pricing page, read 2026-11-04 | Accepts audio directly, which could be a Twi path to test (§4.3) |
| Gemini 3.6 Flash | $0.75 / $3.75 until 2026-12-31, then $1.50 / $7.50 | Same | Mid tier |
| OpenAI mini models | Text ≈ $0.60 / $2.40 (GPT Realtime mini) | Aggregators only, **not verified** on OpenAI's site | Kept as a third adapter option |

**No LLM vendor documents Twi quality.** Google Cloud Translation lists Twi (`ak`) for text translation, which suggests Google has Twi text data. That is weak evidence for Gemini, not proof. With the translation layer (§4.5), the LLM only handles English. Its inputs will include machine-translated Twi, which is often awkward or partly wrong. Decision: in Phase 4 week 1, run an **extraction eval** (≈150 scripted transcripts, scored on slot accuracy) across Haiku 5.5, Gemini 3.1 Flash-Lite and Sonnet 5.5, then pick. The transcripts mix native English, code-switched speech and *Khaya/Abena translations of Twi*.

**Cost per report (LLM only).** Assumptions: ~10 turns, 2 calls per turn (extract + reply), ~3K input tokens and ~150 output tokens per call (before prompt caching, which lowers input cost):

| Model | Per report | 100 agents × 22 reports/month |
|---|---|---|
| Claude Haiku 5.5 | ≈ $0.0075 | ≈ $17 |
| Gemini 3.1 Flash-Lite | ≈ $0.024 | ≈ $53 |
| Claude Sonnet 5.5 | ≈ $0.15 | ≈ $330 |

These are estimates. Thinking tokens, retries and longer conversations raise them. We will measure real token usage per report in Phase 4.

### 4.2 Realtime speech-to-speech vs pipeline

| | Realtime API (OpenAI Realtime, Gemini Live) | **STT → LLM → TTS pipeline** (recommended) |
|---|---|---|
| Latency | Best (sub-second possible) | ~2–4 s per turn target. Must measure |
| Barge-in | Built in | Client-side: tap to interrupt (reliable). Voice barge-in as an enhancement |
| Twi | No documented Twi support | Can plug in Twi-specialised STT/TTS per language |
| Structured extraction control | Harder: the model talks and extracts at once | Every turn goes through our validator |
| Provider swap | Locked to one vendor's audio stack | Each stage swappable |
| Cost (indicative) | gpt-realtime-2.1-mini audio ≈ $10 in / $20 out per 1M audio tokens (aggregator figures, unverified) | STT ≈ $0.004–$0.016/min + cheap LLM + TTS |

**Decision:** pipeline. The engine is designed so a realtime adapter could be added later for English only, without changing the engine.

### 4.3 Speech-to-text and text-to-speech, with Twi evidence

Checked on the vendors' own docs on 2026-11-04:

| Provider | Twi / Akan STT | Twi / Akan TTS | English | Indicative STT price |
|---|---|---|---|---|
| Google Cloud STT (Chirp 3) | **Not listed** | **Not listed** (Google TTS) | Yes | ~$0.016/min standard, cheaper batch (third-party; verify) |
| Azure AI Speech | **Not listed** | **Not listed** | Yes | Not checked |
| ElevenLabs Scribe v2 | **Not listed** (90+ language list) | Not checked | Yes | ~$0.22–0.39/hour (third-party; verify) |
| Deepgram Nova-3 | Not checked; assume no | — | Yes | ~$0.0048/min streaming (third-party; verify) |
| **GhanaNLP Khaya API** (chosen) | **Yes** (SDK lists `tw` for ASR) | **Yes** (`tw` TTS) | Partial | **Pricing not published.** Contact required. Also offers translation |
| **Abena AI** (chosen, 2nd) | To confirm | Lists Twi (Akan) voices in its playground | To confirm | **No public API docs found.** API access, pricing and terms to confirm with the vendor |
| Open models (Hugging Face) | Fine-tuned Whisper/MMS variants | Simba-TTS (MMS arch, Asante/Akuapem), nano-twi (MIT, CPU), stable-twi-tts (**cc-by-nc, non-commercial — not usable**) | — | Self-hosting cost only. **Check each licence** |
| Gemini native audio | Untested for Twi | — | Yes | $0.50/1M audio tokens (3.1 Flash-Lite) |

Published Akan ASR research: fine-tuned models reach roughly **30–40% WER** on curated speech. Zero-shot MMS-1B was ~99% WER. Out-of-domain Whisper sometimes produced fluent but wrong text or >100% WER (WAXAL-NET 2026; Mensah et al. 2025). Fluent-but-wrong output is the most dangerous failure for sales quantities.

**Plan for Twi voice:**
1. MVP ships **Twi text** (typed Twi or code-switched, via the translation layer in §4.5) through the same engine, plus **English voice**. Khaya and Abena AI are tested head to head for Twi STT, TTS and translation.
2. **Twi voice** sits behind feature flags per company. It turns on only after it passes the §12 tests.
3. Every number, name and phone number is **read back and confirmed**, and shown on screen, whatever the language.
4. If STT confidence is low, or the agent says "that's wrong" twice, the UI offers the keyboard. The conversation keeps its state.
5. The speech interface is `SpeechToText.transcribe(audio, languageHint) → {text, confidence, detectedLanguage}` and `TextToSpeech.synthesize(text, language, voice)`. Adapters are configured per company and language, with no app rebuild.

### 4.4 Indicative monthly cost: 100 agents, 22 reports per agent per month

| Item | Estimate | Basis |
|---|---|---|
| Supabase Pro + small compute | $25–$60 | Third-party pricing summaries |
| LLM (Haiku 5.5) | ~$17 | §4.1 |
| English STT, 2.5 min agent speech per report, all reports by voice | $27–$88 | $0.005–$0.016/min |
| TTS | **Unknown.** Need verified prices | Collect in Phase 4 bake-off |
| Twi speech (Khaya / self-host) | **Unknown** | Pricing not published |
| **Total, excluding TTS and Twi speech** | **≈ $70–$170 / month** | ≈ $0.70–$1.70 per agent per month |

Treat these as order-of-magnitude figures. Every price marked "third-party" must be confirmed on the vendor's pricing page before budgeting. Twi translation calls (§4.5) add a cost per Twi turn that is unknown until Khaya and Abena AI share pricing.

### 4.5 Translation layer for Twi

**Decision:** for Twi, the LLM never reads or writes Twi. A translation step sits on each side of the conversation engine:

```
Agent (Twi speech) ─► Twi STT ─► Twi text ─► [protect entities] ─► Twi→English ─► engine (English) ─┐
Agent (Twi text) ──────────────────────────────┘                                                    │
Agent ◄─ Twi TTS ◄─ Twi text ◄─ [restore entities / Twi templates] ◄─ English→Twi ◄── reply (English) ┘
```

English input skips both translation steps.

**Why this works well here**
- LLMs are strongest in English, so extraction and reply quality is easier to test and predict.
- All Twi skill sits in one Ghana-specialised, swappable provider (Khaya or Abena AI).
- The engine, prompts, validation and eval suite exist in one language only.

**What it costs and how we contain it**

| Risk | Mitigation |
|---|---|
| Translation changes numbers ("five" ↔ "enum", digit groups), names or phone numbers | **Entity protection:** before translation, deterministic code detects numbers (Twi and English numerals), phone-number sequences and known names/products. It replaces them with placeholders such as `⟦N1⟧` and `⟦PHONE1⟧`, and restores them afterwards. Product aliases include Twi names |
| Code-switched speech gets garbled by translation | Language detection per message. Mostly-English messages skip translation. The LLM receives the **English translation as primary input and the original transcript as reference**, so it can recover English words the translation lost. This is cheap: no Twi output is needed from the LLM |
| Critical confirmations translated wrongly | Read-backs and confirmation questions ("You sold 4 copies of Book A, is that right?") use **fixed Twi templates written by native speakers**, with slots filled by code. They are never machine-translated |
| Extra latency (two more network hops per Twi turn) | Measure per stage; cache translations of common phrases; keep replies short |
| Unnatural Twi phrasing in free replies | Native-speaker review in §12; grow the template set for the most common replies |

**Data stored per turn:** original text, English translation, translation provider, and detected language. Managers see both in the transcript view, so translation errors can be audited.

**Interface:** `Translator.translate(text, from, to) → {text, provider}`, with adapters for Khaya and Abena AI. It is configured per company, like the speech adapters.

---

## 5. System architecture

```
┌──────────────────────── Flutter app (Android / iOS / Web) ────────────────────────┐
│ presentation (widgets, Riverpod controllers)                                      │
│ domain (entities, use cases, validation shared with offline form)                 │
│ data: SupabaseRepository · LocalDb (drift) · Outbox · AudioRecorder/Player        │
└───────────┬───────────────────────────────┬───────────────────────────────────────┘
            │ HTTPS (JWT)                   │ HTTPS (JWT) audio/text turns
            ▼                               ▼
┌──────────────────── Supabase ───────────────────────────────────────────────────────┐
│ Auth (JWT + custom claims: company_id, role)                                        │
│ PostgREST reads  ──► Postgres with RLS on every tenant table                        │
│ RPC commands     ──► SECURITY DEFINER functions: submit_report, issue_stock, …      │
│                      (role checks, idempotency, ledger writes, audit log)           │
│ Edge Functions:                                                                     │
│   conversation-turn ─► Translator (Twi⇄English, entity protection; Khaya/Abena)    │
│                        ─► ConversationEngine ─► LlmProvider (Claude/Gemini adapter) │
│                        └► ContextBuilder (scoped SQL: last stock, follow-ups…)      │
│   speech-stt / speech-tts ─► SpeechProvider adapters (Google/Deepgram/Khaya/…)      │
│   reminders (pg_cron-triggered) ─► push notifications (FCM)                         │
│ Vault/secrets: all provider keys. Never in the app                                  │
└─────────────────────────────────────────────────────────────────────────────────────┘
Future (not built): telephony gateway / WhatsApp ──► same conversation-turn API (channel field)
```

Key principles:
- **Reads** go through PostgREST with RLS.
- **Writes that matter** (sales, stock, report commits, user management) go **only** through RPC functions. Tenant tables do not allow direct insert or update to these roles.
- The **conversation engine is channel-agnostic.** A turn is `{session_id, channel: app_text|app_voice|phone|whatsapp, input_text, stt_meta}`. Telephony and WhatsApp later become new channel adapters.

---

## 6. Conversation engine design

**State:** `report_sessions.draft` (JSONB, versioned). It holds typed slots:

```jsonc
{
  "sales": [{ "id": "s1", "product_id": "…", "quantity": 4, "unit_price": 50.00,
              "payment_status": "paid", "payment_method": "momo",
              "customer_ref": "c1", "status": "confirmed|needs_confirmation" }],
  "no_sales_declared": false,
  "stock_counts": [{ "product_id": "…", "quantity": 5 }],
  "prospects": { "count": 5 },
  "customers": [{ "ref": "c1", "name": "Ama Mensah", "phone_e164": "+23324…",
                  "match": { "customer_id": "…", "state": "pending|confirmed|rejected" },
                  "consent": true }],
  "follow_ups": [{ "customer_ref": "c1", "due": "tomorrow" , "note": "…" }],
  "follow_up_outcomes": [{ "follow_up_id": "…", "outcome": "contacted|not_reached|sold" }],
  "comments": "…"
}
```

**Each turn:**
0. **Language step (Twi only, §4.5):** detect the language, protect entities, translate Twi → English. At the end of the turn, translate the reply English → Twi, or use a Twi template.
1. **Context** (built once per session and cached): products and prices, agent's current stock by product, yesterday's count, open follow-ups due, last report time. Always scoped to `company_id` and agent.
2. **Extract (LLM call 1, structured output):** returns a list of **operations**: `add_sale`, `update_sale`, `remove_sale`, `set_stock_count`, `declare_no_sales`, `add_customer`, `confirm_match`, `add_follow_up`, `record_follow_up_outcome`, `set_prospects`, `set_comment`, `request_end`. It also returns the `detected_language`. The model may only reference IDs that exist in the context or draft.
3. **Validate and apply (deterministic code):** product exists and is active; quantity is a positive integer; phone normalises to a Ghana E.164 number; prices come from the catalog unless stated; stock is checked against the ledger. Phone matches are found with `find_customer_by_phone`. Invalid operations become **issues**, not data.
4. **Agenda (deterministic):** lists missing required slots, issues, unconfirmed names and phones, matches to confirm, and optional slots not yet asked. The agent can skip optional slots.
5. **Respond (LLM call 2, short):** phrases the top agenda item naturally in English, with an encouraging tone. For Twi sessions, it is then translated or replaced by a Twi template. **Read-backs of numbers, names and phones use fixed templates**, so they can't be paraphrased wrongly.
6. **Summary and confirm:** when the agenda's required items are empty, or the agent asks to finish, the backend renders the summary from the draft. If the agent confirms, the engine calls `submit_report`. If not, corrections continue.

Corrections and "go back" are just `update_*` or `remove_*` operations. Info given early ("I sold 6 and have 5 left") fills several slots at once, so nothing is asked twice. Sessions persist, so the agent can resume later. If two LLM calls make turns too slow, we merge them and use template replies for confirmations.

**Required for a complete daily report:** closing stock count for every product the agent holds; either sales or an explicit "no sales". Each sale needs product + quantity. Amount is required if payment is paid or partial (D2). A new customer needs name, phone and consent. Everything else is optional.

**Retention:** audio is processed in memory and **not stored** by default. A per-company opt-in, short-retention debug store is available for testing only. Transcripts are kept with the session for audit. Retention period is configurable (default 90 days); after that, transcripts are redacted.

---

## 7. Database schema (core)

All tenant tables have `company_id uuid not null`, RLS enabled, and composite indexes leading with `company_id`. Money is `numeric(12,2)` with currency on the company (GHS). Timestamps are `timestamptz` set by `now()` on the server.

```sql
-- Tenancy & identity
companies(id, name, country, timezone default 'Africa/Accra', currency default 'GHS',
          plan, settings jsonb, created_at)
profiles(user_id pk → auth.users, full_name, phone_e164, preferred_language)
memberships(id, company_id, user_id, role check (role in ('admin','manager','agent')),
            team_id null, status ('active','suspended'), created_at,
            unique(company_id, user_id))
teams(id, company_id, name)

-- Catalog
products(id, company_id, sku, name, aliases text[],  -- aliases help the LLM match "Book A"
         unit_price numeric, active bool, created_at)

-- Customers
customers(id, company_id, full_name, phone_e164, location_text, notes,
          consent_given bool, consent_method, consent_at, created_by, assigned_agent_id,
          created_at, updated_at, version int)
  index (company_id, phone_e164)          -- not unique: shared phones exist
customer_interactions(id, company_id, customer_id, agent_id, report_id,
          kind ('sale','prospect','follow_up','note'), product_id null, notes, created_at)
follow_ups(id, company_id, customer_id, agent_id, due_date, status ('open','done','cancelled'),
          outcome, source_report_id, created_at, closed_at)
customer_match_reviews(id, company_id, new_customer_id, candidate_customer_id,
          state ('pending','same','different'), resolved_by, resolved_at)

-- Reporting
report_sessions(id, company_id, agent_id, channel, language, status
          ('active','awaiting_confirmation','submitted','abandoned'), draft jsonb,
          draft_version int, started_at, last_turn_at)
conversation_turns(id, company_id, session_id, role ('agent','assistant'), text,
          detected_language, english_text, translation_provider,
          stt_provider, stt_confidence, llm_provider, tokens_in, tokens_out, latency_ms, created_at)
reply_templates(id, key, language, body, version, approved_by)  -- native-speaker Twi read-backs
daily_reports(id, company_id, agent_id, business_date, client_op_id unique,
          source ('conversation','offline_form'), session_id null,
          sales_count int, total_amount numeric, prospects_count int, comments,
          received_at, client_captured_at, late_sync bool,
          unique(company_id, agent_id, business_date))  -- one per day; later inputs amend it

-- Sales
sales(id uuid pk (client-generated), company_id, agent_id, report_id, customer_id null,
      product_id, quantity int check (quantity > 0), unit_price, total_amount,
      price_override bool, payment_method check (payment_method in ('cash','momo')),
      payment_status default 'paid',  -- only 'paid' in MVP (D2); credit later
      recorded_at default now(), voided_at null, void_reason)

-- Inventory ledger
stock_locations(id, company_id, kind ('store','agent','customer','write_off','external','adjustment'),
      agent_id null, name)
stock_movements(id uuid pk, company_id, product_id, quantity int check (quantity > 0),
      from_location_id, to_location_id,
      movement_type ('receipt','issue','return','sale','damage','loss','adjustment'),
      sale_id null, report_id null, reason, performed_by, approved_by null,
      client_op_id null, created_at default now())        -- append-only
stock_balances(company_id, location_id, product_id, quantity, updated_at,
      primary key(location_id, product_id))               -- maintained by trigger; derived cache
stock_counts(id, company_id, agent_id, product_id, business_date, report_id,
      reported_qty, expected_qty, created_at)
stock_discrepancies(id, company_id, agent_id, product_id, business_date, stock_count_id,
      expected_qty, reported_qty, difference, status ('open','resolved','written_off'),
      resolution_movement_id, resolved_by, resolved_at, note)

-- Targets
daily_targets(id, company_id, scope ('company','team','agent'), team_id, agent_id,
      product_id null, metric ('units','amount'), value, effective_from, effective_to)

-- Platform
idempotency_keys(company_id, client_op_id, command, result jsonb, created_at,
      primary key(company_id, client_op_id))
audit_log(id, company_id, actor_id, action, entity, entity_id, before jsonb, after jsonb, created_at)
ai_usage(company_id, user_id, window_start, requests, tokens)  -- rate limiting & cost tracking
reminder_settings(company_id, agent_id null, window_start, window_end, days int[], enabled)
```

**Expected closing stock** for an agent and product equals the agent location's balance at the end of the business date. Because every movement is in the ledger, this automatically equals opening + issued − sold − returned − damaged/lost ± approved adjustments. Corrections never edit movements. They add compensating `adjustment` movements with `approved_by` and an audit entry.

---

## 8. Roles and permissions

All rules are enforced in RLS and in the RPC functions. UI hiding is cosmetic only.

| Capability | Admin | Manager | Agent |
|---|---|---|---|
| Company settings, AI/speech settings, reminder policy | ✅ | ❌ | ❌ |
| Invite, suspend users; change roles | ✅ | Agents only | ❌ |
| Products & prices | ✅ | ✅ | Read |
| Issue / return / damage / loss / adjust stock | ✅ | ✅ | ❌ |
| Approve discrepancy resolutions | ✅ | ✅ | ❌ |
| View company inventory totals & stock records | ✅ | ✅ | Own holdings only |
| Customers | All | All, create/edit/resolve matches | Own/assigned/interacted (D4). Masked phone lookup |
| Sales | All | All; void with reason | Create via reports. Read own |
| Reports & conversation transcripts | All | All | Own |
| Targets | ✅ | ✅ | Read own |
| Dashboards | ✅ | ✅ | Own home summary |
| Audit log | Read | Read (operational entities) | ❌ |

A platform-operator role (you, across tenants) is kept **out of the app**. Support access goes through the Supabase dashboard and service role, and is audited.

---

## 9. API contracts (MVP)

All commands take a `client_op_id` (UUID v4, generated on the device). Replaying a command returns the stored result. Errors use `{code, message, details}`; codes include `forbidden`, `validation_failed`, `conflict`, `insufficient_stock_flagged`, `rate_limited`.

**RPC (Postgres functions)**

| Function | Caller | Input → Output |
|---|---|---|
| `create_company(name, admin_full_name)` | New signed-up user | → `{company_id}` |
| `invite_member(phone_or_email, role, full_name, team_id?)` | Admin, manager (agents only) | → `{user_id, temp_credential_delivery}` |
| `submit_report(client_op_id, business_date_hint?, client_captured_at, payload)` | Agent | `payload` = the draft schema in §6 → `{report_id, business_date, sales:[ids], discrepancies:[…], match_reviews:[…], late_sync}` |
| `record_stock_movement(client_op_id, product_id, quantity, type, from, to, reason)` | Manager | → `{movement_id, balances}` |
| `issue_stock(client_op_id, agent_id, lines:[{product_id, quantity}], note)` | Manager | → `{movement_ids}` |
| `resolve_discrepancy(id, action: adjust|write_off|recount, note)` | Manager | → `{status, movement_id?}` |
| `resolve_customer_match(review_id, same: bool)` | Manager, agent who created the record | → `{customer_id}` |
| `find_customer_by_phone(phone)` | Agent | → `[{customer_id, first_name, masked_phone}]` (rate-limited) |
| `void_sale(sale_id, reason)` | Manager | Adds reversing stock movement → `{ok}` |
| `dashboard_summary(from, to, agent_ids?, product_ids?, team_id?)` | Manager, admin | → KPIs + series |
| `agent_home()` | Agent | → today's sales, target progress, stock, due follow-ups, last report |

**Edge Functions**

| Endpoint | Input → Output |
|---|---|
| `POST /conversation/start` | `{channel, language_pref}` → `{session_id, assistant_text, audio_url?}` |
| `POST /conversation/turn` | `{session_id, draft_version, text? , audio? (multipart), language_hint?}` → `{transcript?, assistant_text, audio_url?, draft, agenda, state}` |
| `POST /conversation/confirm` | `{session_id, client_op_id}` → `submit_report` result |
| `POST /conversation/abandon` | `{session_id}` → `{ok}` (draft kept for resume) |

`draft_version` gives optimistic concurrency, so two devices can't race the same session.

---

## 10. Offline-first strategy

- **Local DB (drift):** read caches of products, own stock, own customers and follow-ups. An `outbox` of commands. Report drafts.
- **Each queued item shows one status:** `Saved on device` → `Waiting to sync` → `Synced` (or `Needs attention`, with the reason).
- **Offline fallback:** a structured form (products × quantity, stock counts, customers, follow-ups). It produces the **same payload** as the conversation draft and goes through the same `submit_report`. The UI states plainly: *"The AI assistant needs internet. You can file your report with the form now, and it will sync automatically."*
- **Sync:** triggered on reconnect, on app resume and periodically. Commands are sent in order with exponential backoff. Server results (canonical IDs, discrepancies, match reviews) update the local cache.

**Conflict rules**

| Data | Rule |
|---|---|
| Sales | Client UUID + `client_op_id` mean a replay can never duplicate a sale. Sales are only ever added; corrections are manager voids |
| Stock movements | Append-only. The client never sends balances. Insufficient balance is **accepted + flagged**, never rejected or silently capped |
| Stock counts | Observations tied to a business date. A second count for the same day replaces the earlier one (audited) and recomputes the discrepancy |
| Daily report | One per agent per day. A later submission for the same day **amends** it (adds sales, replaces counts). Never a second report |
| Customer edits | Version check. If the server version is newer, the server wins and the agent sees "updated by someone else". Notes are appended, never overwritten |
| Customer creation offline | Match detection runs on sync. Possible duplicates become `customer_match_reviews`, never auto-merged |
| Manager stock operations | Require connectivity in the MVP. Simpler and safer |

---

## 11. Security & reliability

- **Tenant isolation:** RLS on every tenant table, using `company_id = app.current_company_id()`. That function looks up the caller's active row in `memberships` on each request, rather than reading a JWT claim, so suspension takes effect immediately instead of at token expiry. MVP: one company per user. SECURITY DEFINER functions re-check membership and role, and pin `search_path`. Automated tests try cross-tenant reads and writes on every table.
- **Secrets:** provider keys only in Supabase secrets, used only in Edge Functions. Nothing in the Flutter bundle except the public anon key.
- **Rate limits:** per user and per company on conversation turns and phone lookups (`ai_usage` table). Hard monthly AI spend cap per company.
- **PII:** phones are normalised and visible only per D4. Masked phone lookup. Consent captured with method and time. Audio not stored. Transcript redaction after retention period. Every access to sensitive operations is audit-logged.
- **Reliability:** idempotent commands, retries with backoff, provider fallbacks (LLM secondary model; STT fallback, then text), structured error codes, and logs of latency and token cost per turn.

---

## 12. Twi & English testing process

1. **Panel:** 12–20 paid native speakers, mixed gender and age, Asante + Akuapem (D1). Include real or realistic field agents.
2. **Script set (~60 prompts per speaker):** sales reports in English, Twi and code-switched speech; Twi numerals and English numerals; product names; Ghanaian personal names; phone numbers spoken digit by digit and in groups; corrections ("no, it was five").
3. **Conditions:** quiet room, roadside or market noise, inside a vehicle, low-end Android phone microphones.
4. **Consent:** written consent for recordings. Recordings used only for evaluation and deleted after the agreed period.
5. **Metrics** (entity accuracy matters more than WER):
   - STT: WER/CER; **numeric-entity accuracy**; name and phone digit accuracy.
   - End-to-end: slot accuracy after confirmation; number of corrections per report; time to complete.
   - TTS: native-speaker naturalness/intelligibility rating (1–5); a listening test of numbers.
   - Translation (Khaya vs Abena AI): entity survival rate (numbers, names, phones unchanged after protect → translate → restore); meaning preserved, judged by native speakers; same for English → Twi replies.
6. **Proposed gate for enabling Twi voice:** ≥98% of numeric entities correct **after read-back confirmation**, median ≤1 correction per report, TTS intelligibility ≥4/5. Otherwise Twi stays text-first.
7. **Re-test** whenever a provider or model changes. The set becomes a regression suite.

---

## 13. Implementation roadmap

| Phase | Deliverables | Exit criteria |
|---|---|---|
| **2. Foundation** | Flutter skeleton (feature-first clean architecture), design tokens & components, Supabase project + migrations, auth (email for admins, phone+password for agents), company onboarding, memberships & RLS, role-based navigation shells (agent mobile, manager responsive) | Cross-tenant RLS test suite passes; three roles log in and see the right shell |
| **3. Core operations** | Products, agents, customers (+ match detection), stock locations & ledger, issue/return/damage/loss/adjust, `submit_report` via the **structured form**, stock counts & discrepancies, daily targets | Ledger reconciliation tests; idempotency tests; report-state (none/zero/sales) tests |
| **4. AI assistant** | Provider-neutral LLM interface + 2 adapters, Twi/English eval and model choice, conversation engine (operations, validator, agenda, templates), text chat UI, STT/TTS adapters, English voice UI with interrupt, context retrieval, rate limits | Eval scores recorded; scripted conversation tests pass; no LLM output reaches tables without validation |
| **5. Offline** | drift cache, outbox, sync engine, status UI, conflict handling, conversation → form handoff | Airplane-mode tests: no duplicates, all reports converge |
| **6. Dashboards** | Overview KPIs, sales by product/agent, customers & follow-ups, inventory totals, movements, discrepancies, agents not reported + last report time, filters | Numbers match SQL ground truth on seeded data |
| **7. Testing & refinement** | Full test pass (§12 included), responsive QA, error/recovery scenarios, setup docs | Pilot with one real company |

Twi speaker recruitment (§12) should **start during Phase 2**, so data is ready for Phase 4.

---

## 14. Key risks

| Risk | Mitigation |
|---|---|
| Twi STT/TTS not good enough | Text-first parity, feature flag, confirmation templates, Khaya/open-model bake-off, budget for later fine-tuning on consented data |
| LLM mis-extracts quantities | Deterministic validation, fixed read-backs, explicit confirmation, eval suite in CI |
| Voice latency feels slow | Short replies, prompt caching, stream TTS, measure per-stage latency; merge LLM calls if needed |
| Agents game or skip stock counts | Count required for a complete report; discrepancy dashboard; "no report" visible to managers |
| Supabase Edge Function limits for audio | Turn-based (short) requests; move speech to a small container service if limits bite |
| Pricing drift | Per-company usage metering in `ai_usage`; prices kept in config, not code |

---

## 15. Sources (checked 2026-11-04)

- Google STT supported languages: https://docs.cloud.google.com/speech-to-text/docs/speech-to-text-supported-languages
- Google TTS voices: https://docs.cloud.google.com/text-to-speech/docs/list-voices-and-types
- Azure Speech language support: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support?tabs=stt
- ElevenLabs STT: https://elevenlabs.io/docs/capabilities/speech-to-text
- Google Translation languages (Twi `ak`): https://docs.cloud.google.com/translate/docs/languages
- Gemini pricing: https://aistudio.google.com/docs/pricing
- Khaya SDK (Twi ASR/TTS): https://khaya-sdk.readthedocs.io/ · https://pypi.org/project/khaya/
- WAXAL-NET (Akan ASR results): https://arxiv.org/pdf/2606.02375
- Benchmarking Akan ASR (Mensah et al.): https://huggingface.co/papers/2507.02407
- Twi TTS models: https://huggingface.co/ghananlpcommunity/nano-twi · https://huggingface.co/ghananlpcommunity/Simba-TTS-twi-asanti · https://huggingface.co/ghananlpcommunity/stable-twi-tts
- Supabase pricing (third-party): https://makerkit.dev/blog/saas/supabase-pricing
- STT pricing (third-party): https://diyai.io/ai-tools/speech-to-text/speech-to-text-api-pricing/ · https://www.happyrobot.ai/hub/deepgram-pricing
- OpenAI realtime pricing (third-party): https://aireiter.com/blog/openai-realtime-api-pricing
- Claude pricing: Anthropic model reference (claude-api skill, cached 2026-10-06)

---

## Implementation notes (Phase 4)

- **English voice uses the device's own speech recognition and voice** (Android/iOS/browser), not a paid STT/TTS provider. It is free and fast, and works well for English. The speech interface keeps a server-side provider possible later. Twi speech goes through Khaya on the server.
- **Twi voice is off per company** (`settings.twi_voice_enabled`) until it passes the §12 tests. Typed Twi works through the translation layer.
- **Khaya calls are capped per company per month** (`settings.khaya_monthly_calls`, default 100 to match the free developer plan). When the cap is reached, the assistant says so and continues in English. The agent can also use the form.
- **Twi reply templates** (§4.5) are not written yet: they need native speakers. Until then, Twi replies are machine-translated with names and numbers protected, and the summary card on screen stays in English.
- **The LLM is chosen by configuration.** Claude (`claude-haiku-5-5`) is preferred when its key is set; otherwise Gemini (`gemini-3.1-flash-lite`). The §4.1 extraction eval should still decide the production model.
