// Gemini adapter (Google AI Studio REST API).
//
// Note: on Google's free tier, prompts may be used to improve Google's
// products. Use it with test data only; real customer data needs a paid tier.
import type { LlmProvider, Usage } from './types.ts';
import { LlmError } from './types.ts';

/**
 * Gemini's responseSchema is an OpenAPI subset: upper-case types, `nullable`
 * instead of type arrays, and no additionalProperties.
 */
export function toGeminiSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(toGeminiSchema);
  if (!schema || typeof schema !== 'object') return schema;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(schema as Record<string, unknown>)) {
    if (k === 'additionalProperties') continue;
    if (k === 'type') {
      const types = Array.isArray(v) ? v : [v];
      const real = types.filter((t) => t !== 'null');
      out.type = String(real[0]).toUpperCase();
      if (types.includes('null')) out.nullable = true;
    } else if (k === 'properties') {
      out.properties = Object.fromEntries(
        Object.entries(v as Record<string, unknown>).map(([pk, pv]) => [pk, toGeminiSchema(pv)]),
      );
    } else {
      out[k] = toGeminiSchema(v);
    }
  }
  return out;
}

export class GeminiProvider implements LlmProvider {
  readonly name: string;
  private readonly apiKey: string;
  private readonly model: string;
  private readonly doFetch: typeof fetch;

  constructor(apiKey: string, model = 'gemini-3.1-flash-lite', doFetch: typeof fetch = fetch) {
    this.apiKey = apiKey;
    this.model = model;
    this.doFetch = doFetch;
    this.name = `gemini:${model}`;
  }

  private async call(system: string, user: string, generationConfig: Record<string, unknown>) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`;
    let res: Response;
    try {
      res = await this.doFetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': this.apiKey },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: 'user', parts: [{ text: user }] }],
          generationConfig,
        }),
        signal: AbortSignal.timeout(30_000),
      });
    } catch (e) {
      throw new LlmError(`Gemini unreachable: ${(e as Error).message}`, true);
    }
    if (!res.ok) {
      throw new LlmError(`Gemini request failed: ${res.status} ${await res.text()}`, res.status === 429 || res.status >= 500);
    }
    const data = await res.json();
    const candidate = data?.candidates?.[0];
    if (!candidate || candidate.finishReason === 'SAFETY') throw new LlmError('Gemini returned no answer', false);
    const text = (candidate.content?.parts ?? [])
      .filter((p: { thought?: boolean }) => !p.thought) // skip reasoning parts
      .map((p: { text?: string }) => p.text ?? '').join('');
    const usage: Usage = {
      input_tokens: data?.usageMetadata?.promptTokenCount ?? 0,
      output_tokens: data?.usageMetadata?.candidatesTokenCount ?? 0,
    };
    return { text, usage };
  }

  async generateJson(system: string, user: string, schema: Record<string, unknown>) {
    const { text, usage } = await this.call(system, user, {
      responseMimeType: 'application/json',
      responseSchema: toGeminiSchema(schema),
      maxOutputTokens: 4096,
    });
    try {
      return { value: JSON.parse(text), usage };
    } catch {
      throw new LlmError('Gemini returned invalid JSON', true);
    }
  }

  generateText(system: string, user: string, maxTokens: number) {
    return this.call(system, user, { maxOutputTokens: Math.max(maxTokens, 256) });
  }
}
