import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createDb, createUser, as, rows, seedCompany, addMember } from './harness.js';

let db;
let A; // { companyId, admin, manager, agent, agent2 }
let B;

before(async () => {
  db = await createDb();
  A = await seedCompany(db, 'Alpha Books');
  A.manager = await addMember(db, A.admin, 'manager');
  A.agent = await addMember(db, A.manager, 'agent');
  A.agent2 = await addMember(db, A.manager, 'agent');
  B = await seedCompany(db, 'Beta Foods');
  B.agent = await addMember(db, B.admin, 'agent');
});

const rejects = (promise, pattern) => assert.rejects(promise, pattern);

// --- Onboarding ------------------------------------------------------------

test('create_company makes the caller an admin of the new company', async () => {
  const ctx = await as(db, A.admin, () => rows(db, 'select public.my_context() as c'));
  assert.equal(ctx[0].c.membership.role, 'admin');
  assert.equal(ctx[0].c.membership.company_id, A.companyId);
  assert.equal(ctx[0].c.membership.company_name, 'Alpha Books');
});

test('a user cannot create or join a second company', async () => {
  await rejects(as(db, A.admin, () => rows(db, "select public.create_company('Again', 'X Y')")),
    /already_member/);
  await rejects(as(db, null, () => rows(db,
    "select public.admin_add_member($1, $2, 'agent', 'Dup')", [B.admin, A.agent]), 'service_role'),
    /duplicate key/);
});

test('my_context returns no membership for a signed-up user without a company', async () => {
  const loner = await createUser(db);
  const [{ c }] = await as(db, loner, () => rows(db, 'select public.my_context() as c'));
  assert.equal(c.membership, null);
});

test('anonymous callers cannot read data or create companies', async () => {
  await rejects(as(db, null, () => rows(db, 'select * from public.companies'), 'anon'),
    /permission denied/);
  await rejects(as(db, null, () => rows(db, "select public.create_company('X Co', 'X Y')"), 'anon'),
    /permission denied/);
});

// --- Tenant isolation ------------------------------------------------------

test('members only ever see their own company', async () => {
  for (const user of [A.admin, A.manager, A.agent]) {
    const companies = await as(db, user, () => rows(db, 'select id from public.companies'));
    assert.deepEqual(companies.map((c) => c.id), [A.companyId]);
  }
  const fromB = await as(db, B.admin, () => rows(db, 'select id from public.companies'));
  assert.deepEqual(fromB.map((c) => c.id), [B.companyId]);
});

test('admins cannot see memberships, profiles or audit entries of another company', async () => {
  await as(db, B.admin, async () => {
    const members = await rows(db, 'select company_id from public.memberships');
    assert.ok(members.length > 0);
    assert.ok(members.every((m) => m.company_id === B.companyId));

    const profiles = await rows(db, 'select user_id from public.profiles');
    const ids = profiles.map((p) => p.user_id);
    assert.ok(!ids.includes(A.admin) && !ids.includes(A.agent));

    const audit = await rows(db, 'select company_id from public.audit_log');
    assert.ok(audit.every((a) => a.company_id === B.companyId));
  });
});

test('an admin cannot modify a member of another company', async () => {
  const [{ id }] = await rows(db, 'select id from public.memberships where user_id = $1', [A.agent]);
  await rejects(as(db, B.admin, () => rows(db,
    "select public.update_member($1, null, 'suspended')", [id])), /not_found/);
});

test('a manager cannot invite into another company by naming a foreign inviter', async () => {
  // The inviter's own membership decides the company; B's admin always invites into B.
  const newcomer = await createUser(db);
  await as(db, null, () => rows(db,
    "select public.admin_add_member($1, $2, 'agent', 'New Agent')", [B.admin, newcomer]), 'service_role');
  const [m] = await rows(db, 'select company_id from public.memberships where user_id = $1', [newcomer]);
  assert.equal(m.company_id, B.companyId);
});

