// Decides what the assistant asks next, and renders the parts that must be
// exact (read-backs of names and phone numbers, the final summary).
import { customerLabel } from './draft.ts';
import type { AgendaItem, AssistantContext, Draft, DraftCustomer } from './types.ts';

/** "+233241234567" -> "0 2 4, 1 2 3, 4 5 6 7": digit by digit, with pauses when spoken. */
export function speakPhone(e164: string): string {
  const local = e164.startsWith('+233') ? '0' + e164.slice(4) : e164.replace(/^\+/, '');
  const groups = local.length === 10 ? [local.slice(0, 3), local.slice(3, 6), local.slice(6)] : [local];
  return groups.map((g) => g.split('').join(' ')).join(', ');
}

export function formatMoney(n: number): string {
  return `GH₵ ${n.toFixed(2)}`;
}

function item(
  key: string, kind: AgendaItem['kind'], data: Record<string, unknown>,
  opts: { blocking?: boolean; once?: boolean; templated?: boolean } = {},
): AgendaItem {
  return { key, kind, data, blocking: opts.blocking ?? false, once: opts.once ?? false, templated: opts.templated ?? false };
}

/** Everything still open, most important first. */
export function agenda(draft: Draft, ctx: AssistantContext): AgendaItem[] {
  const items: AgendaItem[] = [];
  const productName = (id: string) => ctx.products.find((p) => p.id === id)?.name ?? 'that product';

  for (const c of draft.customers) {
    if (!c.existing_customer_id && !c.details_confirmed) {
      items.push(item(`confirm:${c.ref}`, 'confirm_customer', { ref: c.ref, name: c.full_name, phone: c.phone },
        { blocking: true, templated: true }));
    } else if (c.pending_matches.length > 0) {
      items.push(item(`match:${c.ref}`, 'customer_match', { ref: c.ref, matches: c.pending_matches },
        { blocking: true, templated: true }));
    } else if (c.phone && c.consent !== true) {
      items.push(item(`consent:${c.ref}`, 'consent', { ref: c.ref, name: customerLabel(c) },
        { blocking: true, templated: true }));
    }
  }

  for (const s of draft.sales) {
    if (!s.payment_method) {
      items.push(item(`payment:${s.ref}`, 'payment', { ref: s.ref, quantity: s.quantity, product: productName(s.product_id) },
        { blocking: true }));
    }
  }

  if (draft.sales.length === 0 && !draft.no_sales) {
    if (ctx.report_state === 'none') items.push(item('sales', 'sales', {}, { blocking: true }));
    else if (!draft.asked.includes('more_sales')) items.push(item('more_sales', 'more_sales', {}, { once: true }));
  }

  const openFollowUps = ctx.follow_ups_due.filter((f) => !draft.follow_up_outcomes[f.id]);
  if (openFollowUps.length > 0 && !draft.asked.includes('follow_up_outcomes')) {
    items.push(item('follow_up_outcomes', 'follow_up_outcomes',
      { follow_ups: openFollowUps.map((f) => ({ id: f.id, customer_name: f.customer_name, note: f.note })) },
      { once: true }));
  }

  // Stock counts are asked until answered or explicitly skipped.
  if (!draft.asked.includes('stock_counts')) {
    for (const h of ctx.held) {
      if (draft.stock_counts[h.product_id] === undefined) {
        const sold = draft.sales.filter((s) => s.product_id === h.product_id).reduce((n, s) => n + s.quantity, 0);
        items.push(item(`stock:${h.product_id}`, 'stock_count',
          { product_id: h.product_id, product: h.name, last_count: h.last_count, sold_today_reported: sold }));
        break; // one product at a time
      }
    }
  }

  if (draft.prospects_count == null && !draft.asked.includes('prospects')) {
    items.push(item('prospects', 'prospects', {}, { once: true }));
  }
  if ((draft.prospects_count ?? 0) > 0 && draft.follow_ups.length === 0 && !draft.asked.includes('follow_up_requests')) {
    items.push(item('follow_up_requests', 'follow_up_requests', { prospects: draft.prospects_count }, { once: true }));
  }
  if (!draft.asked.includes('comments')) items.push(item('comments', 'comments', {}, { once: true }));
  return items;
}

/** First thing that still stops the report from being sent, if any. */
export function blockingItem(draft: Draft, ctx: AssistantContext): AgendaItem | null {
  return agenda(draft, ctx).find((i) => i.blocking) ?? null;
}

function confirmCustomer(c: Record<string, unknown>): string {
  const phone = typeof c.phone === 'string' ? `, phone number ${speakPhone(c.phone)}` : '';
  return `Let me check I have this right: the customer's name is ${c.name}${phone}. Is that correct?`;
}

/**
 * Exact wording for each item. Used as-is for templated items, and as the
 * fallback whenever the LLM is unavailable.
 */
