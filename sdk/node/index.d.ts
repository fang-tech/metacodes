// Type declarations for the `metacodes` Node package (index.js).

export const ABI_REVISION: number;
export const BUILTIN_TOOLS: readonly string[];
export const DEFAULT_TOOLS: readonly string[];

/** One AgentCore observation event: a single key (the tag) and its payload. */
export type AgentEvent = Record<string, unknown>;

export interface Tool<Args = Record<string, unknown>> {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  handler: (args: Args) => unknown | Promise<unknown>;
}

export function tool<Args = Record<string, unknown>>(spec: {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
  handler: (args: Args) => unknown | Promise<unknown>;
}): Tool<Args>;

export class UiRequest {
  readonly kind: 'permission' | 'ask_question';
  readonly data: Record<string, any>;
  allowOnce(): object;
  allowSession(): object;
  denyOnce(): object;
  denySession(): object;
  answer(...values: string[][]): object;
}

export interface RunResult {
  text: string;
  stopReason: string;
  turns: number;
  toolCalls: number;
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens: number;
    cache_creation_input_tokens: number;
  };
  segments: { disposition: string; group: number; text: string }[];
  inputAccepted: number;
  inputAdopted: number;
}

export class AgentCoreError extends Error {
  readonly code: string;
  readonly status: number;
  readonly diagnostic: string;
}

export interface SessionOptions {
  provider?: 'anthropic' | 'openai' | 'gemini';
  apiKey?: string;
  /** Full endpoint; empty means the provider's official one. */
  baseUrl?: string;
  workspace?: string;
  workspaceHome?: string;
  tools?: string[];
  permissionMode?: 'default' | 'accept_edits' | 'auto' | 'dont_ask' | 'full_access';
  shell?: 'disabled' | 'sandboxed' | 'unrestricted';
  openaiProtocol?: 'chat_completions' | 'responses';
  allow?: string[];
  ask?: string[];
  deny?: string[];
  onEvent?: (event: AgentEvent) => void;
  onUiRequest?: (request: UiRequest) => object | null | undefined | Promise<object | null | undefined>;
}

export interface RunOptions {
  maxTurns?: number;
  onEvent?: (event: AgentEvent) => void;
}

export interface EventStream extends AsyncIterable<AgentEvent> {
  result: Promise<RunResult>;
  abort(): void;
}

export class Session {
  readonly runtime: Runtime;
  model: string;
  run(prompt: string, options?: RunOptions): Promise<RunResult>;
  stream(prompt: string, options?: { maxTurns?: number }): EventStream;
  abort(): void;
  submit(text: string): number;
  /** Revision 25: replace the provider credential in place, also mid-Run. */
  updateCredential(apiKey: string): void;
  describe(): Record<string, unknown>;
  setModel(model: string): void;
  setPermissionMode(mode: NonNullable<SessionOptions['permissionMode']>): void;
  close(): void;
}

export class Runtime {
  constructor(options?: { tools?: string[]; hostTools?: Tool<any>[]; library?: string });
  readonly tools: string[];
  readonly hostTools: Tool<any>[];
  session(model: string, options?: SessionOptions): Session;
  close(): void;
}

export function candidateLibraryPaths(explicit?: string): string[];
