import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GeminiProvider, toGeminiSchema } from './gemini.ts';
import { FallbackProvider } from './fallback.ts';
import { selectProvider } from './select.ts';
import { LlmError } from './types.ts';
import type { LlmProvider } from './types.ts';
import { EXTRACTION_SCHEMA } from '../assistant/prompts.ts';

test('the extraction schema converts to Gemini\'s OpenAPI subset', () => {
  const s = toGeminiSchema(EXTRACTION_SCHEMA) as any;
  assert.equal(s.type, 'OBJECT');
  assert.equal(s.additionalProperties, undefined);
  const item = s.properties.operations.items;
  assert.deepEqual(item.properties.quantity, { type: 'INTEGER', nullable: true });
  assert.equal(item.properties.op.type, 'STRING');
  assert.ok(item.properties.op.enum.includes('add_sale'));
  assert.ok(item.required.includes('phone'));
});

test('Gemini adapter sends the key in a header and ignores thought parts', async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const fakeFetch = (async (url: string, init: RequestInit) => {
    seen = { url, init };
    return new Response(JSON.stringify({
      candidates: [{ content: { parts: [{ text: 'thinking...', thought: true }, { text: '{"intent":"continue","operations":[]}' }] } }],
      usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 8 },
    }));
  }) as unknown as typeof fetch;
  const g = new GeminiProvider('g-key', 'gemini-test', fakeFetch);
  const r = await g.generateJson('sys', 'user', EXTRACTION_SCHEMA as unknown as Record<string, unknown>);
  assert.deepEqual(r.value, { intent: 'continue', operations: [] });
  assert.deepEqual(r.usage, { input_tokens: 120, output_tokens: 8 });
  assert.equal(seen!.url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent');
  assert.equal((seen!.init.headers as Record<string, string>)['x-goog-api-key'], 'g-key');
  assert.ok(!seen!.url.includes('g-key'), 'key must not be in the URL (it would end up in logs)');
});

test('Gemini errors are classified as retryable or not', async () => {
  let busyCalls = 0;
  const rateLimited = (async () => { busyCalls++; return new Response('slow down', { status: 429 }); }) as unknown as typeof fetch;
  await assert.rejects(new GeminiProvider('k', 'm', rateLimited, 1).generateText('s', 'u', 100),
    (e: { retryable: boolean }) => e.retryable === true);
  assert.equal(busyCalls, 3, 'retried before giving up');

  let keyCalls = 0;
  const badKey = (async () => { keyCalls++; return new Response('bad key', { status: 403 }); }) as unknown as typeof fetch;
  await assert.rejects(new GeminiProvider('k', 'm', badKey, 1).generateText('s', 'u', 100),
    (e: { retryable: boolean }) => e.retryable === false);
  assert.equal(keyCalls, 1, 'a bad key is not retried');
});

test('a "high demand" 503 is retried and then succeeds', async () => {
  let n = 0;
  const busyThenOk = (async () => {
    n++;
    if (n === 1) {
      return new Response(JSON.stringify({ error: { code: 503, message: 'This model is currently experiencing high demand.' } }),
        { status: 503 });
    }
    return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'Hello' }] } }] }));
  }) as unknown as typeof fetch;
  const r = await new GeminiProvider('k', 'm', busyThenOk, 1).generateText('s', 'u', 100);
  assert.equal(r.text, 'Hello');
  assert.equal(n, 2);
});

function stub(name: string, outcome: 'ok' | 'busy' | 'broken'): LlmProvider & { calls: number } {
  return {
    name,
    calls: 0,
    async generateJson() {
      this.calls++;
      if (outcome === 'busy') throw new LlmError(`${name} busy`, true);
      if (outcome === 'broken') throw new LlmError(`${name} bad key`, false);
      return { value: { from: name }, usage: { input_tokens: 1, output_tokens: 1 } };
    },
    async generateText() {
      this.calls++;
      if (outcome !== 'ok') throw new LlmError(`${name} down`, outcome === 'busy');
      return { text: name, usage: { input_tokens: 1, output_tokens: 1 } };
    },
  };
}

test('a busy model hands over to the next one', async () => {
  const first = stub('gemini:a', 'busy');
  const second = stub('gemini:b', 'ok');
  const f = new FallbackProvider([first, second]);
  const r = await f.generateJson('s', 'u', {});
  assert.deepEqual(r.value, { from: 'gemini:b' });
  assert.equal(f.lastUsed, 'gemini:b');
});

test('a configuration error is not hidden by switching models', async () => {
  const first = stub('anthropic', 'broken');
  const second = stub('gemini', 'ok');
  await assert.rejects(new FallbackProvider([first, second]).generateText('s', 'u', 10), /bad key|down/);
  assert.equal(second.calls, 0);
});

// The Claude adapter imports an npm: package that only Deno can load, so
// orderings involving Claude are not exercised under Node.
test('provider order: Gemini alone, or with a backup model', async () => {
  const only = await selectProvider((k) => ({ GEMINI_API_KEY: 'g' } as Record<string, string>)[k]);
  assert.equal(only.name, 'gemini:gemini-3.1-flash-lite');

  const withBackup = await selectProvider((k) =>
    ({ GEMINI_API_KEY: 'g', GEMINI_FALLBACK_MODEL: 'gemini-backup' } as Record<string, string>)[k]);
  assert.equal(withBackup.name, 'gemini:gemini-3.1-flash-lite > gemini:gemini-backup');

  await assert.rejects(selectProvider(() => undefined), /No LLM configured/);
});
