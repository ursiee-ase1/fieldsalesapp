import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createDb, createUser, as, rows, seedCompany, addMember } from './harness.js';

let db;
let A;
let B;

const one = async (user, sql, params) => (await as(db, user, () => rows(db, sql, params)))[0];
const call = async (user, fn, args = [], casts = []) => {
  const placeholders = args.map((_, i) => `$${i + 1}${casts[i] ?? ''}`).join(', ');
  const row = await one(user, `select public.${fn}(${placeholders}) as r`, args);
  return row.r;
};
// Matches the error code (message) or the human-readable reason (detail).
const fails = (promise, pattern) => assert.rejects(promise, (err) => {
  assert.match(`${err.message} ${err.detail ?? ''}`, pattern);
  return true;
});

const product = (user, name, price) =>
  call(user, 'save_product', [null, name, price], ['::uuid', '', '::numeric']);
const transfer = (user, kind, lines, agent = null, op = randomUUID()) =>
  call(user, 'record_stock_transfer', [op, kind, JSON.stringify(lines), agent], ['::uuid', '', '::jsonb', '::uuid']);
const submit = (user, payload, op = randomUUID(), capturedAt = null) =>
  call(user, 'submit_report', [op, JSON.stringify(payload), capturedAt], ['::uuid', '::jsonb', '::timestamptz']);
const home = (user) => call(user, 'agent_home');
const stockOf = async (user, productId) =>
  ((await home(user)).stock.find((s) => s.product_id === productId) ?? { quantity: 0 }).quantity;
const sale = (productId, quantity, extra = {}) =>
  ({ id: randomUUID(), product_id: productId, quantity, payment_method: 'cash', ...extra });

before(async () => {
  db = await createDb();
  A = await seedCompany(db, 'Alpha Books');
  A.manager = await addMember(db, A.admin, 'manager', 'Mary Manager');
  A.agent = await addMember(db, A.manager, 'agent', 'Kofi Agent');
  A.agent2 = await addMember(db, A.manager, 'agent', 'Ama Agent');
  A.agent3 = await addMember(db, A.manager, 'agent', 'Yaw Agent');
  B = await seedCompany(db, 'Beta Foods');
  B.agent = await addMember(db, B.admin, 'agent', 'Beta Agent');

  A.bookA = await product(A.manager, 'Book A', 50);
  A.bookB = await product(A.manager, 'Book B', 30);
  A.sub = await product(A.admin, 'Subscription', 100);
  B.rice = await product(B.admin, 'Rice', 20);

  await transfer(A.manager, 'receipt', [
    { product_id: A.bookA, quantity: 100 }, { product_id: A.bookB, quantity: 50 }, { product_id: A.sub, quantity: 40 }]);
  await transfer(A.manager, 'issue', [
    { product_id: A.bookA, quantity: 30 }, { product_id: A.bookB, quantity: 20 }, { product_id: A.sub, quantity: 10 }], A.agent);
  await transfer(A.manager, 'issue', [{ product_id: A.bookA, quantity: 10 }], A.agent2);
});

// --- Onboarding hardening ----------------------------------------------------

test('phone-only accounts cannot self-onboard a company', async () => {
  const phoneUser = await createUser(db, { email: null, phone: '233240000001' });
  await db.query('update auth.users set email = null where id = $1', [phoneUser]);
  await fails(call(phoneUser, 'create_company', ['Sneaky Co', 'Some One']), /email_account_required/);
});

// --- Products ----------------------------------------------------------------

test('products: managers create, agents cannot, names are unique per company', async () => {
  await fails(product(A.agent, 'Rogue', 1), /forbidden/);
  await fails(product(A.manager, 'book a', 10), /duplicate key/);
  await product(B.admin, 'Book A', 10); // same name in another company is fine
  const visible = await as(db, A.agent, () => rows(db, 'select name from public.products order by name'));
  assert.deepEqual(visible.map((p) => p.name), ['Book A', 'Book B', 'Subscription']);
});

// --- Ledger --------------------------------------------------------------------

