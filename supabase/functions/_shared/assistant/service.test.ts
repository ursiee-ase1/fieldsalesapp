import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { AssistantService } from './service.ts';
import type { Db } from './service.ts';
import type { AssistantContext, Operation } from './types.ts';
import type { LlmProvider } from '../llm/types.ts';
import type { Khaya } from '../language/khaya.ts';

const ctx: AssistantContext = {
  today: '2026-11-04', weekday: 'Wednesday', agent_first_name: 'Kofi', report_state: 'none',
  twi_voice_enabled: true,
  products: [{ id: 'p-a', name: 'Book A', aliases: [], unit_price: 50 }],
  held: [{ product_id: 'p-a', name: 'Book A', quantity: 10, last_count: null }],
  follow_ups_due: [],
};

const op = (o: Partial<Operation> & { op: Operation['op'] }): Operation => ({
  ref: null, product_id: null, quantity: null, unit_price: null, payment_method: null, customer_ref: null,
  full_name: null, phone: null, consent: null, location: null, same_person: null, match_customer_id: null,
  due_date: null, note: null, follow_up_id: null, outcome: null, count: null, text: null, topic: null, ...o,
});

/** In-memory stand-in for the assistant RPCs. */
function fakeDb(opts: { quota?: number } = {}) {
  const session = {
    id: 'sess-1', status: 'active', draft: {}, draft_version: 0, context: ctx, client_op_id: 'op-1', language: 'en',
  };
  const turns: { role: string; text: string; english_text?: string | null }[] = [];
  const calls: { fn: string; params: Record<string, unknown> }[] = [];
  let quota = opts.quota ?? 100;
  const db: Db = {
    async rpc(fn, params = {}) {
      calls.push({ fn, params });
      switch (fn) {
        case 'assistant_start': return { resumed: false, session: { ...session }, turns: [] };
        case 'assistant_load': return { session: { ...session }, recent_turns: turns.slice(-8) };
        case 'assistant_save':
          if (params.p_expected_version !== session.draft_version) throw { message: 'conflict', code: '40001' };
          Object.assign(session, { draft: params.p_draft, status: params.p_status, draft_version: session.draft_version + 1 });
          turns.push(...(params.p_turns as typeof turns));
          return session.draft_version;
        case 'consume_khaya_quota':
          if (--quota < 0) throw { message: 'quota_exceeded', code: 'P0001' };
          return quota;
        case 'find_customer_by_phone': return [];
        case 'submit_report':
          return { report_id: 'r-1', business_date: '2026-11-04', discrepancies: [], match_reviews: [] };
        case 'assistant_mark_submitted': session.status = 'submitted'; return null;
      }
      throw new Error(`unexpected rpc ${fn}`);
    },
  };
  return { db, session, turns, calls };
}

function llm(extractions: unknown[]): LlmProvider & { seen: string[] } {
  const queue = [...extractions];
  return {
    name: 'fake', seen: [],
    async generateJson(_s, user) {
      this.seen.push(JSON.parse(user).agent_message);
      return { value: queue.shift(), usage: { input_tokens: 10, output_tokens: 5 } };
    },
    async generateText() { throw new Error('use the fixed wording'); },
  };
}

/** Fake Khaya: "translates" by tagging, and checks placeholders were used for names/numbers. */
function fakeKhaya(): Khaya & { requests: string[] } {
  const requests: string[] = [];
  return {
    name: 'khaya', requests,
    async translate(text: string, pair: string) {
      requests.push(`${pair}:${text}`);
      return pair === 'tw-en' ? `I sold ${text.match(/⟦[A-Z]+⟧/g)?.join(' ') ?? ''} books` : `[tw] ${text}`;
    },
    async transcribe() { requests.push('asr'); return 'Matɔn nwoma 3'; },
    async synthesize() { requests.push('tts'); return new Uint8Array([82, 73, 70, 70]); },
  } as unknown as Khaya & { requests: string[] };
}

test('an English text report from greeting to submission', async () => {
  const { db, calls } = fakeDb();
  const svc = new AssistantService({
    db, khaya: null, newId: randomUUID,
    llm: llm([
      { intent: 'finish', operations: [
        op({ op: 'add_sale', product_id: 'p-a', quantity: 3, payment_method: 'cash' }),
        op({ op: 'set_stock_count', product_id: 'p-a', count: 7 }),
      ] },
      { intent: 'confirm', operations: [] },
    ]),
  });

  const start = await svc.handle({ action: 'start', channel: 'app_text', language: 'en' });
  assert.match(start.reply_text, /How many sales have you made today\?/);

  const t1 = await svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: start.draft_version, language: 'en',
    text: "Three Book A, cash. Seven left. That's all." });
  assert.equal(t1.action, 'summary');
  assert.deepEqual(t1.summary, ['Sales: 3 × Book A at GH₵ 50.00 (cash). Total GH₵ 150.00.', 'Stock left: Book A 7.']);
  assert.equal(calls.filter((c) => c.fn === 'submit_report').length, 0, 'nothing is saved before confirmation');

  const t2 = await svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: t1.draft_version, language: 'en', text: 'Yes' });
  assert.equal(t2.action, 'submitted');
  assert.equal(t2.reply_text, 'Thank you! Your report has been sent.');
  const submit = calls.find((c) => c.fn === 'submit_report')!;
  assert.equal(submit.params.p_client_op_id, 'op-1');
  assert.equal(submit.params.p_source, 'conversation');
  const payload = submit.params.p_payload as { sales: { quantity: number }[]; stock_counts: unknown[] };
  assert.equal(payload.sales[0].quantity, 3);
  assert.deepEqual(payload.stock_counts, [{ product_id: 'p-a', quantity: 7 }]);
});

