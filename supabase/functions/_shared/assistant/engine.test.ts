import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { emptyDraft, toPayload } from './draft.ts';
import { speakPhone } from './agenda.ts';
import { openingTurn, parseExtraction, runTurn } from './engine.ts';
import type { TurnDeps, TurnState } from './engine.ts';
import type { AssistantContext, Draft, Operation, PhoneMatch } from './types.ts';
import type { LlmProvider } from '../llm/types.ts';

const ctx: AssistantContext = {
  today: '2026-11-04',
  weekday: 'Wednesday',
  agent_first_name: 'Kofi',
  report_state: 'none',
  twi_voice_enabled: false,
  products: [
    { id: 'p-a', name: 'Book A', aliases: ['nwoma A'], unit_price: 50 },
    { id: 'p-sub', name: 'Subscription', aliases: [], unit_price: 100 },
  ],
  held: [
    { product_id: 'p-a', name: 'Book A', quantity: 9, last_count: { date: '2026-11-03', quantity: 5 } },
  ],
  follow_ups_due: [],
};

const op = (o: Partial<Operation> & { op: Operation['op'] }): Operation => ({
  ref: null, product_id: null, quantity: null, unit_price: null, payment_method: null, customer_ref: null,
  full_name: null, phone: null, consent: null, location: null, same_person: null, match_customer_id: null,
  due_date: null, note: null, follow_up_id: null, outcome: null, count: null, text: null, topic: null, ...o,
});

/** Scripted LLM: returns the queued extraction; phrasing echoes the suggested wording. */
function scripted(extractions: unknown[], phrase: 'echo' | 'fail' = 'echo'): LlmProvider & { calls: number } {
  const queue = [...extractions];
  return {
    name: 'fake',
    calls: 0,
    async generateJson() {
      this.calls++;
      return { value: queue.shift(), usage: { input_tokens: 100, output_tokens: 20 } };
    },
    async generateText(_s: string, user: string) {
      if (phrase === 'fail') throw new Error('down');
      return { text: `PHRASED(${JSON.parse(user).next_question.kind})`, usage: { input_tokens: 50, output_tokens: 10 } };
    },
  };
}

function deps(llm: LlmProvider, matches: PhoneMatch[] = []): TurnDeps {
  return { llm, findByPhone: async () => matches, newId: randomUUID };
}

async function converse(llm: LlmProvider, messages: string[], start: Partial<TurnState> = {}, matches: PhoneMatch[] = []) {
  let state: TurnState = { draft: emptyDraft(), status: 'active', ctx, recentTurns: [], ...start };
  const opening = openingTurn(state, false);
  state = { ...state, draft: opening.draft, status: opening.status };
  const outcomes = [];
  for (const m of messages) {
    const out = await runTurn(deps(llm, matches), state, m);
    outcomes.push(out);
    state = { ...state, draft: out.draft, status: out.status };
  }
  return { opening, outcomes, state };
}

test('opens with a greeting and the first required question', () => {
  const o = openingTurn({ draft: emptyDraft(), status: 'active', ctx }, false);
  assert.equal(o.reply, "Hello, Kofi! Let's record your field activities. How many sales have you made today?");
  assert.equal(o.draft.last_question?.kind, 'sales');
});

test('the example conversation: details given early are not asked again', async () => {
  const llm = scripted([
    { intent: 'continue', operations: [
      op({ op: 'add_sale', product_id: 'p-a', quantity: 4, payment_method: 'cash' }),
      op({ op: 'add_sale', product_id: 'Subscription', quantity: 2, payment_method: 'momo' }),
      op({ op: 'set_stock_count', product_id: 'p-a', count: 5 }),
    ] },
    { intent: 'continue', operations: [op({ op: 'set_prospects', count: 5 })] },
    { intent: 'continue', operations: [
      op({ op: 'add_customer', ref: 'new1', full_name: 'Ama Mensah', phone: '024 123 4567', consent: true }),
      op({ op: 'add_follow_up', customer_ref: 'new1', due_date: '2026-11-05' }),
    ] },
  ]);
  const { outcomes } = await converse(llm, [
    'Four books and two subscriptions, one momo... I have five Book A left',
    'Five people',
    'Ama Mensah asked me to come tomorrow, her number is 0241234567',
  ]);
  // Stock and payment were given, so the next question skips them and asks about prospects.
  assert.equal(outcomes[0].reply, 'PHRASED(prospects)');
  assert.equal(outcomes[1].reply, 'PHRASED(follow_up_requests)');
  // New customer details are read back word for word, digit by digit.
  assert.equal(outcomes[2].reply,
    "Got it. Let me check I have this right: the customer's name is Ama Mensah, phone number 0 2 4, 1 2 3, 4 5 6 7. Is that correct?");
});