test('issuing stock moves it from the store to the agent', async () => {
  const summary = await as(db, A.manager, () => rows(db, 'select * from public.inventory_summary()'));
  const bookA = summary.find((p) => p.product_id === A.bookA);
  assert.deepEqual([bookA.in_store, bookA.with_agents, bookA.total], [60, 40, 100]);
  assert.equal(await stockOf(A.agent, A.bookA), 30);
  assert.equal(await stockOf(A.agent2, A.bookA), 10);
});

test('managers cannot issue more than the store holds or return more than an agent holds', async () => {
  await fails(transfer(A.manager, 'issue', [{ product_id: A.bookB, quantity: 999 }], A.agent), /insufficient_stock/);
  await fails(transfer(A.manager, 'return', [{ product_id: A.sub, quantity: 999 }], A.agent), /insufficient_stock/);
  await fails(transfer(A.manager, 'issue', [{ product_id: A.bookB, quantity: 0 }], A.agent), /validation_failed/);
});

test('stock operations are idempotent by client_op_id', async () => {
  const op = randomUUID();
  const first = await transfer(A.manager, 'receipt', [{ product_id: A.bookB, quantity: 5 }], null, op);
  const replay = await transfer(A.manager, 'receipt', [{ product_id: A.bookB, quantity: 5 }], null, op);
  assert.deepEqual(replay, first);
  const [{ n }] = await rows(db, 'select count(*)::int as n from public.stock_movements where client_op_id = $1', [op]);
  assert.equal(n, 1);
  await fails(call(A.manager, 'adjust_stock', [op, A.bookB, 1, 'x'], ['::uuid', '::uuid', '::int']),
    /idempotency_key_reused/);
});

test('the ledger is append-only, even for privileged roles', async () => {
  await fails(rows(db, 'update public.stock_movements set quantity = 1'), /append-only/);
  await fails(rows(db, 'delete from public.stock_movements'), /append-only/);
  await fails(as(db, A.admin, () => rows(db, 'update public.stock_balances set quantity = 999')), /permission denied/);
});

test('agents only see their own stock and movements', async () => {
  const balances = await as(db, A.agent2, () => rows(db,
    `select l.agent_id from public.stock_balances b join public.stock_locations l on l.id = b.location_id`));
  assert.ok(balances.length > 0);
  assert.ok(balances.every((b) => b.agent_id === A.agent2));
  await fails(call(A.agent, 'inventory_summary'), /forbidden/);
});

test('write-offs and adjustments require a reason and are audited', async () => {
  await fails(call(A.manager, 'record_write_off', [randomUUID(), 'damage', A.bookA, 1, ''],
    ['::uuid', '', '::uuid', '::int']), /reason is required/);
  await call(A.manager, 'record_write_off', [randomUUID(), 'damage', A.bookA, 2, 'Water damage'],
    ['::uuid', '', '::uuid', '::int']);
  await call(A.manager, 'adjust_stock', [randomUUID(), A.bookA, -1, 'Miscounted delivery'],
    ['::uuid', '::uuid', '::int']);
  const summary = await as(db, A.manager, () => rows(db, 'select * from public.inventory_summary()'));
  assert.equal(summary.find((p) => p.product_id === A.bookA).in_store, 57);
  const audit = await as(db, A.admin, () => rows(db,
    `select action from public.audit_log where action in ('stock.damage', 'stock.adjusted')`));
  assert.equal(audit.length, 2);
});

// --- Daily reports -------------------------------------------------------------

test('no report, zero-sales report and report with sales are distinguishable', async () => {
  assert.equal((await home(A.agent3)).report.state, 'none');

  await fails(submit(A.agent3, { comments: 'quiet day' }), /record your sales/);
  await fails(submit(A.agent3, { no_sales: true, sales: [sale(A.bookA, 1)] }), /cannot declare no sales/);

  const zero = await submit(A.agent3, { no_sales: true, comments: 'Rain all day' });
  assert.equal(zero.state, 'zero_sales');
  assert.equal((await home(A.agent3)).report.state, 'zero_sales');
});

