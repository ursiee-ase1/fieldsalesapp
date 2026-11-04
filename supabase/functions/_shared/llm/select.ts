// Chooses the LLM(s) from configuration.
//
//   LLM_PROVIDER=anthropic|gemini   which one answers first (default: Claude if its key is set)
//   GEMINI_FALLBACK_MODEL           a second Gemini model to try when the first is busy
//
// Every configured provider becomes a fallback for the others, so a busy
// model doesn't stop an agent's report.
import { FallbackProvider } from './fallback.ts';
import type { LlmProvider } from './types.ts';

export async function selectProvider(env: (k: string) => string | undefined): Promise<LlmProvider> {
  const anthropicKey = env('ANTHROPIC_API_KEY');
  const geminiKey = env('GEMINI_API_KEY');

  const claude: LlmProvider[] = [];
  const gemini: LlmProvider[] = [];
  if (anthropicKey) {
    const { AnthropicProvider } = await import('./anthropic.ts');
    claude.push(new AnthropicProvider(anthropicKey, env('ANTHROPIC_MODEL') || undefined));
  }
  if (geminiKey) {
    const { GeminiProvider } = await import('./gemini.ts');
    gemini.push(new GeminiProvider(geminiKey, env('GEMINI_MODEL') || undefined));
    const backup = env('GEMINI_FALLBACK_MODEL');
    if (backup) gemini.push(new GeminiProvider(geminiKey, backup));
  }

  const preferGemini = env('LLM_PROVIDER')?.toLowerCase() === 'gemini' || claude.length === 0;
  const ordered = preferGemini ? [...gemini, ...claude] : [...claude, ...gemini];
  if (ordered.length === 0) {
    throw new Error('No LLM configured: set ANTHROPIC_API_KEY or GEMINI_API_KEY (and optionally LLM_PROVIDER).');
  }
  return ordered.length === 1 ? ordered[0] : new FallbackProvider(ordered);
}