// --- Role-based access -----------------------------------------------------

test('agents see only their own membership and profile', async () => {
  await as(db, A.agent, async () => {
    const members = await rows(db, 'select user_id from public.memberships');
    assert.deepEqual(members.map((m) => m.user_id), [A.agent]);
    const profiles = await rows(db, 'select user_id from public.profiles');
    assert.deepEqual(profiles.map((p) => p.user_id), [A.agent]);
    const audit = await rows(db, 'select id from public.audit_log');
    assert.equal(audit.length, 0);
  });
});

test('managers see all members of their company', async () => {
  const members = await as(db, A.manager, () => rows(db, 'select user_id from public.memberships'));
  const ids = members.map((m) => m.user_id).sort();
  assert.deepEqual(ids, [A.admin, A.manager, A.agent, A.agent2].sort());
});

test('clients cannot write tenant tables directly, whatever their role', async () => {
  await rejects(as(db, A.admin, () => rows(db,
    "update public.memberships set role = 'admin' where user_id = $1", [A.agent])), /permission denied/);
  await rejects(as(db, A.admin, () => rows(db,
    "insert into public.companies (name) values ('Sneaky')")), /permission denied/);
  await rejects(as(db, A.agent, () => rows(db,
    'delete from public.audit_log')), /permission denied/);
});

test('only the service role can call admin_add_member', async () => {
  const someone = await createUser(db);
  await rejects(as(db, A.admin, () => rows(db,
    "select public.admin_add_member($1, $2, 'agent', 'X Y')", [A.admin, someone])), /permission denied/);
});

test('invite rules: managers invite agents only; agents invite nobody', async () => {
  const u1 = await createUser(db);
  const u2 = await createUser(db);
  const call = (inviter, user, role) => as(db, null, () => rows(db,
    'select public.admin_add_member($1, $2, $3::app.member_role, $4)', [inviter, user, role, 'X Y']),
  'service_role');
  await rejects(call(A.manager, u1, 'manager'), /forbidden/);
  await rejects(call(A.manager, u1, 'admin'), /forbidden/);
  await rejects(call(A.agent, u2, 'agent'), /forbidden/);
  await call(A.admin, u1, 'manager'); // admins may add managers
});

test('managers can suspend agents but cannot touch managers or change roles', async () => {
  const membershipOf = async (u) =>
    (await rows(db, 'select id from public.memberships where user_id = $1', [u]))[0].id;
  const agentM = await membershipOf(A.agent2);
  const adminM = await membershipOf(A.admin);

  await rejects(as(db, A.manager, () => rows(db,
    "select public.update_member($1, 'manager', null)", [agentM])), /forbidden/);
  await rejects(as(db, A.manager, () => rows(db,
    "select public.update_member($1, null, 'suspended')", [adminM])), /forbidden/);
  await as(db, A.manager, () => rows(db, "select public.update_member($1, null, 'suspended')", [agentM]));
  await as(db, A.manager, () => rows(db, "select public.update_member($1, null, 'active')", [agentM]));
});

test('agents cannot manage members', async () => {
  const [{ id }] = await rows(db, 'select id from public.memberships where user_id = $1', [A.agent2]);
  await rejects(as(db, A.agent, () => rows(db,
    "select public.update_member($1, null, 'suspended')", [id])), /forbidden/);
});

test('admins cannot change their own role or status', async () => {
  const [{ id }] = await rows(db, 'select id from public.memberships where user_id = $1', [A.admin]);
  await rejects(as(db, A.admin, () => rows(db,
    "select public.update_member($1, 'agent', null)", [id])), /cannot_modify_self/);
});

test('suspension removes access immediately', async () => {
  const victim = await addMember(db, A.admin, 'agent');
  const [{ id }] = await rows(db, 'select id from public.memberships where user_id = $1', [victim]);
  assert.equal((await as(db, victim, () => rows(db, 'select id from public.companies'))).length, 1);

  await as(db, A.admin, () => rows(db, "select public.update_member($1, null, 'suspended')", [id]));
  assert.equal((await as(db, victim, () => rows(db, 'select id from public.companies'))).length, 0);
  await rejects(as(db, victim, () => rows(db, "select public.create_team('Night shift')")), /forbidden/);
});