test('sales are priced and totalled by the server and reduce agent stock', async () => {
  const before = await stockOf(A.agent, A.bookA);
  const result = await submit(A.agent, {
    sales: [sale(A.bookA, 4), sale(A.sub, 2, { payment_method: 'momo', unit_price: 90 })],
    stock_counts: [],
  });
  assert.equal(result.state, 'with_sales');
  const h = await home(A.agent);
  assert.deepEqual(h.sales, { count: 2, units: 6, amount: 380 }); // 4×50 + 2×90
  assert.equal(await stockOf(A.agent, A.bookA), before - 4);

  const [s] = await as(db, A.manager, () => rows(db,
    `select price_override, price_flagged, catalog_price::float from public.sales where unit_price = 90`));
  assert.deepEqual(s, { price_override: true, price_flagged: false, catalog_price: 100 });
});

test('big discounts are flagged; prices and payment methods are validated', async () => {
  await submit(A.agent, { sales: [sale(A.bookB, 1, { unit_price: 10 })] });
  const [s] = await as(db, A.manager, () => rows(db, 'select price_flagged from public.sales where unit_price = 10'));
  assert.equal(s.price_flagged, true);
  await fails(submit(A.agent, { sales: [sale(A.bookB, 1, { payment_method: 'credit' })] }), /cash or momo/);
  await fails(submit(A.agent, { sales: [sale(A.bookB, -2)] }), /positive whole number/);
});

test('replaying a submission never duplicates sales; reusing a sale id is rejected', async () => {
  const op = randomUUID();
  const payload = { sales: [sale(A.bookB, 1)] };
  const first = await submit(A.agent, payload, op);
  const replay = await submit(A.agent, payload, op);
  assert.deepEqual(replay, first);
  const [{ n }] = await rows(db, 'select count(*)::int as n from public.sales where id = $1', [payload.sales[0].id]);
  assert.equal(n, 1);
  await fails(submit(A.agent, payload), /duplicate_sale/);
});

test('overselling is accepted and flagged, not dropped', async () => {
  const held = await stockOf(A.agent2, A.bookA);
  const s = sale(A.bookA, held + 2);
  await submit(A.agent2, { sales: [s] });
  assert.equal(await stockOf(A.agent2, A.bookA), -2);
  const [row] = await as(db, A.manager, () => rows(db, 'select stock_flagged from public.sales where id = $1', [s.id]));
  assert.equal(row.stock_flagged, true);
});

test('agents cannot sell products of another company', async () => {
  await fails(submit(B.agent, { sales: [sale(A.bookA, 1)] }), /unknown product/);
});

// --- Stock counts and discrepancies ---------------------------------------------

test('a matching count raises nothing; a mismatch opens a discrepancy', async () => {
  const expected = await stockOf(A.agent, A.bookB);
  const ok = await submit(A.agent, { stock_counts: [{ product_id: A.bookB, quantity: expected }] });
  assert.deepEqual(ok.discrepancies, []);

  const short = await submit(A.agent, { stock_counts: [{ product_id: A.sub, quantity: 5 }] });
  assert.equal(short.discrepancies.length, 1);
  assert.equal(short.discrepancies[0].expected, 8);
  const open = await as(db, A.manager, () => rows(db, `select * from public.list_discrepancies('open')`));
  assert.ok(open.some((d) => d.product_name === 'Subscription' && d.difference === -3));
  // The count never overwrote the ledger.
  assert.equal(await stockOf(A.agent, A.sub), 8);
});

test('a recount that matches closes the discrepancy', async () => {
  await submit(A.agent, { stock_counts: [{ product_id: A.sub, quantity: 8 }] });
  const open = await as(db, A.manager, () => rows(db, `select * from public.list_discrepancies('open')`));
  assert.ok(!open.some((d) => d.product_name === 'Subscription' && d.agent_name === 'Kofi Agent'));
});

test('managers resolve shortages by write-off or adjustment', async () => {
  await submit(A.agent, { stock_counts: [{ product_id: A.sub, quantity: 6 }] });
  const [d] = await as(db, A.manager, () => rows(db,
    `select id from public.list_discrepancies('open') where product_name = 'Subscription'`));
  await fails(call(A.agent, 'resolve_discrepancy', [d.id, 'write_off'], ['::uuid']), /forbidden/);
  await call(A.manager, 'resolve_discrepancy', [d.id, 'write_off', 'Two copies lost'], ['::uuid']);
  assert.equal(await stockOf(A.agent, A.sub), 6);
  await fails(call(A.manager, 'resolve_discrepancy', [d.id, 'adjust'], ['::uuid']), /already_resolved/);

  // Surplus: adjust the ledger up to the counted quantity.
  await submit(A.agent2, { stock_counts: [{ product_id: A.bookA, quantity: 1 }] });
  const [d2] = await as(db, A.manager, () => rows(db,
    `select id from public.list_discrepancies('open') where agent_name = 'Ama Agent'`));
  await call(A.manager, 'resolve_discrepancy', [d2.id, 'adjust', 'Found returned copies'], ['::uuid']);
  assert.equal(await stockOf(A.agent2, A.bookA), 1);
});

