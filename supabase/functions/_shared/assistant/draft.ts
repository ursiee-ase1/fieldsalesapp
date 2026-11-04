// Applies the operations an LLM proposed to the report draft, with the same
// rules the database enforces. Anything invalid becomes an "issue" for the
// assistant to raise with the agent; nothing is guessed.
import { normalizeGhanaPhone } from '../phone.ts';
import type {
  AssistantContext, Draft, DraftCustomer, Operation, Outcome, PaymentMethod, ProductCtx,
} from './types.ts';

export function emptyDraft(): Draft {
  return {
    no_sales: false, sales: [], customers: [], follow_ups: [], stock_counts: {},
    follow_up_outcomes: {}, prospects_count: null, comments: [], asked: [], last_question: null, next_ref: 1,
  };
}

export interface ApplyResult {
  draft: Draft;
  issues: string[];
  /** Short English notes of what changed, for the acknowledgement. */
  applied: string[];
}

const OUTCOMES: Outcome[] = ['contacted', 'not_reached', 'sold', 'not_interested'];

export function resolveProduct(ctx: AssistantContext, value: string | null): ProductCtx | null {
  if (!value) return null;
  const v = value.trim().toLowerCase();
  return ctx.products.find((p) => p.id === value)
    ?? ctx.products.find((p) => p.name.toLowerCase() === v)
    ?? ctx.products.find((p) => p.aliases.some((a) => a.toLowerCase() === v))
    ?? null;
}

function payment(value: string | null): PaymentMethod | null | 'invalid' {
  if (value == null || value === '') return null;
  const v = value.toLowerCase().replace(/[\s_-]/g, '');
  if (v === 'cash') return 'cash';
  if (v === 'momo' || v === 'mobilemoney') return 'momo';
  return 'invalid';
}

function isWholeNumber(n: unknown, min: number): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= min;
}

