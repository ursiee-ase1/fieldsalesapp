// The assistant's request handling, independent of HTTP and Supabase so it
// can be tested with fakes. Every database call runs as the signed-in agent.
import { blockingItem, summaryLines } from './agenda.ts';
import { emptyDraft, toPayload } from './draft.ts';
import { openingTurn, runTurn } from './engine.ts';
import type { TurnOutcome } from './engine.ts';
import type { AssistantContext, Draft, Lang, PhoneMatch, SessionStatus } from './types.ts';
import { looksEnglish, protect, restore } from '../language/entities.ts';
import type { Khaya } from '../language/khaya.ts';
import type { LlmProvider } from '../llm/types.ts';

export interface Db {
  /** Calls a Postgres function as the agent; throws { message, code, details } on error. */
  rpc(fn: string, params?: Record<string, unknown>): Promise<unknown>;
}

export interface ServiceDeps {
  db: Db;
  llm: LlmProvider;
  khaya: Khaya | null;
  newId(): string;
}

export type Channel = 'app_text' | 'app_voice';

export type AssistantRequest =
  | { action: 'start'; channel: Channel; language: Lang; voice_out?: boolean }
  | { action: 'turn'; session_id: string; draft_version: number; language: Lang; text?: string;
      audio_wav_b64?: string; voice_out?: boolean }
  | { action: 'confirm'; session_id: string; draft_version: number; language: Lang; voice_out?: boolean }
  | { action: 'abandon'; session_id: string };

export interface AssistantResponse {
  session_id: string;
  draft_version: number;
  status: SessionStatus | 'submitted' | 'abandoned';
  language: Lang;
  action: TurnOutcome['action'] | 'submitted' | 'abandoned' | 'not_understood';
  /** What the agent said, as recognised (voice) or typed. */
  agent_text: string | null;
  reply_text: string;
  reply_audio_wav_b64: string | null;
  summary: string[] | null;
  notices: string[];
  twi_voice_enabled: boolean;
  history?: { role: string; text: string }[];
  report?: { business_date: string; discrepancies: number; match_reviews: number };
}

export class AssistantError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, message: string, status: number) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

interface SessionRow {
  id: string;
  status: SessionStatus;
  draft: Draft | Record<string, never>;
  draft_version: number;
  context: AssistantContext;
  client_op_id: string;
  language: Lang;
}

interface Turn {
  role: 'agent' | 'assistant';
  text: string;
  english_text?: string | null;
  language: Lang;
  input_mode?: 'text' | 'voice';
  stt_provider?: string;
  translation_provider?: string;
  llm_provider?: string;
  tokens_in?: number;
  tokens_out?: number;
  latency_ms?: number;
  meta?: Record<string, unknown>;
}

const isDraft = (d: unknown): d is Draft => !!d && typeof d === 'object' && Array.isArray((d as Draft).sales);

function b64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Names that translation must leave untouched. */
function protectedNames(ctx: AssistantContext, draft: Draft): string[] {
  return [
    ...ctx.products.flatMap((p) => [p.name, ...p.aliases]),
    ...draft.customers.flatMap((c) => [c.full_name ?? '', c.existing_first_name ?? '']),
    ...ctx.follow_ups_due.map((f) => f.customer_name),
    ctx.agent_first_name,
  ];
}

const MAX_AUDIO_BYTES = 2_000_000; // ~60 s of 16 kHz mono WAV

export class AssistantService {
  private readonly deps: ServiceDeps;

  constructor(deps: ServiceDeps) {
    this.deps = deps;
  }

  async handle(req: AssistantRequest): Promise<AssistantResponse> {
    switch (req.action) {
      case 'start': return this.start(req);
      case 'turn': return this.turn(req);
      case 'confirm': return this.confirm(req);
      case 'abandon': return this.abandon(req);
      default: throw new AssistantError('validation_failed', 'Unknown action', 400);
    }
  }

  // --- Twi via Khaya, metered per company --------------------------------------