test('missing counts are reported for products the agent holds', async () => {
  const r = await submit(A.agent, { stock_counts: [] });
  assert.ok(r.missing_counts >= 1);
});

// --- Business date ---------------------------------------------------------------

test('late offline syncs use the capture date within 72 hours, otherwise server date', async () => {
  const yesterday = new Date(Date.now() - 30 * 3600 * 1000).toISOString();
  const late = await submit(A.agent3, { no_sales: true }, randomUUID(), yesterday);
  assert.equal(late.late_sync, true);
  assert.notEqual(late.business_date, (await home(A.agent3)).business_date);

  const tooOld = new Date(Date.now() - 5 * 24 * 3600 * 1000).toISOString();
  const clamped = await submit(A.agent3, { no_sales: true }, randomUUID(), tooOld);
  assert.equal(clamped.late_sync, false);
  assert.equal(clamped.business_date, (await home(A.agent3)).business_date);

  const future = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
  const fromFuture = await submit(A.agent3, { no_sales: true }, randomUUID(), future);
  assert.equal(fromFuture.business_date, (await home(A.agent3)).business_date);
});

// --- Voids -------------------------------------------------------------------------

test('voiding a sale restores stock and totals; agents cannot void', async () => {
  const s = sale(A.bookB, 3);
  await submit(A.agent, { sales: [s] });
  const stockBefore = await stockOf(A.agent, A.bookB);
  const amountBefore = (await home(A.agent)).sales.amount;

  await fails(call(A.agent, 'void_sale', [s.id, 'mistake'], ['::uuid']), /forbidden/);
  await fails(call(A.manager, 'void_sale', [s.id, ''], ['::uuid']), /reason is required/);
  await call(A.manager, 'void_sale', [s.id, 'Entered twice'], ['::uuid']);
  assert.equal(await stockOf(A.agent, A.bookB), stockBefore + 3);
  assert.equal((await home(A.agent)).sales.amount, amountBefore - 90);
  await fails(call(A.manager, 'void_sale', [s.id, 'again'], ['::uuid']), /already_voided/);
});

// --- Customers ----------------------------------------------------------------------

test('phone numbers need the customer\'s consent', async () => {
  await fails(submit(A.agent, {
    customers: [{ ref: 'c1', full_name: 'Esi Mensah', phone: '024 555 0001' }],
    sales: [sale(A.bookA, 1, { customer_ref: 'c1' })],
  }), /must agree/);
});

test('agents see customers they work with, and not other agents\' customers', async () => {
  await submit(A.agent, {
    customers: [{ ref: 'c1', full_name: 'Ama Owusu', phone: '024 555 0002', consent: true }],
    sales: [sale(A.bookA, 1, { customer_ref: 'c1' })],
  });
  const mine = await as(db, A.agent, () => rows(db, `select full_name from public.list_customers(null)`));
  assert.ok(mine.some((c) => c.full_name === 'Ama Owusu'));
  const theirs = await as(db, A.agent2, () => rows(db, `select full_name from public.list_customers(null)`));
  assert.ok(!theirs.some((c) => c.full_name === 'Ama Owusu'));
  const fromB = await as(db, B.admin, () => rows(db, `select full_name from public.list_customers(null)`));
  assert.ok(!fromB.some((c) => c.full_name === 'Ama Owusu'));
});

test('customer search matches names and phone digits only', async () => {
  const byName = await as(db, A.manager, () => rows(db, `select full_name from public.list_customers('owusu')`));
  assert.deepEqual(byName.map((c) => c.full_name), ['Ama Owusu']);
  const byPhone = await as(db, A.manager, () => rows(db, `select full_name from public.list_customers('5550002')`));
  assert.deepEqual(byPhone.map((c) => c.full_name), ['Ama Owusu']);
  const none = await as(db, A.manager, () => rows(db, `select full_name from public.list_customers('zzz')`));
  assert.equal(none.length, 0);
});

