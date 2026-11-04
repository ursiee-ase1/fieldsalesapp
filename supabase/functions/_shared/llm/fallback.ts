// Tries providers in order: when one is busy or unreachable (a retryable
// error), the next answers instead. Non-retryable errors (bad key, refusal)
// are not hidden by switching.
import type { LlmProvider } from './types.ts';
import { LlmError } from './types.ts';

export class FallbackProvider implements LlmProvider {
  readonly name: string;
  private readonly providers: LlmProvider[];
  /** Name of the provider that answered last, for the conversation log. */
  lastUsed: string;

  constructor(providers: LlmProvider[]) {
    if (providers.length === 0) throw new Error('FallbackProvider needs at least one provider');
    this.providers = providers;
    this.name = providers.map((p) => p.name).join(' > ');
    this.lastUsed = providers[0].name;
  }

  private async attempt<T>(run: (p: LlmProvider) => Promise<T>): Promise<T> {
    let last: unknown;
    for (const p of this.providers) {
      try {
        const result = await run(p);
        this.lastUsed = p.name;
        return result;
      } catch (e) {
        if (!(e instanceof LlmError) || !e.retryable) throw e;
        console.warn(`llm fallback: ${p.name} unavailable (${e.message.slice(0, 120)})`);
        last = e;
      }
    }
    throw last;
  }

  generateJson(system: string, user: string, schema: Record<string, unknown>) {
    return this.attempt((p) => p.generateJson(system, user, schema));
  }

  generateText(system: string, user: string, maxTokens: number) {
    return this.attempt((p) => p.generateText(system, user, maxTokens));
  }
}
