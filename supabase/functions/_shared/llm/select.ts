// Chooses the LLM from configuration: LLM_PROVIDER=anthropic|gemini, or
// whichever key is set (Claude preferred).
import type { LlmProvider } from './types.ts';

export async function selectProvider(env: (k: string) => string | undefined): Promise<LlmProvider> {
  const choice = env('LLM_PROVIDER')?.toLowerCase();
  const anthropicKey = env('ANTHROPIC_API_KEY');
  const geminiKey = env('GEMINI_API_KEY');

  if ((choice === 'anthropic' || (!choice && anthropicKey)) && anthropicKey) {
    const { AnthropicProvider } = await import('./anthropic.ts');
    return new AnthropicProvider(anthropicKey, env('ANTHROPIC_MODEL') || undefined);
  }
  if ((choice === 'gemini' || !choice) && geminiKey) {
    const { GeminiProvider } = await import('./gemini.ts');
    return new GeminiProvider(geminiKey, env('GEMINI_MODEL') || undefined);
  }
  throw new Error('No LLM configured: set ANTHROPIC_API_KEY or GEMINI_API_KEY (and optionally LLM_PROVIDER).');
}