test('Twi: translated in and out, with numbers protected; voice gets audio', async () => {
  const { db, turns } = fakeDb();
  const khaya = fakeKhaya();
  const model = llm([{ intent: 'continue', operations: [op({ op: 'add_sale', product_id: 'p-a', quantity: 3, payment_method: 'cash' })] }]);
  const svc = new AssistantService({ db, khaya, newId: randomUUID, llm: model });

  const start = await svc.handle({ action: 'start', channel: 'app_voice', language: 'tw', voice_out: true });
  assert.ok(start.reply_text.startsWith('[tw] '));
  assert.ok(start.reply_audio_wav_b64);

  const t = await svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: start.draft_version, language: 'tw',
    audio_wav_b64: btoa('RIFFfake'), voice_out: true });
  assert.equal(t.agent_text, 'Matɔn nwoma 3');
  // The digit went to Khaya as a placeholder and came back intact.
  assert.ok(khaya.requests.includes('tw-en:Matɔn nwoma ⟦A⟧'), khaya.requests.join(' | '));
  assert.equal(model.seen[0], 'I sold 3 books');
  // Transcript keeps both languages for audit.
  const agentTurn = turns.find((x) => x.role === 'agent')!;
  assert.equal(agentTurn.text, 'Matɔn nwoma 3');
  assert.equal(agentTurn.english_text, 'I sold 3 books');
});

test('mixed English in a Twi session is not translated', async () => {
  const { db } = fakeDb();
  const khaya = fakeKhaya();
  const model = llm([{ intent: 'continue', operations: [] }]);
  const svc = new AssistantService({ db, khaya, newId: randomUUID, llm: model });
  const start = await svc.handle({ action: 'start', channel: 'app_text', language: 'tw' });
  await svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: start.draft_version, language: 'tw',
    text: 'I sold four books today' });
  assert.ok(!khaya.requests.some((r) => r.startsWith('tw-en')));
  assert.equal(model.seen[0], 'I sold four books today');
});

test('when the Twi quota runs out, the agent is told and nothing is lost', async () => {
  const { db, session } = fakeDb({ quota: 1 });
  const svc = new AssistantService({ db, khaya: fakeKhaya(), newId: randomUUID, llm: llm([]) });
  const start = await svc.handle({ action: 'start', channel: 'app_text', language: 'tw' }); // uses the last call
  const t = await svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: start.draft_version, language: 'tw',
    text: 'Matɔn nwoma anan' });
  assert.equal(t.action, 'not_understood');
  assert.match(t.notices.join(' '), /limit for this month/);
  assert.match(t.reply_text, /answer in English, or use the form/);
  assert.equal((session.draft as { sales: unknown[] }).sales.length, 0);
});

test('Twi voice is refused unless the company switched it on', async () => {
  const { db, session } = fakeDb();
  session.context = { ...ctx, twi_voice_enabled: false };
  const svc = new AssistantService({ db, khaya: fakeKhaya(), newId: randomUUID, llm: llm([]) });
  await assert.rejects(
    svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: 0, language: 'tw', audio_wav_b64: btoa('x') }),
    /not switched on/,
  );
});

test('a stale device gets a conflict instead of overwriting newer answers', async () => {
  const { db } = fakeDb();
  const svc = new AssistantService({ db, khaya: null, newId: randomUUID, llm: llm([]) });
  await svc.handle({ action: 'start', channel: 'app_text', language: 'en' });
  await assert.rejects(
    svc.handle({ action: 'turn', session_id: 'sess-1', draft_version: 0, language: 'en', text: 'hi' }),
    /updated somewhere else/,
  );
});

test('the confirm button only works once the report is ready', async () => {
  const { db } = fakeDb();
  const svc = new AssistantService({ db, khaya: null, newId: randomUUID, llm: llm([]) });
  const start = await svc.handle({ action: 'start', channel: 'app_text', language: 'en' });
  await assert.rejects(
    svc.handle({ action: 'confirm', session_id: 'sess-1', draft_version: start.draft_version, language: 'en' }),
    /not ready/,
  );
});
