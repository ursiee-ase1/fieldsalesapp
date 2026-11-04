// Conversational reporting assistant (text and voice).
//
// Runs with the caller's own JWT: every database call is made as the agent,
// so tenant isolation, roles and rate limits apply exactly as for the form.
// Provider keys (LLM, Khaya) never leave this function.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders, error, json } from '../_shared/cors.ts';
import { AssistantError, AssistantService } from '../_shared/assistant/service.ts';
import type { AssistantRequest, Db } from '../_shared/assistant/service.ts';
import { Khaya } from '../_shared/language/khaya.ts';
import { selectProvider } from '../_shared/llm/select.ts';
import { LlmError } from '../_shared/llm/types.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const PUBLIC_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY');
const KHAYA_KEY = Deno.env.get('KHAYA_API_KEY');

const ACTIONS = new Set(['start', 'turn', 'confirm', 'abandon']);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return error('method_not_allowed', 'Use POST', 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return error('not_authenticated', 'Missing Authorization header', 401);
  if (!PUBLIC_KEY) return error('misconfigured', 'Function is missing SUPABASE_ANON_KEY', 500);

  let body: AssistantRequest;
  try {
    body = await req.json();
  } catch {
    return error('validation_failed', 'Body must be JSON', 400);
  }
  if (!body || !ACTIONS.has((body as { action?: string }).action ?? '')) {
    return error('validation_failed', 'Unknown action', 400);
  }

  const client = createClient(SUPABASE_URL, PUBLIC_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const db: Db = {
    async rpc(fn, params) {
      const { data, error: e } = await client.rpc(fn, params);
      if (e) throw e;
      return data;
    },
  };

  try {
    const llm = await selectProvider((k) => Deno.env.get(k));
    const service = new AssistantService({
      db,
      llm,
      khaya: KHAYA_KEY ? new Khaya({ apiKey: KHAYA_KEY, baseUrl: Deno.env.get('KHAYA_BASE_URL') || undefined }) : null,
      newId: () => crypto.randomUUID(),
    });
    return json(await service.handle(body));
  } catch (e) {
    if (e instanceof AssistantError) return error(e.code, e.message, e.status);
    if (e instanceof LlmError) {
      console.error('llm', e.message);
      return error('assistant_unavailable',
        'The assistant is not available right now. Please try again, or use the form.', e.retryable ? 503 : 502);
    }
    const pg = e as { message?: string; code?: string; details?: string };
    if (pg?.code === '42501' || pg?.message?.includes('forbidden')) return error('forbidden', 'Only field agents can use the assistant.', 403);
    if (pg?.message?.includes('rate_limited')) return error('rate_limited', 'Too many messages. Please wait a few minutes.', 429);
    if (pg?.message?.includes('conflict')) return error('conflict', 'This conversation was updated somewhere else. Reopen it.', 409);
    if (pg?.message?.includes('session_closed')) return error('session_closed', 'This conversation has ended. Start a new one.', 409);
    console.error('assistant', e);
    return error('internal', 'Something went wrong. Please try again, or use the form.', 500);
  }
});
