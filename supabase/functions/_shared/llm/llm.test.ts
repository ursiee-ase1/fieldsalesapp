import { test } from 'node:test';
import assert from 'node:assert/strict';
import { GeminiProvider, toGeminiSchema } from './gemini.ts';
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
  const rateLimited = (async () => new Response('slow down', { status: 429 })) as unknown as typeof fetch;
  await assert.rejects(new GeminiProvider('k', 'm', rateLimited).generateText('s', 'u', 100),
    (e: { retryable: boolean }) => e.retryable === true);
  const badKey = (async () => new Response('bad key', { status: 403 })) as unknown as typeof fetch;
  await assert.rejects(new GeminiProvider('k', 'm', badKey).generateText('s', 'u', 100),
    (e: { retryable: boolean }) => e.retryable === false);
});