test('phone lookup reveals only a first name and masked number', async () => {
  const found = await as(db, A.agent2, () => rows(db, `select * from public.find_customer_by_phone('0245550002')`));
  assert.equal(found.length, 1);
  assert.equal(found[0].first_name, 'Ama');
  assert.equal(found[0].masked_phone, '024 *** **02');
  const fromB = await as(db, B.agent, () => rows(db, `select * from public.find_customer_by_phone('0245550002')`));
  assert.equal(fromB.length, 0);
});

test('a confirmed match links the sale to the existing customer instead of creating one', async () => {
  const [match] = await as(db, A.agent2, () => rows(db, `select * from public.find_customer_by_phone('0245550002')`));
  await submit(A.agent2, {
    customers: [{ ref: 'c1', customer_id: match.customer_id }],
    sales: [sale(A.bookA, 1, { customer_ref: 'c1' })],
  });
  const visible = await as(db, A.agent2, () => rows(db, `select id from public.list_customers(null)`));
  assert.ok(visible.some((c) => c.id === match.customer_id));
  const [{ n }] = await rows(db, `select count(*)::int as n from public.customers where phone_e164 = '+233245550002'`);
  assert.equal(n, 1);
});

test('an unconfirmed duplicate phone creates a review; managers decide, nothing auto-merges', async () => {
  await transfer(A.manager, 'issue', [{ product_id: A.bookA, quantity: 5 }], A.agent3);
  const r = await submit(A.agent3, {
    customers: [{ ref: 'c1', full_name: 'Ama O.', phone: '+233245550002', consent: true }],
    sales: [sale(A.bookA, 1, { customer_ref: 'c1' })],
  });
  assert.equal(r.match_reviews.length, 1);
  const [{ n }] = await rows(db, `select count(*)::int as n from public.customers where phone_e164 = '+233245550002'`);
  assert.equal(n, 2);

  const [review] = await as(db, A.manager, () => rows(db, 'select * from public.list_match_reviews()'));
  assert.equal(review.candidate_name, 'Ama Owusu');
  await fails(call(A.agent3, 'resolve_customer_match', [review.id, true], ['::uuid']), /forbidden/);
  const kept = await call(A.manager, 'resolve_customer_match', [review.id, true], ['::uuid']);
  assert.equal(kept, review.candidate_customer_id);

  const [{ m }] = await rows(db,
    `select count(*)::int as m from public.sales where customer_id = $1`, [review.candidate_customer_id]);
  assert.equal(m, 3); // agent, agent2 and the merged agent3 sale
  const after = await as(db, A.manager, () => rows(db, `select full_name from public.list_customers('ama')`));
  assert.deepEqual(after.map((c) => c.full_name), ['Ama Owusu']);
});

test('"not the same person" skips the review', async () => {
  const [match] = await as(db, A.agent, () => rows(db, `select * from public.find_customer_by_phone('0245550002')`));
  const r = await submit(A.agent, {
    customers: [{ ref: 'c1', full_name: 'Kwame Owusu', phone: '0245550002', consent: true,
                  not_same_as: [match.customer_id] }],
    prospects_count: 3,
  });
  assert.equal(r.match_reviews.length, 0);
});

test('managers edit customers with a version check', async () => {
  const [c] = await as(db, A.manager, () => rows(db, `select id, version from public.list_customers('Ama Owusu')`));
  const v2 = await call(A.manager, 'update_customer',
    [c.id, c.version, 'Ama Owusu', '0245550002', 'Kumasi', 'Prefers mornings', true],
    ['::uuid', '::int', '', '', '', '', '::boolean']);
  assert.equal(v2, c.version + 1);
  await fails(call(A.manager, 'update_customer',
    [c.id, c.version, 'Stale Edit', null, null, null, false], ['::uuid', '::int', '', '', '', '', '::boolean']),
  /conflict/);
  await fails(call(A.agent, 'update_customer',
    [c.id, v2, 'X Y', null, null, null, false], ['::uuid', '::int', '', '', '', '', '::boolean']), /forbidden/);
});