test('teams: admins and managers create them, agents cannot', async () => {
  await as(db, A.manager, () => rows(db, "select public.create_team('Kumasi North')"));
  await rejects(as(db, A.agent, () => rows(db, "select public.create_team('Rogue team')")), /forbidden/);
  const teamsB = await as(db, B.admin, () => rows(db, 'select name from public.teams'));
  assert.ok(!teamsB.some((t) => t.name === 'Kumasi North'));
});

// --- Audit -----------------------------------------------------------------

test('sensitive operations are audit-logged with the actor', async () => {
  const audit = await as(db, A.admin, () => rows(db,
    'select action, actor_id from public.audit_log order by id'));
  const actions = audit.map((a) => a.action);
  assert.ok(actions.includes('company.created'));
  assert.ok(actions.includes('member.added'));
  assert.ok(actions.includes('member.updated'));
  const created = audit.find((a) => a.action === 'company.created');
  assert.equal(created.actor_id, A.admin);
});

// --- Phone normalisation ---------------------------------------------------

test('normalize_phone accepts common Ghana formats and rejects junk', async () => {
  const norm = async (raw) => (await rows(db, 'select app.normalize_phone($1) as p', [raw]))[0].p;
  for (const raw of ['024 123 4567', '0241234567', '233241234567', '+233 24-123-4567', '(024) 123 4567']) {
    assert.equal(await norm(raw), '+233241234567', raw);
  }
  assert.equal(await norm('0551234567'), '+233551234567');
  for (const bad of ['', '12345', '0141234567', '+2332412345678', 'abc']) {
    await rejects(norm(bad), /invalid_phone/, bad);
  }
});

test('list_members returns only the caller company, and only to admins/managers', async () => {
  const list = await as(db, A.manager, () => rows(db, 'select * from public.list_members()'));
  assert.ok(list.length >= 4);
  const bIds = (await rows(db, 'select user_id from public.memberships where company_id = $1', [B.companyId]))
    .map((r) => r.user_id);
  assert.ok(list.every((m) => !bIds.includes(m.user_id)));
  assert.ok(list.every((m) => m.full_name));
  await rejects(as(db, A.agent, () => rows(db, 'select * from public.list_members()')), /forbidden/);
});

// --- Phone logins (no SMS provider) ------------------------------------------

test('phone logins cannot self-onboard a company', async () => {
  const squatter = await createUser(db, { email: '233249990001@phone.fieldsales.invalid' });
  await rejects(as(db, squatter, () => rows(db, "select public.create_company('Squat Co', 'Some One')")),
    /email_account_required/);
});

test('orphaned phone logins can be found for replacement; real members never', async () => {
  const orphanEmail = '233249990002@phone.fieldsales.invalid';
  const orphan = await createUser(db, { email: orphanEmail });
  const find = (email) => as(db, null, () => rows(db,
    'select public.admin_orphan_phone_login($1) as id', [email]), 'service_role');

  assert.equal((await find(orphanEmail))[0].id, orphan);
  assert.equal((await find(orphanEmail.toUpperCase()))[0].id, orphan);

  const member = await addMember(db, A.admin, 'agent');
  await db.query("update auth.users set email = '233249990003@phone.fieldsales.invalid' where id = $1", [member]);
  assert.equal((await find('233249990003@phone.fieldsales.invalid'))[0].id, null);

  const emailUser = await createUser(db, { email: 'someone@example.com' });
  assert.ok(emailUser);
  assert.equal((await find('someone@example.com'))[0].id, null);

  await rejects(as(db, A.admin, () => rows(db, 'select public.admin_orphan_phone_login($1)', [orphanEmail])),
    /permission denied/);
});