  private async khayaCall<T>(notices: string[], fn: (k: Khaya) => Promise<T>): Promise<T | null> {
    const khaya = this.deps.khaya;
    if (!khaya) {
      notices.push('Twi is not set up yet, so I will continue in English.');
      return null;
    }
    try {
      await this.deps.db.rpc('consume_khaya_quota', { p_calls: 1 });
    } catch (e) {
      if (String((e as { message?: string }).message).includes('quota_exceeded')) {
        notices.push('The Twi service limit for this month has been reached, so I will continue in English.');
        return null;
      }
      throw e;
    }
    try {
      return await fn(khaya);
    } catch (e) {
      console.error('khaya', e);
      notices.push('The Twi service is not responding, so I will continue in English.');
      return null;
    }
  }

  private async toEnglish(text: string, names: string[], notices: string[]) {
    if (looksEnglish(text)) return { english: text, translated: false };
    const p = protect(text, names);
    const out = await this.khayaCall(notices, (k) => k.translate(p.text, 'tw-en'));
    if (out == null) return null;
    return { english: restore(out, p.entities).text, translated: true };
  }

  private async toTwi(text: string, names: string[], notices: string[]) {
    const p = protect(text, names);
    const out = await this.khayaCall(notices, (k) => k.translate(p.text, 'en-tw'));
    return out == null ? null : restore(out, p.entities).text;
  }

  /** Reply text in the agent's language, plus Twi audio when asked for. */
  private async speak(english: string, lang: Lang, voiceOut: boolean, ctx: AssistantContext, draft: Draft, notices: string[]) {
    if (lang !== 'tw') return { text: english, audio: null as string | null, translated: false };
    const twi = await this.toTwi(english, protectedNames(ctx, draft), notices);
    if (twi == null) return { text: english, audio: null, translated: false };
    let audio: string | null = null;
    if (voiceOut && ctx.twi_voice_enabled) {
      const wav = await this.khayaCall(notices, (k) => k.synthesize(twi, 'twi'));
      if (wav) audio = bytesToB64(wav);
    }
    return { text: twi, audio, translated: true };
  }

  // --- Actions -------------------------------------------------------------------

  private async start(req: Extract<AssistantRequest, { action: 'start' }>): Promise<AssistantResponse> {
    const started = await this.deps.db.rpc('assistant_start', { p_channel: req.channel, p_language: req.language }) as {
      resumed: boolean; session: SessionRow; turns: { role: string; text: string }[];
    };
    const s = started.session;
    const draft = isDraft(s.draft) ? s.draft : emptyDraft();
    const notices: string[] = [];
    const opening = openingTurn({ draft, status: s.status, ctx: s.context }, started.resumed && started.turns.length > 0);
    const said = await this.speak(opening.reply, req.language, !!req.voice_out, s.context, opening.draft, notices);

    const version = await this.save(s, opening.draft, opening.status, [{
      role: 'assistant', text: said.text, english_text: said.translated ? opening.reply : null, language: req.language,
      translation_provider: said.translated ? 'khaya' : undefined,
    }]);
    return {
      session_id: s.id, draft_version: version, status: opening.status, language: req.language, action: opening.action,
      agent_text: null, reply_text: said.text, reply_audio_wav_b64: said.audio, summary: opening.summary, notices,
      twi_voice_enabled: s.context.twi_voice_enabled, history: started.turns,
    };
  }

  private async load(sessionId: string, expectedVersion?: number) {
    const loaded = await this.deps.db.rpc('assistant_load', { p_session: sessionId }) as {
      session: SessionRow; recent_turns: { role: string; text: string }[];
    };
    if (expectedVersion !== undefined && loaded.session.draft_version !== expectedVersion) {
      throw new AssistantError('conflict', 'This conversation was updated somewhere else. Reopen it to continue.', 409);
    }
    const draft = isDraft(loaded.session.draft) ? loaded.session.draft : emptyDraft();
    return { session: loaded.session, draft, recent: loaded.recent_turns };
  }

  private save(s: SessionRow, draft: Draft, status: SessionStatus, turns: Turn[]): Promise<number> {
    return this.deps.db.rpc('assistant_save', {
      p_session: s.id, p_expected_version: s.draft_version, p_draft: draft, p_status: status, p_turns: turns,
    }) as Promise<number>;
  }