test('the assistant never invents a payment method: it asks', async () => {
  const llm = scripted([{ intent: 'continue', operations: [op({ op: 'add_sale', product_id: 'p-a', quantity: 2 })] }]);
  const { outcomes } = await converse(llm, ['I sold two books']);
  assert.equal(outcomes[0].draft.sales[0].payment_method, null);
  assert.equal(outcomes[0].reply, 'PHRASED(payment)');
});

test('unknown products and bad numbers become questions, not data', async () => {
  const llm = scripted([{ intent: 'continue', operations: [
    op({ op: 'add_sale', product_id: 'magazine', quantity: 3, payment_method: 'cash' }),
    op({ op: 'add_customer', full_name: 'Yaw', phone: '12345' }),
  ] }], 'fail');
  const { outcomes } = await converse(llm, ['3 magazines, and Yaw on 12345']);
  const out = outcomes[0];
  assert.equal(out.draft.sales.length, 0);
  assert.equal(out.draft.customers[0].phone, null);
  assert.match(out.reply, /"magazine" is not one of your products \(Book A, Subscription\)/);
  assert.match(out.reply, /doesn't look like a Ghana phone number/);
});

test('a known phone number asks whether it is the same customer, and links on yes', async () => {
  const matches = [{ customer_id: 'cust-ama', first_name: 'Ama', masked_phone: '024 *** **67' }];
  const llm = scripted([
    { intent: 'continue', operations: [
      op({ op: 'add_sale', product_id: 'p-a', quantity: 1, payment_method: 'cash', customer_ref: 'new1' }),
      op({ op: 'add_customer', ref: 'new1', full_name: 'Ama', phone: '0241234567', consent: true }),
    ] },
    { intent: 'continue', operations: [op({ op: 'confirm_customer_details', ref: 'c1' })] },
    { intent: 'continue', operations: [op({ op: 'answer_customer_match', ref: 'c1', same_person: true })] },
  ]);
  const { outcomes } = await converse(llm, ['Sold a book to Ama, 0241234567', 'Yes', 'Yes, same person'], {}, matches);
  assert.equal(outcomes[1].reply, 'This phone number is already associated with Ama. Is this the same customer?');
  const payload = toPayload(outcomes[2].draft) as { customers: unknown[]; sales: { customer_ref?: string }[] };
  assert.deepEqual(payload.customers, [{ ref: 'c1', customer_id: 'cust-ama' }]);
  assert.equal(payload.sales[0].customer_ref, 'c1');
});

test('"not the same person" keeps a new customer and tells the server', async () => {
  const matches = [{ customer_id: 'cust-ama', first_name: 'Ama', masked_phone: '024 *** **67' }];
  const llm = scripted([
    { intent: 'continue', operations: [op({ op: 'add_customer', full_name: 'Ama Owusu', phone: '0241234567', consent: true })] },
    { intent: 'continue', operations: [op({ op: 'confirm_customer_details', ref: 'c1' })] },
    { intent: 'continue', operations: [op({ op: 'answer_customer_match', ref: 'c1', same_person: false })] },
  ]);
  const { outcomes } = await converse(llm, ['a', 'b', 'c'], {}, matches);
  const c = (toPayload(outcomes[2].draft).customers as Record<string, unknown>[])[0];
  assert.equal(c.full_name, 'Ama Owusu');
  assert.deepEqual(c.not_same_as, ['cust-ama']);
});

test('no consent means the phone number is dropped', async () => {
  const llm = scripted([
    { intent: 'continue', operations: [op({ op: 'add_customer', full_name: 'Kwame Asare', phone: '0201112222' })] },
    { intent: 'continue', operations: [op({ op: 'confirm_customer_details', ref: 'c1' })] },
    { intent: 'continue', operations: [op({ op: 'update_customer', ref: 'c1', consent: false })] },
  ]);
  const { outcomes } = await converse(llm, ['a', 'yes', 'no he did not agree']);
  assert.equal(outcomes[1].reply, 'Did Kwame Asare agree for us to keep their phone number?');
  const c = (toPayload(outcomes[2].draft).customers as Record<string, unknown>[])[0];
  assert.equal(c.phone, undefined);
  assert.equal(c.consent, false);
});

test('corrections change the draft instead of adding to it', async () => {
  const llm = scripted([
    { intent: 'continue', operations: [op({ op: 'add_sale', product_id: 'p-a', quantity: 6, payment_method: 'cash' })] },
    { intent: 'continue', operations: [op({ op: 'update_sale', ref: 's1', quantity: 5 })] },
  ]);
  const { state } = await converse(llm, ['six books cash', 'sorry, it was five']);
  assert.equal(state.draft.sales.length, 1);
  assert.equal(state.draft.sales[0].quantity, 5);
});

test('optional questions are asked once and can be skipped', async () => {
  const llm = scripted([
    { intent: 'continue', operations: [op({ op: 'declare_no_sales' }), op({ op: 'set_stock_count', product_id: 'p-a', count: 9 })] },
    { intent: 'continue', operations: [op({ op: 'skip', topic: 'prospects' })] },
    { intent: 'continue', operations: [] },
  ]);
  const { outcomes } = await converse(llm, ['No sales today, 9 left', 'skip that', 'no']);
  assert.equal(outcomes[0].reply, 'PHRASED(prospects)');
  assert.equal(outcomes[1].reply, 'PHRASED(comments)');
  assert.equal(outcomes[2].action, 'summary', 'comments asked once; then the summary');
  assert.equal(outcomes[2].status, 'awaiting_confirmation');
});

test('zero sales is a normal report, summarised without judgement', async () => {
  const llm = scripted([{ intent: 'finish', operations: [op({ op: 'declare_no_sales' }), op({ op: 'set_stock_count', product_id: 'p-a', count: 9 })] }]);
  const { outcomes } = await converse(llm, ["No sales today, 9 books left, that's all"]);
  assert.equal(outcomes[0].action, 'summary');
  assert.deepEqual(outcomes[0].summary, ['No sales today.', 'Stock left: Book A 9.']);
  assert.deepEqual(toPayload(outcomes[0].draft).stock_counts, [{ product_id: 'p-a', quantity: 9 }]);
  assert.equal(toPayload(outcomes[0].draft).no_sales, true);
});

test('finishing early still requires the essentials', async () => {
  const llm = scripted([{ intent: 'finish', operations: [] }], 'fail');
  const { outcomes } = await converse(llm, ["That's all"]);
  assert.equal(outcomes[0].action, 'ask');
  assert.match(outcomes[0].reply, /Before I can send your report.*How many sales have you made today\?/);
});

test('uncounted stock may be skipped, and the summary says so', async () => {
  const llm = scripted([{ intent: 'finish', operations: [op({ op: 'declare_no_sales' }), op({ op: 'skip', topic: 'stock_counts' })] }]);
  const { outcomes } = await converse(llm, ["No sales, I'll count later, that's it"]);
  assert.equal(outcomes[0].action, 'summary');
  assert.ok(outcomes[0].summary!.includes('Stock not counted: Book A.'));
});

test('a yes to the summary submits; a change goes back to editing', async () => {
  const done = scripted([
    { intent: 'finish', operations: [op({ op: 'declare_no_sales' }), op({ op: 'set_stock_count', product_id: 'p-a', count: 9 })] },
    { intent: 'change', operations: [op({ op: 'set_stock_count', product_id: 'p-a', count: 8 })] },
    { intent: 'confirm', operations: [] },
  ]);
  const { outcomes } = await converse(done, ['none, 9 left, done', 'actually 8 left', 'yes send it']);
  assert.equal(outcomes[1].action, 'summary');
  assert.deepEqual(outcomes[1].summary, ['No sales today.', 'Stock left: Book A 8.']);
  assert.equal(outcomes[2].action, 'submit');
});

test('pausing keeps everything for later', async () => {
  const llm = scripted([{ intent: 'pause', operations: [op({ op: 'add_sale', product_id: 'p-a', quantity: 1, payment_method: 'cash' })] }]);
  const { outcomes } = await converse(llm, ['one book cash, I have to go']);
  assert.equal(outcomes[0].action, 'pause');
  assert.equal(outcomes[0].draft.sales.length, 1);
});

test('contextual memory: stock and follow-up questions use yesterday\'s data', () => {
  const withFollowUp = { ...ctx, follow_ups_due: [{ id: 'f1', customer_name: 'Esi', due_date: '2026-11-04', note: null }] };
  const draft: Draft = { ...emptyDraft(), no_sales: true };
  const o = openingTurn({ draft, status: 'active', ctx: withFollowUp }, false);
  assert.match(o.reply, /You had follow-ups due with Esi\. Were you able to contact them\?/);

  const d2: Draft = { ...emptyDraft(), no_sales: true, asked: ['follow_up_outcomes'] };
  const o2 = openingTurn({ draft: d2, status: 'active', ctx: withFollowUp }, false);
  assert.match(o2.reply, /Last time you had 5 left of Book A\. How many do you have now\?/);
});

test('malformed LLM output is ignored safely', () => {
  const e = parseExtraction({ intent: 'delete_everything', operations: [{ op: 'drop_table' }, null, { op: 'set_prospects', count: 2 }] });
  assert.equal(e.intent, 'continue');
  assert.equal(e.operations.length, 1);
  assert.equal(e.operations[0].count, 2);
  assert.equal(e.operations[0].product_id, null);
});

test('phone numbers are read digit by digit', () => {
  assert.equal(speakPhone('+233201234567'), '0 2 0, 1 2 3, 4 5 6 7');
});
