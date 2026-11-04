// Provider-neutral LLM interface. Adapters only handle transport; prompts,
// schemas and validation live in the assistant engine.

export interface Usage {
  input_tokens: number;
  output_tokens: number;
}

export interface LlmProvider {
  readonly name: string;
  /** Returns JSON matching `schema` (already parsed). */
  generateJson(system: string, user: string, schema: Record<string, unknown>): Promise<{ value: unknown; usage: Usage }>;
  generateText(system: string, user: string, maxTokens: number): Promise<{ text: string; usage: Usage }>;
}

export class LlmError extends Error {
  readonly retryable: boolean;

  constructor(message: string, retryable: boolean) {
    super(message);
    this.retryable = retryable;
  }
}
