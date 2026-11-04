// One conversational turn: understand the message (LLM), apply it to the draft
// (deterministic), decide what to ask next (deterministic), and phrase the
// reply (LLM, with fixed wording for read-backs). Text and voice both end
// up here.
import type { LlmProvider, Usage } from '../llm/types.ts';
import {
  agenda, blockingItem, greeting, hasCustomerNeedingMatchCheck, summaryLines, summaryText, templateQuestion,
} from './agenda.ts';
import { applyOperations } from './draft.ts';
import { EXTRACTION_SCHEMA, EXTRACTION_SYSTEM, extractionInput, PHRASE_SYSTEM, phraseInput } from './prompts.ts';
import type {
  AgendaItem, AssistantContext, Draft, Extraction, Intent, Operation, PhoneMatch, SessionStatus,
} from './types.ts';
import { OPS } from './types.ts';

export interface TurnDeps {
  llm: LlmProvider;
  /** Runs public.find_customer_by_phone as the agent. */
  findByPhone(phoneE164: string): Promise<PhoneMatch[]>;
  newId(): string;
}

export interface TurnState {
  draft: Draft;
  status: SessionStatus;
  ctx: AssistantContext;
  recentTurns: { role: string; text: string }[];
}

export interface TurnOutcome {
  draft: Draft;
  status: SessionStatus;
  /** ask: continue the conversation; summary: waiting for a yes; submit: the agent confirmed; pause: stop for now. */
  action: 'ask' | 'summary' | 'submit' | 'pause';
  reply: string;
  summary: string[] | null;
  issues: string[];
  usage: Usage;
}

const INTENTS: Intent[] = ['continue', 'finish', 'confirm', 'change', 'pause'];
const FIELDS: (keyof Operation)[] = [
  'ref', 'product_id', 'quantity', 'unit_price', 'payment_method', 'customer_ref', 'full_name', 'phone', 'consent',
  'location', 'same_person', 'match_customer_id', 'due_date', 'note', 'follow_up_id', 'outcome', 'count', 'text', 'topic',
];

/** Defensive parse: providers are asked for strict JSON, but nothing is trusted. */
export function parseExtraction(value: unknown): Extraction {
  const v = (value ?? {}) as Record<string, unknown>;
  const intent = INTENTS.includes(v.intent as Intent) ? v.intent as Intent : 'continue';
  const raw = Array.isArray(v.operations) ? v.operations : [];
  const operations: Operation[] = [];
  for (const r of raw) {
    if (!r || typeof r !== 'object' || !OPS.includes((r as Operation).op)) continue;
    const op = { op: (r as Operation).op } as Operation;
    for (const f of FIELDS) (op as unknown as Record<string, unknown>)[f] = (r as Record<string, unknown>)[f] ?? null;
    operations.push(op);
  }
  return { intent, operations };
}

function addUsage(total: Usage, u: Usage) {
  total.input_tokens += u.input_tokens;
  total.output_tokens += u.output_tokens;
}

function remember(draft: Draft, item: AgendaItem) {
  draft.last_question = { key: item.key, kind: item.kind, data: item.data };
  if (item.once && !draft.asked.includes(item.key)) draft.asked.push(item.key);
}

/** Opening line for a new or resumed session. No LLM call. */
export function openingTurn(state: Omit<TurnState, 'recentTurns'>, resumed: boolean): TurnOutcome {
  const draft: Draft = structuredClone(state.draft);
  const usage = { input_tokens: 0, output_tokens: 0 };
  if (state.status === 'awaiting_confirmation') {
    return { draft, status: state.status, action: 'summary', reply: summaryText(draft, state.ctx),
      summary: summaryLines(draft, state.ctx), issues: [], usage };
  }
  const next = agenda(draft, state.ctx)[0];
  const hello = greeting(state.ctx, resumed);
  if (!next) {
    return { draft, status: 'awaiting_confirmation', action: 'summary', reply: `${hello} ${summaryText(draft, state.ctx)}`,
      summary: summaryLines(draft, state.ctx), issues: [], usage };
  }
  remember(draft, next);
  return { draft, status: 'active', action: 'ask', reply: `${hello} ${templateQuestion(next, state.ctx)}`,
    summary: null, issues: [], usage };
}