export function templateQuestion(i: AgendaItem, ctx: AssistantContext): string {
  const d = i.data as Record<string, any>;
  switch (i.kind) {
    case 'confirm_customer':
      return confirmCustomer(d);
    case 'customer_match': {
      const m = d.matches as { first_name: string }[];
      return m.length === 1
        ? `This phone number is already associated with ${m[0].first_name}. Is this the same customer?`
        : `This phone number is already associated with ${m.map((x) => x.first_name).join(' and ')}. Is it one of them?`;
    }
    case 'consent':
      return `Did ${d.name} agree for us to keep their phone number?`;
    case 'payment':
      return `Was that sale of ${d.product} paid in cash or Mobile Money?`;
    case 'sales':
      return 'How many sales have you made today?';
    case 'more_sales':
      return 'Have you made any more sales since your last report?';
    case 'follow_up_outcomes': {
      const names = (d.follow_ups as { customer_name: string }[]).map((f) => f.customer_name);
      return `You had follow-ups due with ${names.join(' and ')}. Were you able to contact them?`;
    }
    case 'stock_count': {
      const last = d.last_count as { quantity: number } | null;
      return last
        ? `Last time you had ${last.quantity} left of ${d.product}. How many do you have now?`
        : `How many do you have left of ${d.product}?`;
    }
    case 'prospects':
      return "How many people did you speak to who haven't bought yet?";
    case 'follow_up_requests':
      return 'Did any of them ask you to come back or call them?';
    case 'comments':
      return 'Is there anything else you would like to add?';
  }
  return ctx.agent_first_name ? `Anything else, ${ctx.agent_first_name}?` : 'Anything else?';
}

export function greeting(ctx: AssistantContext, resumed: boolean): string {
  const name = ctx.agent_first_name ? `, ${ctx.agent_first_name}` : '';
  if (resumed) return `Welcome back${name}. Let's carry on with your report.`;
  if (ctx.report_state !== 'none') return `Hello${name}! You've already reported today. Let's add anything new.`;
  return `Hello${name}! Let's record your field activities.`;
}

/** Deterministic summary shown and read back before anything is saved. */
export function summaryLines(draft: Draft, ctx: AssistantContext): string[] {
  const lines: string[] = [];
  const product = (id: string) => ctx.products.find((p) => p.id === id);
  const customer = (ref: string | null) => draft.customers.find((c) => c.ref === ref);

  if (draft.sales.length > 0) {
    let total = 0;
    const parts = draft.sales.map((s) => {
      const p = product(s.product_id);
      const price = s.unit_price ?? p?.unit_price ?? 0;
      total += price * s.quantity;
      const who = customer(s.customer_ref);
      return `${s.quantity} × ${p?.name} at ${formatMoney(price)} (${s.payment_method === 'momo' ? 'Mobile Money' : 'cash'})` +
        (who ? ` to ${customerLabel(who)}` : '');
    });
    lines.push(`Sales: ${parts.join('; ')}. Total ${formatMoney(total)}.`);
  } else if (draft.no_sales) {
    lines.push('No sales today.');
  } else if (ctx.report_state !== 'none') {
    lines.push('No new sales.');
  }

  const counted = ctx.held.filter((h) => draft.stock_counts[h.product_id] !== undefined)
    .map((h) => `${h.name} ${draft.stock_counts[h.product_id]}`);
  const extra = Object.keys(draft.stock_counts).filter((id) => !ctx.held.some((h) => h.product_id === id))
    .map((id) => `${product(id)?.name} ${draft.stock_counts[id]}`);
  const uncounted = ctx.held.filter((h) => draft.stock_counts[h.product_id] === undefined).map((h) => h.name);
  if (counted.length + extra.length > 0) lines.push(`Stock left: ${[...counted, ...extra].join(', ')}.`);
  if (uncounted.length > 0) lines.push(`Stock not counted: ${uncounted.join(', ')}.`);

  for (const c of draft.customers) {
    const f = draft.follow_ups.find((x) => x.customer_ref === c.ref);
    const phone = !c.existing_customer_id && c.phone && c.consent ? ` (${c.phone})` : '';
    const existing = c.existing_customer_id ? ' (existing customer)' : '';
    lines.push(`Customer: ${customerLabel(c)}${phone}${existing}${f ? `, follow up on ${f.due_date}` : ''}.`);
  }
  for (const f of ctx.follow_ups_due) {
    const o = draft.follow_up_outcomes[f.id];
    if (o) lines.push(`Follow-up with ${f.customer_name}: ${o.replace('_', ' ')}.`);
  }
  if (draft.prospects_count != null) lines.push(`Spoke to ${draft.prospects_count} people who didn't buy.`);
  if (draft.comments.length) lines.push(`Comments: ${draft.comments.join(' ')}`);
  return lines;
}

export function summaryText(draft: Draft, ctx: AssistantContext): string {
  return `Here is your report. ${summaryLines(draft, ctx).join(' ')} Shall I send it?`;
}

export function hasCustomerNeedingMatchCheck(c: DraftCustomer): boolean {
  return !!c.phone && c.details_confirmed && !c.match_checked && !c.existing_customer_id;
}