function addDays(isoDate: string, days: number): string {
  const d = new Date(isoDate + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function customerLabel(c: DraftCustomer): string {
  return c.existing_first_name ?? c.full_name ?? 'the customer';
}

export function applyOperations(
  input: Draft, ops: Operation[], ctx: AssistantContext, newId: () => string,
): ApplyResult {
  const draft: Draft = structuredClone(input);
  const issues: string[] = [];
  const applied: string[] = [];
  // Refs the LLM invented in this turn ("new customer") -> real refs.
  const aliases = new Map<string, string>();
  const productList = ctx.products.map((p) => p.name).join(', ');

  const newRef = (prefix: string) => `${prefix}${draft.next_ref++}`;
  const customerByRef = (ref: string | null) => {
    if (!ref) return null;
    const real = aliases.get(ref) ?? ref;
    return draft.customers.find((c) => c.ref === real) ?? null;
  };
  const saleByRef = (ref: string | null) => {
    if (!ref) return null;
    const real = aliases.get(ref) ?? ref;
    return draft.sales.find((s) => s.ref === real) ?? null;
  };
  const product = (value: string | null) => {
    const p = resolveProduct(ctx, value);
    if (!p) issues.push(value ? `"${value}" is not one of your products (${productList}).` : 'Which product was it?');
    return p;
  };

  // New customers first, so a sale or follow-up in the same message can refer
  // to them by their temporary ref whatever order the LLM listed them in.
  const ordered = [...ops.filter((o) => o.op === 'add_customer'), ...ops.filter((o) => o.op !== 'add_customer')];

  for (const op of ordered) {
    switch (op.op) {
      case 'add_sale': {
        const p = product(op.product_id);
        if (!p) break;
        if (!isWholeNumber(op.quantity, 1)) {
          issues.push(`How many ${p.name} did you sell?`);
          break;
        }
        const pay = payment(op.payment_method);
        if (pay === 'invalid') issues.push('Payment can be cash or Mobile Money.');
        if (op.unit_price != null && op.unit_price < 0) issues.push('A price cannot be negative.');
        const customer = op.customer_ref ? customerByRef(op.customer_ref) : null;
        const ref = newRef('s');
        if (op.ref) aliases.set(op.ref, ref);
        draft.sales.push({
          ref, id: newId(), product_id: p.id, quantity: op.quantity,
          unit_price: op.unit_price != null && op.unit_price >= 0 && op.unit_price !== p.unit_price ? op.unit_price : null,
          payment_method: pay === 'invalid' ? null : pay,
          customer_ref: customer?.ref ?? null,
        });
        draft.no_sales = false;
        applied.push(`sale of ${op.quantity} ${p.name}`);
        break;
      }
      case 'update_sale': {
        const s = saleByRef(op.ref);
        if (!s) { issues.push('Which sale should I change?'); break; }
        if (op.product_id) {
          const p = product(op.product_id);
          if (p) { s.product_id = p.id; s.unit_price = null; }
        }
        if (op.quantity != null) {
          if (isWholeNumber(op.quantity, 1)) s.quantity = op.quantity;
          else issues.push('The quantity must be a whole number of at least 1.');
        }
        if (op.unit_price != null) {
          const catalog = ctx.products.find((p) => p.id === s.product_id)?.unit_price;
          if (op.unit_price < 0) issues.push('A price cannot be negative.');
          else s.unit_price = op.unit_price === catalog ? null : op.unit_price;
        }
        const pay = payment(op.payment_method);
        if (pay === 'invalid') issues.push('Payment can be cash or Mobile Money.');
        else if (pay) s.payment_method = pay;
        if (op.customer_ref) s.customer_ref = customerByRef(op.customer_ref)?.ref ?? s.customer_ref;
        applied.push('sale updated');
        break;
      }
      case 'remove_sale': {
        const s = saleByRef(op.ref);
        if (!s) { issues.push('Which sale should I remove?'); break; }
        draft.sales = draft.sales.filter((x) => x !== s);
        applied.push('sale removed');
        break;
      }
      case 'declare_no_sales':
        if (draft.sales.length > 0) {
          issues.push(`You told me about ${draft.sales.length} sale(s) already. Should I remove them?`);
        } else {
          draft.no_sales = true;
          applied.push('no sales today');
        }
        break;
      case 'set_stock_count': {
        const p = product(op.product_id);
        if (!p) break;
        const n = op.count ?? op.quantity;
        if (!isWholeNumber(n, 0)) { issues.push(`How many ${p.name} do you have left?`); break; }
        draft.stock_counts[p.id] = n;
        applied.push(`${n} ${p.name} left`);
        break;
      }
      case 'add_customer': {
        const name = op.full_name?.trim() ?? '';
        if (name.length < 2) { issues.push("What is the customer's name?"); break; }
        let phone: string | null = null;
        if (op.phone && op.phone.trim()) {
          phone = normalizeGhanaPhone(op.phone);
          if (!phone) issues.push(`The number ${op.phone} doesn't look like a Ghana phone number. Could you repeat it?`);
        }
        const ref = newRef('c');
        if (op.ref) aliases.set(op.ref, ref);
        draft.customers.push({
          ref, full_name: name, phone, consent: op.consent, location: op.location?.trim() || null,
          existing_customer_id: null, existing_first_name: null, not_same_as: [],
          details_confirmed: false, match_checked: false, pending_matches: [],
        });
        applied.push(`customer ${name}`);
        break;
      }
      case 'update_customer': {
        const c = customerByRef(op.ref ?? op.customer_ref);
        if (!c || c.existing_customer_id) { issues.push('Which customer should I change?'); break; }
        if (op.full_name && op.full_name.trim().length >= 2) { c.full_name = op.full_name.trim(); c.details_confirmed = false; }
        if (op.phone && op.phone.trim()) {
          const phone = normalizeGhanaPhone(op.phone);
          if (!phone) issues.push(`The number ${op.phone} doesn't look like a Ghana phone number. Could you repeat it?`);
          else if (phone !== c.phone) {
            c.phone = phone;
            c.details_confirmed = false;
            c.match_checked = false;
            c.pending_matches = [];
          }
        }
        if (op.location) c.location = op.location.trim();
        if (op.consent === true) c.consent = true;
        if (op.consent === false) {
          // No consent: the number is not kept.
          c.consent = false;
          c.phone = null;
          c.pending_matches = [];
        }
        applied.push(`customer ${customerLabel(c)} updated`);
        break;
      }
      case 'remove_customer': {
        const c = customerByRef(op.ref ?? op.customer_ref);
        if (!c) { issues.push('Which customer should I remove?'); break; }
        draft.customers = draft.customers.filter((x) => x !== c);
        draft.follow_ups = draft.follow_ups.filter((f) => f.customer_ref !== c.ref);
        for (const s of draft.sales) if (s.customer_ref === c.ref) s.customer_ref = null;
        applied.push(`customer ${customerLabel(c)} removed`);
        break;
      }
      case 'confirm_customer_details': {
        const c = customerByRef(op.ref ?? op.customer_ref);
        if (c) c.details_confirmed = true;
        break;
      }
      case 'answer_customer_match': {
        const c = customerByRef(op.ref ?? op.customer_ref);
        if (!c || c.pending_matches.length === 0) break;
        if (op.same_person === true) {
          const match = c.pending_matches.find((m) => m.customer_id === op.match_customer_id) ?? c.pending_matches[0];
          c.existing_customer_id = match.customer_id;
          c.existing_first_name = match.first_name;
          applied.push(`linked to existing customer ${match.first_name}`);
        } else if (op.same_person === false) {
          c.not_same_as.push(...c.pending_matches.map((m) => m.customer_id));
        } else {
          break;
        }
        c.pending_matches = [];
        break;
      }
      case 'link_sale_customer': {
        const s = saleByRef(op.ref);
        const c = customerByRef(op.customer_ref);
        if (s && c) s.customer_ref = c.ref;
        else issues.push('Which sale was for which customer?');
        break;
      }
      case 'add_follow_up': {
        const c = customerByRef(op.customer_ref);
        if (!c) { issues.push('Who should you follow up with?'); break; }
        const due = op.due_date ?? '';
        if (!/^\d{4}-\d{2}-\d{2}$/.test(due) || due < ctx.today || due > addDays(ctx.today, 90)) {
          issues.push(`When should you follow up with ${customerLabel(c)}? It must be within the next 90 days.`);
          break;
        }
        draft.follow_ups = draft.follow_ups.filter((f) => f.customer_ref !== c.ref);
        draft.follow_ups.push({ customer_ref: c.ref, due_date: due, note: op.note?.trim() || null });
        applied.push(`follow-up with ${customerLabel(c)} on ${due}`);
        break;
      }
      case 'record_follow_up_outcome': {
        const f = ctx.follow_ups_due.find((x) => x.id === op.follow_up_id);
        const outcome = OUTCOMES.find((o) => o === op.outcome);
        if (!f || !outcome) { issues.push('Which follow-up do you mean, and how did it go?'); break; }
        draft.follow_up_outcomes[f.id] = outcome;
        applied.push(`${f.customer_name}: ${outcome.replace('_', ' ')}`);
        break;
      }
      case 'set_prospects': {
        const n = op.count ?? op.quantity;
        if (!isWholeNumber(n, 0)) { issues.push('How many people did you speak to who did not buy?'); break; }
        draft.prospects_count = n;
        applied.push(`${n} people spoken to`);
        break;
      }
      case 'add_comment':
        if (op.text && op.text.trim()) {
          draft.comments.push(op.text.trim());
          applied.push('comment noted');
        }
        break;
      case 'skip':
        if (op.topic && !draft.asked.includes(op.topic)) draft.asked.push(op.topic);
        break;
    }
  }
  return { draft, issues: [...new Set(issues)], applied };
}

/** The submit_report payload (same contract as the app's ReportDraft). */
export function toPayload(draft: Draft): Record<string, unknown> {
  const confirmedRefs = new Set(draft.customers.map((c) => c.ref));
  return {
    ...(draft.no_sales && draft.sales.length === 0 ? { no_sales: true } : {}),
    customers: draft.customers.map((c) =>
      c.existing_customer_id
        ? { ref: c.ref, customer_id: c.existing_customer_id }
        : {
          ref: c.ref,
          full_name: c.full_name,
          ...(c.phone && c.consent ? { phone: c.phone, consent: true } : { consent: false }),
          ...(c.location ? { location: c.location } : {}),
          ...(c.not_same_as.length ? { not_same_as: c.not_same_as } : {}),
        }
    ),
    sales: draft.sales.map((s) => ({
      id: s.id,
      product_id: s.product_id,
      quantity: s.quantity,
      ...(s.unit_price != null ? { unit_price: s.unit_price } : {}),
      payment_method: s.payment_method,
      ...(s.customer_ref && confirmedRefs.has(s.customer_ref) ? { customer_ref: s.customer_ref } : {}),
    })),
    stock_counts: Object.entries(draft.stock_counts).map(([product_id, quantity]) => ({ product_id, quantity })),
    follow_ups: draft.follow_ups.map((f) => ({ customer_ref: f.customer_ref, due_date: f.due_date, ...(f.note ? { note: f.note } : {}) })),
    follow_up_outcomes: Object.entries(draft.follow_up_outcomes).map(([follow_up_id, outcome]) => ({ follow_up_id, outcome })),
    ...(draft.prospects_count != null ? { prospects_count: draft.prospects_count } : {}),
    ...(draft.comments.length ? { comments: draft.comments.join('\n') } : {}),
  };
}
