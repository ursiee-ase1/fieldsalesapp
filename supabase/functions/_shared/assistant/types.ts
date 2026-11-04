// Shapes shared by the assistant engine. Snake_case matches the database
// context and the submit_report payload.

export type Lang = 'en' | 'tw';
export type ReportState = 'none' | 'zero_sales' | 'with_sales';
export type PaymentMethod = 'cash' | 'momo';
export type Outcome = 'contacted' | 'not_reached' | 'sold' | 'not_interested';
export type SessionStatus = 'active' | 'awaiting_confirmation';

export interface ProductCtx {
  id: string;
  name: string;
  aliases: string[];
  unit_price: number;
}

export interface HeldCtx {
  product_id: string;
  name: string;
  quantity: number;
  last_count: { date: string; quantity: number } | null;
}

export interface FollowUpCtx {
  id: string;
  customer_name: string;
  due_date: string;
  note: string | null;
}

/** Built by app.assistant_context: everything the assistant may know. */
export interface AssistantContext {
  today: string; // YYYY-MM-DD, company timezone
  weekday: string;
  agent_first_name: string;
  report_state: ReportState;
  twi_voice_enabled: boolean;
  products: ProductCtx[];
  held: HeldCtx[];
  follow_ups_due: FollowUpCtx[];
}

export interface DraftSale {
  ref: string;
  id: string; // client-style UUID, so submit_report stays idempotent
  product_id: string;
  quantity: number;
  unit_price: number | null; // null = catalog price
  payment_method: PaymentMethod | null;
  customer_ref: string | null;
}

export interface PhoneMatch {
  customer_id: string;
  first_name: string;
  masked_phone: string;
}

export interface DraftCustomer {
  ref: string;
  full_name: string | null;
  phone: string | null; // E.164
  consent: boolean | null;
  location: string | null;
  existing_customer_id: string | null;
  existing_first_name: string | null;
  not_same_as: string[];
  details_confirmed: boolean;
  match_checked: boolean;
  pending_matches: PhoneMatch[];
}

export interface DraftFollowUp {
  customer_ref: string;
  due_date: string;
  note: string | null;
}

export interface Draft {
  no_sales: boolean;
  sales: DraftSale[];
  customers: DraftCustomer[];
  follow_ups: DraftFollowUp[];
  stock_counts: Record<string, number>;
  follow_up_outcomes: Record<string, Outcome>;
  prospects_count: number | null;
  comments: string[];
  /** Optional questions already asked or skipped: never asked twice. */
  asked: string[];
  /** What the assistant asked last, so "yes"/"no" can be interpreted. */
  last_question: { key: string; kind: string; data: Record<string, unknown> } | null;
  next_ref: number;
}

export const OPS = [
  'add_sale', 'update_sale', 'remove_sale', 'declare_no_sales', 'set_stock_count',
  'add_customer', 'update_customer', 'remove_customer', 'confirm_customer_details',
  'answer_customer_match', 'link_sale_customer', 'add_follow_up', 'record_follow_up_outcome',
  'set_prospects', 'add_comment', 'skip',
] as const;
export type OpName = typeof OPS[number];

/** One change the LLM proposes. Every field is present; unused ones are null. */
export interface Operation {
  op: OpName;
  ref: string | null;
  product_id: string | null;
  quantity: number | null;
  unit_price: number | null;
  payment_method: string | null;
  customer_ref: string | null;
  full_name: string | null;
  phone: string | null;
  consent: boolean | null;
  location: string | null;
  same_person: boolean | null;
  match_customer_id: string | null;
  due_date: string | null;
  note: string | null;
  follow_up_id: string | null;
  outcome: string | null;
  count: number | null;
  text: string | null;
  topic: string | null;
}

export type Intent = 'continue' | 'finish' | 'confirm' | 'change' | 'pause';

export interface Extraction {
  intent: Intent;
  operations: Operation[];
}

export interface AgendaItem {
  key: string;
  kind:
    | 'confirm_customer' | 'customer_match' | 'consent' | 'payment' | 'sales' | 'more_sales'
    | 'follow_up_outcomes' | 'stock_count' | 'prospects' | 'follow_up_requests' | 'comments';
  /** Must be resolved before the report can be sent. */
  blocking: boolean;
  /** Asked once; afterwards the agent may ignore it. */
  once: boolean;
  /** Read back word for word (names, phone numbers): never paraphrased by the LLM. */
  templated: boolean;
  data: Record<string, unknown>;
}
