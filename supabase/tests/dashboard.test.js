import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createDb, as, rows, seedCompany, addMember } from './harness.js';

let db;
let A;
let B;
let today;

const call = async (user, sql, params) => (await as(db, user, () => rows(db, sql, params)))[0]?.r;
const fails = (promise, pattern) => assert.rejects(promise, (err) => {
  assert.match(`${err.message} ${err.detail ?? ''}`, pattern);
  return true;
});
const sale = (product_id, quantity, extra = {}) =>
  ({ id: randomUUID(), product_id, quantity, payment_method: 'cash', ...extra });
const submit = (user, payload) =>
  call(user, `select public.submit_report($1, $2::jsonb) as r`, [randomUUID(), JSON.stringify(payload)]);

before(async () => {
  db = await createDb();
  A = await seedCompany(db, 'Alpha Books');
  A.manager = await addMember(db, A.admin, 'manager', 'Mary Manager');
  A.kofi = await addMember(db, A.manager, 'agent', 'Kofi Mensah');
  A.ama = await addMember(db, A.manager, 'agent', 'Ama Owusu');
  A.yaw = await addMember(db, A.manager, 'agent', 'Yaw Boateng');
  B = await seedCompany(db, 'Beta Foods');
  B.agent = await addMember(db, B.admin, 'agent', 'Beta Agent');

  A.bookA = await call(A.manager, `select public.save_product(null, 'Book A', 50) as r`);
  A.bookB = await call(A.manager, `select public.save_product(null, 'Book B', 30) as r`);
  B.rice = await call(B.admin, `select public.save_product(null, 'Rice', 20) as r`);
  await call(A.manager, `select public.record_stock_transfer($1, 'receipt', $2::jsonb) as r`,
    [randomUUID(), JSON.stringify([{ product_id: A.bookA, quantity: 100 }, { product_id: A.bookB, quantity: 100 }])]);
  for (const agent of [A.kofi, A.ama]) {
    await call(A.manager, `select public.record_stock_transfer($1, 'issue', $2::jsonb, $3) as r`,
      [randomUUID(), JSON.stringify([{ product_id: A.bookA, quantity: 20 }, { product_id: A.bookB, quantity: 20 }]), agent]);
  }

  // Kofi: 3 × Book A + 2 × Book B, with a new customer. Ama: zero sales. Yaw: no report.
  await submit(A.kofi, {
    customers: [{ ref: 'c1', full_name: 'Esi Asante', phone: '0244000001', consent: true }],
    sales: [sale(A.bookA, 3, { customer_ref: 'c1' }), sale(A.bookB, 2)],
  });
  await submit(A.ama, { no_sales: true });
  await call(A.manager, `select public.set_daily_target('company', 'units', 10) as r`);
  await submit(B.agent, { sales: [sale(B.rice, 7)] });
  today = (await call(A.manager, 'select public.dashboard_overview() as r')).date;
});

test('overview: totals, and every agent\'s report state (none / zero / with sales)', async () => {
  const o = await call(A.manager, 'select public.dashboard_overview() as r');
  assert.deepEqual(o.today, { sales_count: 2, units: 5, amount: 210 });
  assert.equal(o.week.amount, 210);
  assert.equal(o.week_by_day.length, 7);
  assert.equal(o.week_by_day[6].amount, 210);

  const byName = Object.fromEntries(o.agents.map((a) => [a.name, a]));
  assert.equal(byName['Kofi Mensah'].state, 'with_sales');
  assert.equal(byName['Ama Owusu'].state, 'zero_sales');
  assert.equal(byName['Yaw Boateng'].state, 'none');
  assert.equal(o.agents[0].name, 'Yaw Boateng', 'agents who have not reported come first');
  assert.ok(byName['Kofi Mensah'].last_report_at);
  assert.equal(byName['Yaw Boateng'].last_report_at, null);

  const kofiTarget = byName['Kofi Mensah'].targets[0];
  assert.equal(Number(kofiTarget.target), 10);
  assert.equal(Number(kofiTarget.achieved), 5);

  assert.equal(o.customers.new_today, 1);
  assert.equal(o.stock.in_store, 120);
  assert.equal(o.stock.with_agents, 75); // 80 issued − 5 sold
});

test('overview never includes another company', async () => {
  const o = await call(B.admin, 'select public.dashboard_overview() as r');
  assert.deepEqual(o.today, { sales_count: 1, units: 7, amount: 140 });
  assert.deepEqual(o.agents.map((a) => a.name), ['Beta Agent']);
});

test('agents cannot see dashboards, reports or transcripts', async () => {
  await fails(call(A.kofi, 'select public.dashboard_overview() as r'), /forbidden/);
  await fails(call(A.kofi, `select public.sales_report($1, $1) as r`, [today]), /forbidden/);
  await fails(call(A.kofi, `select count(*) as r from public.list_conversations($1, $1)`, [today]), /forbidden/);
});