  private async turn(req: Extract<AssistantRequest, { action: 'turn' }>): Promise<AssistantResponse> {
    const started = Date.now();
    const { session: s, draft, recent } = await this.load(req.session_id, req.draft_version);
    const ctx = s.context;
    const notices: string[] = [];
    const lang = req.language;

    // 1. What did the agent say?
    let agentText = req.text?.trim() ?? '';
    let sttProvider: string | undefined;
    if (req.audio_wav_b64) {
      if (lang !== 'tw') {
        throw new AssistantError('validation_failed', 'English speech is recognised on the phone; send text.', 400);
      }
      if (!ctx.twi_voice_enabled) {
        throw new AssistantError('twi_voice_disabled', 'Twi voice is not switched on for your company. Please type instead.', 403);
      }
      const wav = b64ToBytes(req.audio_wav_b64);
      if (wav.length > MAX_AUDIO_BYTES) throw new AssistantError('validation_failed', 'That recording is too long.', 413);
      const heard = await this.khayaCall(notices, (k) => k.transcribe(wav, 'twi'));
      if (!heard) {
        return this.notUnderstood(s, lang, notices, ctx,
          "Sorry, I couldn't hear that clearly. Please try again, or type your answer.");
      }
      agentText = heard;
      sttProvider = 'khaya';
    }
    if (!agentText) throw new AssistantError('validation_failed', 'Say or type something first.', 400);

    // 2. Into English for the engine (Twi only), keeping names and numbers intact.
    let english = agentText;
    let translated = false;
    if (lang === 'tw') {
      const t = await this.toEnglish(agentText, protectedNames(ctx, draft), notices);
      if (!t) {
        return this.notUnderstood(s, lang, notices, ctx,
          "Sorry, I can't understand Twi right now. Please answer in English, or use the form.", agentText);
      }
      english = t.english;
      translated = t.translated;
    }

    // 3. Understand, validate, decide the next question.
    const outcome = await runTurn(
      {
        llm: this.deps.llm,
        newId: this.deps.newId,
        findByPhone: async (phone) => {
          try {
            return await this.deps.db.rpc('find_customer_by_phone', { p_phone: phone }) as PhoneMatch[];
          } catch {
            return []; // The server re-checks on submit and flags duplicates for the manager.
          }
        },
      },
      { draft, status: s.status, ctx, recentTurns: recent },
      english,
      translated ? agentText : undefined,
    );

    const agentTurn: Turn = {
      role: 'agent', text: agentText, english_text: translated ? english : null, language: lang,
      input_mode: req.audio_wav_b64 ? 'voice' : 'text', stt_provider: sttProvider,
      translation_provider: translated ? 'khaya' : undefined,
    };

    if (outcome.action === 'submit') {
      return this.submit(s, outcome.draft, lang, !!req.voice_out, notices, [agentTurn]);
    }

    // 4. Reply in the agent's language.
    const said = await this.speak(outcome.reply, lang, !!req.voice_out, ctx, outcome.draft, notices);
    const version = await this.save(s, outcome.draft, outcome.status, [agentTurn, {
      role: 'assistant', text: said.text, english_text: said.translated ? outcome.reply : null, language: lang,
      translation_provider: said.translated ? 'khaya' : undefined, llm_provider: this.deps.llm.name,
      tokens_in: outcome.usage.input_tokens, tokens_out: outcome.usage.output_tokens,
      latency_ms: Date.now() - started, meta: outcome.issues.length ? { issues: outcome.issues } : {},
    }]);

    return {
      session_id: s.id, draft_version: version, status: outcome.status, language: lang, action: outcome.action,
      agent_text: agentText, reply_text: said.text, reply_audio_wav_b64: said.audio, summary: outcome.summary,
      notices, twi_voice_enabled: ctx.twi_voice_enabled,
    };
  }

