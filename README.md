# Field Sales Platform

Multi-tenant field sales and operations platform: Flutter app (Android, iOS, web) + Supabase backend.
Architecture and decisions: [docs/phase-1-architecture-plan.md](docs/phase-1-architecture-plan.md).

## Repository layout

```
app/                    Flutter app
  lib/core/             config, design system, routing, shared helpers
  lib/features/<name>/  data (repositories) · domain (models, rules) · application (state) · presentation (UI)
  test/                 unit and widget tests
supabase/
  migrations/           SQL migrations (schema, RLS, RPC commands)
  functions/            Edge Functions (Deno); all provider secrets live here
  tests/                database tests: run the migrations in PGlite and check isolation/permissions
  config.toml           local Supabase configuration
docs/                   planning documents
```

## Security model

- Every tenant table has `company_id` and row-level security.
- A user's company and role are looked up from `memberships` on every request, so a suspended user loses access immediately.
- Clients can only **read** tenant tables (through RLS). All writes go through `SECURITY DEFINER` functions that check the caller's role.
- Creating accounts needs the service-role key, so it happens in the `invite-member` Edge Function. The app only ever holds the publishable key.

## Business rules (as implemented)

- **Stock** is an append-only ledger (`stock_movements`). Balances are derived by a trigger and never written by clients. Corrections are new `adjustment` movements, which need a reason and are audited.
- **Managers** cannot issue, return or write off more than the source holds; that would be a data-entry error. **Agents' sales** beyond their recorded stock are accepted and flagged (`stock_flagged`), never dropped.
- **Daily report**: one per agent per business day, and later submissions amend it. The first submission must contain sales or an explicit "no sales", which keeps *no report*, *zero sales* and *sales* distinct. Totals are recomputed on the server.
- **Closing counts** are compared with the ledger when submitted. A mismatch opens a discrepancy, and a matching recount closes it. Managers resolve by *accept count* (adjust), *record as lost* (shortages only) or *dismiss*.
- **Business date** is the server date in the company timezone. A late offline sync uses the device capture time only when it falls within the last 72 hours, and is flagged `late_sync`.
- **Customers**: a phone number is stored only with the customer's consent. Agents see customers they created, are assigned to, or have dealt with; other matches come only through a masked, rate-limited lookup. Duplicate phones create a review for managers and never auto-merge.
- **Targets**: per day, by company or agent (optionally per product). The most specific target wins, and setting a new one replaces the old one from that date.
- **Idempotency**: every command carries a client-generated `client_op_id`, and replays return the original result.

## Prerequisites

- Flutter (stable) — `flutter --version`
- Node.js 20+ — for the database tests and the Supabase CLI (`npx supabase`)
- A Supabase project (hosted). Docker is only needed if you want a local Supabase stack (`npx supabase start`).

## Environment variables

| Where | Name | Notes |
|---|---|---|
| App (`app/env.json`) | `SUPABASE_URL` | Project URL |
| App (`app/env.json`) | `SUPABASE_PUBLISHABLE_KEY` | Public client key (Project Settings → API Keys). Never put a secret or service-role key here |
| Edge Functions | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Injected automatically by Supabase |

Copy `app/env.example.json` to `app/env.json` and fill it in. `env.json` is git-ignored.

## Set up the backend

```bash
npx supabase login
npx supabase link --project-ref YOUR-PROJECT-REF
npx supabase db push --remote                 # apply migrations to the linked project
npx supabase functions deploy invite-member
```

Auth settings in the hosted dashboard (Authentication → Sign In / Providers). `config.toml` only applies to a local stack, so set these by hand:

1. **Email provider: enabled.** Company administrators sign up with email. Decide whether email confirmation is required; the app handles both.
2. **Phone provider: leave off.** Agents type their phone number + password, but sign in through the Email provider: `invite-member` creates their login as `<digits>@phone.fieldsales.invalid`, already confirmed, so no SMS provider is needed. `.invalid` is a reserved domain, so password-reset mail for these logins can never reach anyone. Admins reset agent passwords instead.
3. **Minimum password length: 8.**
4. **URL Configuration → Site URL:** your web app URL (`http://localhost:3000` while testing).

## Run the app

```bash
cd app
flutter pub get
flutter run --dart-define-from-file=env.json            # device/emulator
flutter run -d chrome --dart-define-from-file=env.json  # web
```

First use: **Create an account** (email) → **Set up your company** → you're the administrator. Add managers and agents under **Agents → Add member**. Share each agent's phone number and temporary password with them directly.

## Tests and checks

```bash
cd supabase/tests && npm install && npm test         # database: tenant isolation, roles, audit
node --test supabase/functions/_shared/phone.test.ts # Edge Function helpers (Node 22.6+)
cd app && flutter analyze && flutter test            # Flutter
```

The database tests run the real migrations in [PGlite](https://pglite.dev) (Postgres in WebAssembly) with a small stand-in for Supabase's `auth` schema and roles. No Docker or hosted project is needed.
