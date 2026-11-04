import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createDb, as, rows, seedCompany, addMember } from './harness.js';

let db;
let A;
let B;

const call = async (user, sql, params) => (await as(db, user, () => rows(db, sql, params)))[0]?.r;
const fails = (promise, pattern) => assert.rejects(promise, (err) => {
  assert.match(`${err.message} ${err.detail ?? ''}`, pattern);
  return true;
});

before(async () => {
  db = await createDb();
  A = await seedCompany(db, 'Alpha Books');
  A.manager = await addMember(db, A.admin, 'manager', 'Mary Manager');
  A.agent = await addMember(db, A.manager, 'agent', 'Kofi Mensah');
  A.agent2 = await addMember(db, A.manager, 'agent', 'Ama Agent');
  B = await seedCompany(db, 'Beta Foods');
  B.agent = await addMember(db, B.admin, 'agent', 'Beta Agent');

  A.book = await call(A.manager, `select public.save_product(null, 'Book A', 50) as r`);
  await call(A.manager, `select public.record_stock_transfer($1, 'receipt', $2::jsonb) as r`,
    [randomUUID(), JSON.stringify([{ product_id: A.book, quantity: 50 }])]);
  await call(A.manager, `select public.record_stock_transfer($1, 'issue', $2::jsonb, $3) as r`,
    [randomUUID(), JSON.stringify([{ product_id: A.book, quantity: 10 }]), A.agent]);
  // An earlier count, so the assistant can say "Last time you reported having ..."
  await db.query(`insert into public.daily_reports (company_id, agent_id, business_date) values ($1, $2, current_date - 1)`,
    [A.companyId, A.agent]);
  await db.query(`insert into public.stock_counts (company_id, agent_id, product_id, business_date, report_id, reported_qty, expected_qty)
                  select $1, $2, $3, current_date - 1, id, 5, 5 from public.daily_reports where agent_id = $2`,
    [A.companyId, A.agent, A.book]);
});

test('starting gives the assistant scoped context, and a second start resumes', async () => {
  const first = await call(A.agent, `select public.assistant_start('app_text', 'en') as r`);
  assert.equal(first.resumed, false);
  const ctx = first.session.context;
  assert.equal(ctx.agent_first_name, 'Kofi');
  assert.equal(ctx.report_state, 'none');
  assert.equal(ctx.twi_voice_enabled, false);
  assert.deepEqual(ctx.products.map((p) => p.name), ['Book A']);
  assert.equal(ctx.held[0].quantity, 10);
  assert.equal(ctx.held[0].last_count.quantity, 5);

  const again = await call(A.agent, `select public.assistant_start('app_voice', 'tw') as r`);
  assert.equal(again.resumed, true);
  assert.equal(again.session.id, first.session.id);
  assert.equal(again.session.language, 'tw');
});

test('only agents use the assistant', async () => {
  await fails(call(A.manager, `select public.assistant_start('app_text') as r`), /forbidden/);
});

test('saving is versioned: a stale write is rejected', async () => {
  const s = (await call(A.agent, `select public.assistant_start('app_text') as r`)).session;
  const v1 = await call(A.agent, `select public.assistant_save($1, $2, '{"sales":[]}'::jsonb, 'active',
      '[{"role":"assistant","text":"Hello"},{"role":"agent","text":"Matɔn nwoma","english_text":"I sold books","language":"tw"}]'::jsonb) as r`,
    [s.id, s.draft_version]);
  assert.equal(v1, s.draft_version + 1);
  await fails(call(A.agent, `select public.assistant_save($1, $2, '{}'::jsonb, 'active', '[]'::jsonb) as r`,
    [s.id, s.draft_version]), /conflict/);

  const loaded = await call(A.agent, `select public.assistant_load($1) as r`, [s.id]);
  assert.deepEqual(loaded.recent_turns.map((t) => t.text), ['Hello', 'I sold books'],
    'the engine sees the English version of Twi turns');
});

test('sessions and transcripts stay with the agent and their managers', async () => {
  const s = (await call(A.agent, `select public.assistant_start('app_text') as r`)).session;
  await fails(call(A.agent2, `select public.assistant_load($1) as r`, [s.id]), /not_found/);
  await fails(call(B.agent, `select public.assistant_load($1) as r`, [s.id]), /forbidden|not_found/);
  await fails(call(A.agent2, `select public.assistant_save($1, $2, '{}'::jsonb, 'active', '[]'::jsonb) as r`,
    [s.id, s.draft_version]), /conflict/);

  const asManager = await as(db, A.manager, () => rows(db, 'select text from public.conversation_turns'));
  assert.ok(asManager.length >= 2);
  const asOtherAgent = await as(db, A.agent2, () => rows(db, 'select text from public.conversation_turns'));
  assert.equal(asOtherAgent.length, 0);
  const fromB = await as(db, B.admin, () => rows(db, 'select id from public.report_sessions'));
  assert.equal(fromB.length, 0);
});

test('a submitted session closes, and the next start opens a fresh one', async () => {
  const s = (await call(A.agent, `select public.assistant_start('app_text') as r`)).session;
  const report = await call(A.agent, `select public.submit_report($1, $2::jsonb, null, 'conversation') as r`,
    [s.client_op_id, JSON.stringify({ no_sales: true })]);
  await call(A.agent, `select public.assistant_mark_submitted($1, $2) as r`, [s.id, report.report_id]);
  await fails(call(A.agent, `select public.assistant_load($1) as r`, [s.id]), /session_closed/);

  const next = await call(A.agent, `select public.assistant_start('app_text') as r`);
  assert.equal(next.resumed, false);
  assert.notEqual(next.session.id, s.id);
  assert.equal(next.session.context.report_state, 'zero_sales');
  const [{ source }] = await rows(db, 'select source from public.report_submissions where client_op_id = $1', [s.client_op_id]);
  assert.equal(source, 'conversation');
});

test('Khaya calls are capped per company per month', async () => {
  await db.query(`update public.companies set settings = settings || '{"khaya_monthly_calls": 3}' where id = $1`, [A.companyId]);
  assert.equal(await call(A.agent, `select public.consume_khaya_quota(1) as r`), 2);
  assert.equal(await call(A.agent2, `select public.consume_khaya_quota(2) as r`), 0, 'shared by the company');
  await fails(call(A.agent, `select public.consume_khaya_quota(1) as r`), /quota_exceeded/);
  // Another company has its own allowance.
  assert.equal(await call(B.agent, `select public.consume_khaya_quota(1) as r`), 99);
});
