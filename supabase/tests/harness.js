// Test harness: runs the real migrations in PGlite (Postgres compiled to WASM)
// on top of a minimal stand-in for the parts of Supabase they depend on:
// the anon/authenticated/service_role roles, auth.users and auth.uid().
import { PGlite } from '@electric-sql/pglite';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '..', 'migrations');

const SUPABASE_STUB = `
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
  create schema auth;
  grant usage on schema auth, public to anon, authenticated, service_role;
  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    email text unique,
    phone text unique
  );
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(
      coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
               (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')),
      '')::uuid
  $$;
  grant execute on function auth.uid() to anon, authenticated, service_role;
`;

export async function createDb() {
  const db = new PGlite();
  await db.exec(SUPABASE_STUB);
  const files = readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
  for (const file of files) {
    await db.exec(readFileSync(join(migrationsDir, file), 'utf8'));
  }
  // Supabase grants table privileges to service_role by default.
  await db.exec(`
    grant all on all tables in schema public to service_role;
    grant usage on schema app to service_role;
  `);
  return db;
}

export async function createUser(db, { email, phone } = {}) {
  const id = randomUUID();
  await db.query('insert into auth.users (id, email, phone) values ($1, $2, $3)', [
    id, email ?? `${id}@test.local`, phone ?? null,
  ]);
  return id;
}

// Runs fn with the session acting as `role` (and auth.uid() = userId).
// Always restores the superuser session, even when fn throws.
export async function as(db, userId, fn, role = 'authenticated') {
  const claims = JSON.stringify(userId ? { sub: userId, role } : { role });
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [claims]);
  await db.exec(`set role ${role}`);
  try {
    return await fn();
  } finally {
    await db.exec('reset role');
    await db.query(`select set_config('request.jwt.claims', '', false)`);
  }
}

export const rows = async (db, sql, params) => (await db.query(sql, params)).rows;

// Creates a company with an admin and returns their ids.
export async function seedCompany(db, name) {
  const admin = await createUser(db);
  const [{ create_company: companyId }] = await as(db, admin, () =>
    rows(db, 'select public.create_company($1, $2) as create_company', [name, `${name} Admin`]));
  return { companyId, admin };
}

// Adds a member the way the invite-member Edge Function does (service role).
export async function addMember(db, inviter, role, fullName = `${role} user`) {
  const user = await createUser(db);
  await as(db, null, () => rows(db,
    'select public.admin_add_member($1, $2, $3::app.member_role, $4)',
    [inviter, user, role, fullName]), 'service_role');
  return user;
}