test('phone lookups are rate limited', async () => {
  const user = A.agent3;
  let error;
  for (let i = 0; i < 31 && !error; i++) {
    await as(db, user, () => rows(db, `select * from public.find_customer_by_phone('0245550099')`)).catch((e) => { error = e; });
  }
  assert.match(String(error), /rate_limited/);
});

// --- Follow-ups -----------------------------------------------------------------------

test('follow-ups appear on the agent home and close with an outcome', async () => {
  const tomorrow = new Date(Date.now() + 24 * 3600 * 1000).toISOString().slice(0, 10);
  await submit(A.agent, {
    customers: [{ ref: 'p1', full_name: 'Yaa Boateng', phone: '0205550003', consent: true }],
    follow_ups: [{ customer_ref: 'p1', due_date: tomorrow, note: 'Come back with Book B' }],
  });
  const h = await home(A.agent);
  const f = h.follow_ups.find((x) => x.customer_name === 'Yaa Boateng');
  assert.ok(f);
  await fails(submit(A.agent2, { follow_up_outcomes: [{ follow_up_id: f.id, outcome: 'sold' }] }), /unknown follow-up/);
  await submit(A.agent, { follow_up_outcomes: [{ follow_up_id: f.id, outcome: 'contacted' }] });
  assert.ok(!(await home(A.agent)).follow_ups.some((x) => x.id === f.id));

  await fails(submit(A.agent, {
    customers: [{ ref: 'p2', full_name: 'Late Person' }],
    follow_ups: [{ customer_ref: 'p2', due_date: '2020-01-01' }],
  }), /within 90 days/);
});

// --- Targets -----------------------------------------------------------------------------

test('the most specific daily target wins, with progress from today\'s sales', async () => {
  await call(A.manager, 'set_daily_target', ['company', 'units', 20]);
  await call(A.manager, 'set_daily_target', ['agent', 'units', 10, null, A.agent3],
    ['', '', '::numeric', '::date', '::uuid']);
  await call(A.manager, 'set_daily_target', ['company', 'amount', 500, null, null, null, A.bookA],
    ['', '', '::numeric', '::date', '::uuid', '::uuid', '::uuid']);
  await fails(call(A.agent, 'set_daily_target', ['company', 'units', 5]), /forbidden/);

  const agent3 = (await home(A.agent3)).targets;
  const units = agent3.find((t) => t.metric === 'units' && t.product_id === null);
  assert.equal(units.scope, 'agent');
  assert.equal(Number(units.target), 10);
  assert.equal(Number(units.achieved), 1); // the Book A sale merged above
  assert.equal(Number(units.remaining), 9);
  assert.equal(Number(units.progress_pct), 10);

  const agent2 = (await home(A.agent2)).targets;
  assert.equal(agent2.find((t) => t.metric === 'units' && t.product_id === null).scope, 'company');
  assert.ok(agent2.some((t) => t.metric === 'amount' && t.product_name === 'Book A'));
});

test('setting a target again replaces it instead of stacking', async () => {
  await call(A.manager, 'set_daily_target', ['company', 'units', 25]);
  const list = await as(db, A.manager, () => rows(db,
    `select value::float from public.list_targets() where scope = 'company' and metric = 'units'`));
  assert.deepEqual(list, [{ value: 25 }]);
});

// --- Cross-tenant ---------------------------------------------------------------------------

test('another company cannot touch this company\'s agents, sales or discrepancies', async () => {
  await fails(transfer(B.admin, 'issue', [{ product_id: B.rice, quantity: 1 }], A.agent), /not_found|insufficient/);
  const sales = await as(db, B.admin, () => rows(db, `select * from public.list_sales('2000-01-01', '2100-01-01')`));
  assert.equal(sales.length, 0);
  const disc = await as(db, B.admin, () => rows(db, `select * from public.list_discrepancies(null)`));
  assert.equal(disc.length, 0);
  const [s] = await rows(db, 'select id from public.sales limit 1');
  await fails(call(B.admin, 'void_sale', [s.id, 'evil'], ['::uuid']), /not_found/);
  const raw = await as(db, B.agent, () => rows(db, 'select id from public.sales'));
  assert.equal(raw.length, 0);
});
