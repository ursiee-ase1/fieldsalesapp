// GhanaNLP Khaya API: Twi translation (v2), speech recognition (v3) and
// speech synthesis (v2). Request shapes follow the official Khaya Python
// SDK (github.com/Khaya-AI/khaya-sdk), as the API reference itself requires
// a portal sign-in.

export class KhayaError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export interface KhayaOptions {
  apiKey: string;
  baseUrl?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

/** Twi variety codes used by ASR and TTS ("twi" is Asante, "atw" Akuapem). */
export type TwiVariety = 'twi' | 'atw';

export class Khaya {
  readonly name = 'khaya';
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly doFetch: typeof fetch;
  private readonly timeoutMs: number;

  constructor(opts: KhayaOptions) {
    this.apiKey = opts.apiKey;
    this.baseUrl = (opts.baseUrl ?? 'https://translation-api.ghananlp.org').replace(/\/$/, '');
    this.doFetch = opts.fetch ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? 30_000;
  }

  private async post(path: string, body: BodyInit, query?: Record<string, string>): Promise<Response> {
    const url = new URL(this.baseUrl + path);
    for (const [k, v] of Object.entries(query ?? {})) url.searchParams.set(k, v);
    let last: unknown;
    // Same policy as the SDK: up to 3 attempts on 429/5xx and network errors.
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const res = await this.doFetch(url, {
          method: 'POST',
          headers: {
            'Ocp-Apim-Subscription-Key': this.apiKey,
            'Content-Type': 'application/json',
            'Cache-Control': 'no-cache',
          },
          body,
          signal: AbortSignal.timeout(this.timeoutMs),
        });
        if (res.ok) return res;
        if (![429, 500, 502, 503, 504].includes(res.status)) {
          throw new KhayaError(`Khaya ${path} failed: ${res.status} ${await res.text()}`, res.status);
        }
        last = new KhayaError(`Khaya ${path} failed: ${res.status}`, res.status);
      } catch (e) {
        if (e instanceof KhayaError && ![429, 500, 502, 503, 504].includes(e.status)) throw e;
        last = e;
      }
      await new Promise((r) => setTimeout(r, 2 ** attempt * 500));
    }
    throw last instanceof Error ? last : new KhayaError(`Khaya ${path} failed`, 0);
  }

  /** pair: "tw-en" or "en-tw". */
  async translate(text: string, pair: 'tw-en' | 'en-tw'): Promise<string> {
    const res = await this.post('/v2/translate', JSON.stringify({ in: text, lang: pair }));
    const data = await res.json();
    if (typeof data === 'string') return data;
    const value = data?.out ?? data?.translation ?? data?.text;
    if (typeof value !== 'string') throw new KhayaError('Unexpected translation response', 200);
    return value;
  }

  /** Audio must be WAV (PCM, 16 kHz mono recommended). */
  async transcribe(wav: Uint8Array<ArrayBuffer>, language: TwiVariety): Promise<string> {
    const res = await this.post('/asr/v3/transcribe', wav, { language });
    const data = await res.json();
    const text = typeof data === 'string' ? data : data?.text;
    if (typeof text !== 'string') throw new KhayaError('Unexpected transcription response', 200);
    return text.trim();
  }

  /** Returns WAV audio bytes. */
  async synthesize(text: string, language: TwiVariety): Promise<Uint8Array> {
    const res = await this.post('/tts/v2/synthesize', JSON.stringify({ text, language }));
    return new Uint8Array(await res.arrayBuffer());
  }
}
