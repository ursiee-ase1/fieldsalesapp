// Prompts and the structured-output schema, shared by every LLM provider.
import type { AgendaItem, AssistantContext, Draft } from './types.ts';

type Question = { key: string; kind: string; data: Record<string, unknown> };
import { OPS } from './types.ts';

const nullable = (type: string) => ({ type: [type, 'null'] });

/** JSON Schema for one extraction. Every field is required (null when unused) for strict modes. */
export const EXTRACTION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['intent', 'operations'],
  properties: {
    intent: { type: 'string', enum: ['continue', 'finish', 'confirm', 'change', 'pause'] },
    operations: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'op', 'ref', 'product_id', 'quantity', 'unit_price', 'payment_method', 'customer_ref', 'full_name',
          'phone', 'consent', 'location', 'same_person', 'match_customer_id', 'due_date', 'note', 'follow_up_id',
          'outcome', 'count', 'text', 'topic',
        ],
        properties: {
          op: { type: 'string', enum: [...OPS] },
          ref: nullable('string'),
          product_id: nullable('string'),
          quantity: nullable('integer'),
          unit_price: nullable('number'),
          payment_method: nullable('string'),
          customer_ref: nullable('string'),
          full_name: nullable('string'),
          phone: nullable('string'),
          consent: nullable('boolean'),
          location: nullable('string'),
          same_person: nullable('boolean'),
          match_customer_id: nullable('string'),
          due_date: nullable('string'),
          note: nullable('string'),
          follow_up_id: nullable('string'),
          outcome: nullable('string'),
          count: nullable('integer'),
          text: nullable('string'),
          topic: nullable('string'),
        },
      },
    },
  },
} as const;

// Stable text first so providers can cache it.
export const EXTRACTION_SYSTEM = `You turn a field sales agent's message into structured changes to their daily report.
The agent works in Ghana and may mix English and Twi; Twi messages arrive machine-translated, with the original attached.

Rules:
- Only record what the agent actually said. Never invent or estimate quantities, prices, names, phone numbers or dates.
- If something is unclear or missing, leave it out. The assistant will ask. Do not guess.
- Use product ids from "products". Match what the agent says to a product's name or aliases. If nothing matches, use the agent's word as product_id.
- To change something already in the draft, use its ref (s1, c2, ...) with update_/remove_ operations.
- New customers: add_customer with full_name, and phone only if the agent said one. If a new sale or follow-up in this
  same message belongs to that customer, give the customer a temporary ref like "new1" and use it as customer_ref.
- Phone numbers: copy the digits exactly as spoken (e.g. "0241234567"). Never complete a partial number.
- "I've made no sales" -> declare_no_sales. Zero sales is fine and normal.
- Stock left / remaining -> set_stock_count with count.
- People spoken to who did not buy -> set_prospects with count.
- When the assistant just read back a customer's details or asked a yes/no question about them, a "yes" is
  confirm_customer_details or answer_customer_match (same_person true/false) or update_customer consent true/false,
  for the customer named in "last_question". A correction is update_customer with the corrected field.
- A follow-up date must be YYYY-MM-DD; work it out from "today" ("tomorrow", "on Friday").
- Follow-ups listed in "follow_ups_due": record_follow_up_outcome with follow_up_id and outcome
  contacted | not_reached | sold | not_interested.
- If the agent declines an optional question ("no", "nothing else", "skip"), use skip with topic = last_question.key.
  If they don't know or will count stock later, skip with topic "stock_counts".
- Unused fields are null.

intent:
- "finish": the agent wants to end or send the report now ("that's all", "send it").
- "confirm": the agent says yes to the summary when status is awaiting_confirmation.
- "change": the agent wants to change something after seeing the summary.
- "pause": the agent wants to stop and continue later.
- otherwise "continue".`;

export function extractionInput(args: {
  ctx: AssistantContext;
  draft: Draft;
  status: string;
  lastQuestion: Question | null;
  recentTurns: { role: string; text: string }[];
  message: string;
  originalMessage?: string;
}): string {
  const { ctx, draft } = args;
  return JSON.stringify({
    today: ctx.today,
    weekday: ctx.weekday,
    products: ctx.products.map((p) => ({ id: p.id, name: p.name, aliases: p.aliases, price: p.unit_price })),
    stock_held: ctx.held.map((h) => ({ product_id: h.product_id, name: h.name })),
    follow_ups_due: ctx.follow_ups_due,
    draft: {
      no_sales: draft.no_sales,
      sales: draft.sales.map(({ id: _id, ...s }) => s),
      customers: draft.customers.map((c) => ({
        ref: c.ref, full_name: c.full_name ?? c.existing_first_name, phone: c.phone,
        pending_matches: c.pending_matches,
      })),
      follow_ups: draft.follow_ups,
      stock_counts: draft.stock_counts,
      prospects_count: draft.prospects_count,
    },
    status: args.status,
    last_question: args.lastQuestion && { key: args.lastQuestion.key, kind: args.lastQuestion.kind, data: args.lastQuestion.data },
    recent_conversation: args.recentTurns,
    agent_message: args.message,
    ...(args.originalMessage ? { agent_message_original_twi: args.originalMessage } : {}),
  });
}

export const PHRASE_SYSTEM = `You are a friendly, encouraging field sales supervisor in Ghana, talking with one of your agents
to record their daily report. Write the assistant's next message.

- At most two short sentences, in simple English. It may be translated into Twi and spoken aloud.
- If something was just recorded, acknowledge it briefly and naturally (no long repetition).
- If there are problems, ask about them first, kindly and clearly.
- Then ask exactly the next question given. Ask nothing else.
- Use only the facts provided. Never invent numbers or names.
- Never criticise or pressure the agent about low or zero sales.
- No lists, no emojis, no markdown.`;

export function phraseInput(args: {
  ctx: AssistantContext;
  justRecorded: string[];
  problems: string[];
  next: AgendaItem;
  suggested: string;
  recentTurns: { role: string; text: string }[];
}): string {
  return JSON.stringify({
    agent_first_name: args.ctx.agent_first_name,
    just_recorded: args.justRecorded,
    problems: args.problems,
    next_question: { kind: args.next.kind, details: args.next.data, example_wording: args.suggested },
    recent_conversation: args.recentTurns.slice(-4),
  });
}
