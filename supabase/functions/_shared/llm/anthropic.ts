// Claude adapter (Anthropic API via the official SDK).
import Anthropic from 'npm:@anthropic-ai/sdk@^0';
import type { LlmProvider, Usage } from './types.ts';
import { LlmError } from './types.ts';

export class AnthropicProvider implements LlmProvider {
  readonly name: string;
  private readonly client: Anthropic;
  private readonly model: string;

  constructor(apiKey: string, model = 'claude-haiku-5-5') {
    this.client = new Anthropic({ apiKey, maxRetries: 2, timeout: 30_000 });
    this.model = model;
    this.name = `anthropic:${model}`;
  }

  private async call(params: {
    system: string;
    user: string;
    maxTokens: number;
    schema?: Record<string, unknown>;
  }): Promise<{ text: string; usage: Usage }> {
    let response;
    try {
      response = await this.client.messages.create({
        model: this.model,
        max_tokens: params.maxTokens,
        system: [{ type: 'text', text: params.system, cache_control: { type: 'ephemeral' } }],
        messages: [{ role: 'user', content: params.user }],
        output_config: {
          effort: 'low', // short, latency-sensitive turns
          ...(params.schema ? { format: { type: 'json_schema', schema: params.schema } } : {}),
        },
      } as Anthropic.MessageCreateParamsNonStreaming);
    } catch (e) {
      if (e instanceof Anthropic.RateLimitError || e instanceof Anthropic.InternalServerError ||
          e instanceof Anthropic.APIConnectionError) {
        throw new LlmError(`Claude unavailable: ${(e as Error).message}`, true);
      }
      if (e instanceof Anthropic.APIError) throw new LlmError(`Claude request failed: ${e.message}`, false);
      throw e;
    }
    if (response.stop_reason === 'refusal') throw new LlmError('Claude declined the request', false);
    if (response.stop_reason === 'max_tokens') throw new LlmError('Claude response was cut off', true);
    const text = response.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
    return {
      text,
      usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
    };
  }

  async generateJson(system: string, user: string, schema: Record<string, unknown>) {
    const { text, usage } = await this.call({ system, user, maxTokens: 4096, schema });
    try {
      return { value: JSON.parse(text), usage };
    } catch {
      throw new LlmError('Claude returned invalid JSON', true);
    }
  }

  generateText(system: string, user: string, maxTokens: number) {
    return this.call({ system, user, maxTokens: Math.max(maxTokens, 1024) });
  }
}
