// Protects facts that machine translation must not change (numbers, phone
// numbers, money, product and customer names) by swapping them for
// placeholders before translating and restoring them afterwards.

const OPEN = '⟦';
const CLOSE = '⟧';

function token(i: number): string {
  // Letters, not digits, so the number patterns never match a placeholder.
  let s = '';
  let n = i;
  do {
    s = String.fromCharCode(65 + (n % 26)) + s;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return `${OPEN}${s}${CLOSE}`;
}

const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const PATTERNS = [
  /GH₵\s?\d+(?:[.,]\d+)?/g, // money
  /\+?\d[\d ,-]{6,}\d/g, // phone numbers and digit-by-digit read-backs
  /\d{4}-\d{2}-\d{2}/g, // dates
  /\d+(?:\.\d+)?/g, // plain numbers
];

export interface Protected {
  text: string;
  entities: string[];
}

export function protect(text: string, names: string[]): Protected {
  const entities: string[] = [];
  let out = text;
  const swap = (match: string) => {
    entities.push(match);
    return token(entities.length - 1);
  };
  const sorted = [...new Set(names.filter((n) => n && n.trim().length >= 2))].sort((a, b) => b.length - a.length);
  for (const name of sorted) {
    out = out.replace(new RegExp(`(?<![\\p{L}\\p{N}])${escape(name)}(?![\\p{L}\\p{N}])`, 'giu'), swap);
  }
  for (const p of PATTERNS) out = out.replace(p, swap);
  return { text: out, entities };
}

/**
 * Puts the protected facts back. Any placeholder the translator dropped is
 * appended in brackets, so a fact is never silently lost.
 */
export function restore(text: string, entities: string[]): { text: string; missing: number } {
  let out = text;
  const lost: string[] = [];
  entities.forEach((value, i) => {
    const t = token(i);
    if (out.includes(t)) out = out.split(t).join(value);
    else lost.push(value);
  });
  // Translators sometimes add spaces inside the brackets.
  out = out.replace(/⟦\s*([A-Z]+)\s*⟧/g, (_m, letters: string) => {
    let n = 0;
    for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
    const value = entities[n - 1];
    if (value !== undefined) {
      const idx = lost.indexOf(value);
      if (idx >= 0) lost.splice(idx, 1);
      return value;
    }
    return '';
  });
  if (lost.length) out = `${out.trim()} (${lost.join(', ')})`;
  return { text: out, missing: lost.length };
}

const ENGLISH_HINTS = new Set([
  'i', 'i\'ve', 'i\'m', 'my', 'me', 'we', 'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'with', 'is',
  'was', 'are', 'have', 'has', 'had', 'did', 'do', 'not', 'no', 'yes', 'it', 'that', 'this', 'today', 'tomorrow',
  'yesterday', 'sold', 'sell', 'sale', 'sales', 'book', 'books', 'copies', 'customer', 'customers', 'left', 'remaining',
  'cash', 'momo', 'mobile', 'money', 'paid', 'follow', 'up', 'call', 'come', 'back', 'one', 'two', 'three', 'four',
  'five', 'six', 'seven', 'eight', 'nine', 'ten', 'some', 'all', 'more', 'none', 'nothing', 'people', 'person',
  'asked', 'want', 'wants', 'her', 'his', 'she', 'he', 'they', 'their', 'number', 'phone', 'okay', 'ok', 'please',
]);

/**
 * True when a message in a Twi session is mostly English already (common
 * with code-switching), so translating it would only add errors.
 */
export function looksEnglish(text: string): boolean {
  if (/[ɛɔƐƆ]/.test(text)) return false;
  const words = text.toLowerCase().match(/[a-z']+/g) ?? [];
  if (words.length === 0) return true;
  const hits = words.filter((w) => ENGLISH_HINTS.has(w)).length;
  return hits / words.length >= 0.5;
}