  /** Couldn't get the message into English: nothing changes, the agent is asked to retry. */
  private async notUnderstood(s: SessionRow, lang: Lang, notices: string[], ctx: AssistantContext, reply: string, heard?: string) {
    const draft = isDraft(s.draft) ? s.draft : emptyDraft();
    const turns: Turn[] = [];
    if (heard) turns.push({ role: 'agent', text: heard, language: lang });
    turns.push({ role: 'assistant', text: reply, language: 'en', meta: { notices } });
    const version = await this.save(s, draft, s.status, turns);
    return {
      session_id: s.id, draft_version: version, status: s.status, language: lang, action: 'not_understood' as const,
      agent_text: heard ?? null, reply_text: reply, reply_audio_wav_b64: null, summary: null, notices,
      twi_voice_enabled: ctx.twi_voice_enabled,
    };
  }

  private async confirm(req: Extract<AssistantRequest, { action: 'confirm' }>): Promise<AssistantResponse> {
    const { session: s, draft } = await this.load(req.session_id, req.draft_version);
    if (s.status !== 'awaiting_confirmation' || blockingItem(draft, s.context)) {
      throw new AssistantError('validation_failed', 'The report is not ready to send yet.', 409);
    }
    return this.submit(s, draft, req.language, !!req.voice_out, [], []);
  }

  private async submit(s: SessionRow, draft: Draft, lang: Lang, voiceOut: boolean, notices: string[], turns: Turn[]) {
    // Record the confirmation first; submit_report is idempotent on the
    // session's op id, so a retry after a failure here is safe.
    const version = await this.save(s, draft, 'awaiting_confirmation', [
      ...turns,
      { role: 'assistant', text: 'Sending your report.', language: 'en', meta: { summary: summaryLines(draft, s.context) } },
    ]);
    let result: { report_id: string; business_date: string; discrepancies: unknown[]; match_reviews: unknown[] };
    try {
      result = await this.deps.db.rpc('submit_report', {
        p_client_op_id: s.client_op_id, p_payload: toPayload(draft), p_client_captured_at: null, p_source: 'conversation',
      }) as typeof result;
    } catch (e) {
      const detail = (e as { details?: string }).details;
      const reply = `I couldn't send the report: ${detail ?? 'please try again'}. Let's fix that.`;
      const said = await this.speak(reply, lang, voiceOut, s.context, draft, notices);
      const v2 = await this.save({ ...s, draft_version: version }, draft, 'active',
        [{ role: 'assistant', text: said.text, english_text: said.translated ? reply : null, language: lang }]);
      return {
        session_id: s.id, draft_version: v2, status: 'active' as const, language: lang, action: 'ask' as const,
        agent_text: null, reply_text: said.text, reply_audio_wav_b64: said.audio, summary: null, notices,
        twi_voice_enabled: s.context.twi_voice_enabled,
      };
    }
    await this.deps.db.rpc('assistant_mark_submitted', { p_session: s.id, p_report_id: result.report_id });

    const notes = [
      result.discrepancies.length > 0
        ? 'Your stock count is a little different from our records, so your manager will take a look.' : '',
      result.match_reviews.length > 0 ? 'Your manager will check a possible duplicate customer.' : '',
    ].filter(Boolean);
    const reply = ['Thank you! Your report has been sent.', ...notes].join(' ');
    const said = await this.speak(reply, lang, voiceOut, s.context, draft, notices);
    return {
      session_id: s.id, draft_version: version, status: 'submitted' as const, language: lang, action: 'submitted' as const,
      agent_text: null, reply_text: said.text, reply_audio_wav_b64: said.audio, summary: summaryLines(draft, s.context),
      notices, twi_voice_enabled: s.context.twi_voice_enabled,
      report: { business_date: result.business_date, discrepancies: result.discrepancies.length,
                match_reviews: result.match_reviews.length },
    };
  }

  private async abandon(req: Extract<AssistantRequest, { action: 'abandon' }>): Promise<AssistantResponse> {
    const { session: s, draft } = await this.load(req.session_id);
    const version = await this.deps.db.rpc('assistant_save', {
      p_session: s.id, p_expected_version: s.draft_version, p_draft: draft, p_status: 'abandoned', p_turns: [],
    }) as number;
    return {
      session_id: s.id, draft_version: version, status: 'abandoned', language: s.language, action: 'abandoned',
      agent_text: null, reply_text: 'Report discarded.', reply_audio_wav_b64: null, summary: null, notices: [],
      twi_voice_enabled: s.context.twi_voice_enabled,
    };
  }
}