export async function runTurn(
  deps: TurnDeps, state: TurnState, message: string, originalMessage?: string,
): Promise<TurnOutcome> {
  const { ctx } = state;
  const usage: Usage = { input_tokens: 0, output_tokens: 0 };

  const extracted = await deps.llm.generateJson(
    EXTRACTION_SYSTEM,
    extractionInput({
      ctx, draft: state.draft, status: state.status, lastQuestion: state.draft.last_question,
      recentTurns: state.recentTurns, message, originalMessage,
    }),
    EXTRACTION_SCHEMA as unknown as Record<string, unknown>,
  );
  addUsage(usage, extracted.usage);
  const { intent, operations } = parseExtraction(extracted.value);

  const { draft, issues, applied } = applyOperations(state.draft, operations, ctx, deps.newId);

  // Once a new customer's number is confirmed, look for existing customers
  // with the same phone ("This number is already associated with Ama...").
  for (const c of draft.customers) {
    if (hasCustomerNeedingMatchCheck(c)) {
      const matches = await deps.findByPhone(c.phone!);
      c.pending_matches = matches.filter((m) => !c.not_same_as.includes(m.customer_id));
      c.match_checked = true;
    }
  }

  if (intent === 'pause') {
    return { draft, status: 'active', action: 'pause', issues, usage, summary: null,
      reply: "No problem. I've saved what you told me. Come back any time to finish your report." };
  }

  const blocking = blockingItem(draft, ctx);
  if (state.status === 'awaiting_confirmation' && intent === 'confirm' && operations.length === 0 && !blocking) {
    return { draft, status: 'awaiting_confirmation', action: 'submit', reply: '', summary: summaryLines(draft, ctx), issues, usage };
  }

  const wantsToFinish = intent === 'finish' || intent === 'confirm';
  const next = wantsToFinish ? blocking : agenda(draft, ctx)[0] ?? null;
  const ack = applied.length > 0 ? 'Got it.' : '';

  if (!next && issues.length === 0) return toSummary(draft, ctx, ack, issues, usage);

  const problems = wantsToFinish && next ? ['Before I can send your report, I need one more answer.', ...issues] : issues;
  const question = next ? templateQuestion(next, ctx) : '';
  const fallback = [ack, ...problems, question].filter(Boolean).join(' ');
  let reply = fallback;

  if (next && !next.templated) {
    try {
      const phrased = await deps.llm.generateText(
        PHRASE_SYSTEM,
        phraseInput({ ctx, justRecorded: applied, problems, next, suggested: question, recentTurns: state.recentTurns }),
        200,
      );
      addUsage(usage, phrased.usage);
      if (phrased.text.trim()) reply = phrased.text.trim();
    } catch {
      // Phrasing is cosmetic: the fixed wording is always a correct question.
    }
  }

  if (next) remember(draft, next);
  return { draft, status: 'active', action: 'ask', reply, summary: null, issues, usage };
}

function toSummary(draft: Draft, ctx: AssistantContext, ack: string, issues: string[], usage: Usage): TurnOutcome {
  // The agent chose to finish: optional questions stay dismissed, even if
  // they make a change after seeing the summary.
  for (const i of agenda(draft, ctx)) {
    if (i.once && !draft.asked.includes(i.key)) draft.asked.push(i.key);
    if (i.kind === 'stock_count' && !draft.asked.includes('stock_counts')) draft.asked.push('stock_counts');
  }
  draft.last_question = null;
  return { draft, status: 'awaiting_confirmation', action: 'summary', issues, usage,
    reply: [ack, summaryText(draft, ctx)].filter(Boolean).join(' '), summary: summaryLines(draft, ctx) };
}

/**
 * The "Finish report" button: skip what's optional and show the summary, or
 * ask only for what's still essential. No LLM call.
 */
export function finishTurn(state: Omit<TurnState, 'recentTurns'>): TurnOutcome {
  const draft: Draft = structuredClone(state.draft);
  const usage = { input_tokens: 0, output_tokens: 0 };
  const blocking = blockingItem(draft, state.ctx);
  if (!blocking) return toSummary(draft, state.ctx, '', [], usage);
  remember(draft, blocking);
  return { draft, status: 'active', action: 'ask', summary: null, issues: [], usage,
    reply: `Before I can send your report, I need one more answer. ${templateQuestion(blocking, state.ctx)}` };
}