test('sales report: totals, by product, by agent (incl. activity), by day', async () => {
  const r = await call(A.manager, `select public.sales_report($1::date - 6, $1) as r`, [today]);
  assert.equal(r.days, 7);
  assert.deepEqual(r.totals, { sales_count: 2, units: 5, amount: 210 });
  assert.deepEqual(r.by_product.map((p) => [p.name, p.units, p.amount]), [['Book A', 3, 150], ['Book B', 2, 60]]);

  const agents = Object.fromEntries(r.by_agent.map((a) => [a.name, a]));
  assert.equal(agents['Kofi Mensah'].amount, 210);
  assert.equal(agents['Ama Owusu'].days_reported, 1);
  assert.equal(agents['Ama Owusu'].zero_sale_days, 1);
  assert.equal(agents['Yaw Boateng'].days_reported, 0);
  assert.equal(r.by_day.length, 7);
  assert.equal(r.customers_by_day.at(-1).count, 1);
});

test('sales report filters by product and agent', async () => {
  const onlyB = await call(A.manager, `select public.sales_report($1, $1, null, $2::uuid[]) as r`, [today, [A.bookB]]);
  assert.deepEqual(onlyB.totals, { sales_count: 1, units: 2, amount: 60 });
  // A zero-sales report still counts as activity under a product filter.
  assert.equal(onlyB.by_agent.find((a) => a.name === 'Ama Owusu').days_reported, 1);

  const onlyAma = await call(A.manager, `select public.sales_report($1, $1, $2::uuid[]) as r`, [today, [A.ama]]);
  assert.deepEqual(onlyAma.totals, { sales_count: 0, units: 0, amount: 0 });
  assert.deepEqual(onlyAma.by_agent.map((a) => a.name), ['Ama Owusu']);
});

test('voided sales drop out of reports', async () => {
  const [s] = await rows(db, `select id from public.sales where product_id = $1`, [A.bookB]);
  await call(A.manager, `select public.void_sale($1, 'Entered twice') as r`, [s.id]);
  const r = await call(A.manager, `select public.sales_report($1, $1) as r`, [today]);
  assert.deepEqual(r.totals, { sales_count: 1, units: 3, amount: 150 });
});

test('report ranges are validated', async () => {
  await fails(call(A.manager, `select public.sales_report($1, $1::date - 1) as r`, [today]), /valid date range/);
  await fails(call(A.manager, `select public.sales_report($1::date - 400, $1) as r`, [today]), /at most a year/);
});

test('managers can read conversation transcripts of their company only', async () => {
  const started = await call(A.kofi, `select public.assistant_start('app_text', 'tw') as r`);
  await call(A.kofi, `select public.assistant_save($1, $2, '{}'::jsonb, 'active',
      '[{"role":"assistant","text":"Akwaaba"},{"role":"agent","text":"Matɔn nwoma","english_text":"I sold books","language":"tw"}]'::jsonb) as r`,
    [started.session.id, started.session.draft_version]);

  const list = await as(db, A.manager, () => rows(db, 'select * from public.list_conversations($1, $1)', [today]));
  assert.equal(list.length, 1);
  assert.equal(list[0].agent_name, 'Kofi Mensah');
  assert.equal(list[0].turns, 2);

  const transcript = await as(db, A.manager, () =>
    rows(db, 'select * from public.conversation_transcript($1)', [started.session.id]));
  assert.deepEqual(transcript.map((t) => [t.role, t.text, t.english_text]),
    [['assistant', 'Akwaaba', null], ['agent', 'Matɔn nwoma', 'I sold books']]);

  await fails(as(db, B.admin, () => rows(db, 'select * from public.conversation_transcript($1)', [started.session.id])),
    /not_found/);
});

test('company settings: admins change known keys only, validated and audited', async () => {
  const s = await call(A.manager, 'select public.company_settings() as r');
  assert.deepEqual(s, { twi_voice_enabled: false, khaya_monthly_calls: 100, max_discount_pct: 20, khaya_calls_used_this_month: 0 });

  await fails(call(A.manager, `select public.update_company_settings('{"twi_voice_enabled": true}') as r`), /forbidden/);
  await fails(call(A.admin, `select public.update_company_settings('{"plan": "free"}') as r`), /unknown setting/);
  await fails(call(A.admin, `select public.update_company_settings('{"max_discount_pct": 150}') as r`), /between 0 and 100/);
  await fails(call(A.admin, `select public.update_company_settings('{"khaya_monthly_calls": 2.5}') as r`), /whole number/);

  const updated = await call(A.admin,
    `select public.update_company_settings('{"twi_voice_enabled": true, "khaya_monthly_calls": 500}') as r`);
  assert.equal(updated.twi_voice_enabled, true);
  assert.equal(updated.khaya_monthly_calls, 500);

  // The assistant sees the switch on its next start.
  const ctx = (await call(A.ama, `select public.assistant_start('app_voice', 'tw') as r`)).session.context;
  assert.equal(ctx.twi_voice_enabled, true);

  const [audit] = await rows(db, `select before, after from public.audit_log where action = 'company.settings_updated'`);
  assert.equal(audit.after.twi_voice_enabled, true);

  const fromB = await call(B.admin, 'select public.company_settings() as r');
  assert.equal(fromB.twi_voice_enabled, false);
});
