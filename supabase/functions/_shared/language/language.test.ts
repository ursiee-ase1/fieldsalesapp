import { test } from 'node:test';
import assert from 'node:assert/strict';
import { looksEnglish, protect, restore } from './entities.ts';
import { Khaya } from './khaya.ts';

test('numbers, phones, money and names survive translation', () => {
  const p = protect('Ama Mensah bought 4 Book A for GH₵ 200.00, number 0 2 4, 1 2 3, 4 5 6 7', ['Ama Mensah', 'Book A']);
  assert.ok(!/\d/.test(p.text), p.text);
  assert.ok(!p.text.includes('Ama'));
  // Simulate a translator that reorders words but keeps the placeholders.
  const translated = p.text.split(' ').reverse().join(' ');
  const r = restore(translated, p.entities);
  for (const fact of ['Ama Mensah', 'Book A', '4', 'GH₵ 200.00', '0 2 4, 1 2 3, 4 5 6 7']) {
    assert.ok(r.text.includes(fact), `${fact} missing from: ${r.text}`);
  }
  assert.equal(r.missing, 0);
});

test('a dropped placeholder is appended, never lost silently', () => {
  const p = protect('I sold 6 books', []);
  const r = restore('Matɔn nwoma', p.entities);
  assert.equal(r.text, 'Matɔn nwoma (6)');
  assert.equal(r.missing, 1);
});

test('placeholders with spaces added by the translator are still restored', () => {
  const p = protect('5 left', []);
  const r = restore('⟦ A ⟧ aka', p.entities);
  assert.equal(r.text, '5 aka');
});

test('mostly-English messages in a Twi session skip translation', () => {
  assert.equal(looksEnglish('I sold four books today and two subscriptions'), true);
  assert.equal(looksEnglish('Matɔn nwoma anan nnɛ'), false);
  assert.equal(looksEnglish('Me tɔn nwoma'), false);
});

test('Khaya requests match the SDK wire format', async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const fakeFetch = (async (url: URL, init: RequestInit) => {
    calls.push({ url: String(url), init });
    if (String(url).includes('/v2/translate')) return new Response(JSON.stringify('I sold four books'));
    if (String(url).includes('/asr/v3/')) return new Response(JSON.stringify({ text: ' Matɔn nwoma ', warnings: [] }));
    return new Response(new Uint8Array([82, 73, 70, 70]), { headers: { 'content-type': 'audio/wav' } });
  }) as unknown as typeof fetch;
  const k = new Khaya({ apiKey: 'key-123', fetch: fakeFetch });

  assert.equal(await k.translate('Matɔn nwoma anan', 'tw-en'), 'I sold four books');
  assert.equal(calls[0].url, 'https://translation-api.ghananlp.org/v2/translate');
  assert.deepEqual(JSON.parse(calls[0].init.body as string), { in: 'Matɔn nwoma anan', lang: 'tw-en' });
  assert.equal((calls[0].init.headers as Record<string, string>)['Ocp-Apim-Subscription-Key'], 'key-123');

  assert.equal(await k.transcribe(new Uint8Array([1, 2]), 'twi'), 'Matɔn nwoma');
  assert.equal(calls[1].url, 'https://translation-api.ghananlp.org/asr/v3/transcribe?language=twi');

  const audio = await k.synthesize('Akwaaba', 'twi');
  assert.deepEqual([...audio], [82, 73, 70, 70]);
  assert.deepEqual(JSON.parse(calls[2].init.body as string), { text: 'Akwaaba', language: 'twi' });
});

test('Khaya retries rate limits and server errors, not client errors', async () => {
  let n = 0;
  const flaky = (async () => (++n < 2 ? new Response('busy', { status: 429 }) : new Response(JSON.stringify('ok')))) as unknown as typeof fetch;
  assert.equal(await new Khaya({ apiKey: 'k', fetch: flaky }).translate('x', 'en-tw'), 'ok');
  assert.equal(n, 2);

  let m = 0;
  const bad = (async () => { m++; return new Response('nope', { status: 401 }); }) as unknown as typeof fetch;
  await assert.rejects(new Khaya({ apiKey: 'k', fetch: bad }).translate('x', 'en-tw'), /401/);
  assert.equal(m, 1);
});
