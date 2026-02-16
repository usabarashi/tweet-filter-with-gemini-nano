// Ambient type declarations for Gemini Nano API

export type GeminiAvailability = 'available' | 'downloading' | 'downloadable' | 'after-download' | 'unavailable';

declare global {
  interface LanguageModelParams {
    defaultTopK: number;
    maxTopK: number;
    defaultTemperature: number;
    maxTemperature: number;
  }

  interface LanguageModelCreateOptions {
    temperature?: number;
    topK?: number;
    signal?: AbortSignal;
    initialPrompts?: Array<{
      role: 'system' | 'user' | 'assistant';
      content: string;
    }>;
    monitor?: (monitor: LanguageModelDownloadMonitor) => void;
    expectedInputs?: Array<{ type: string }>;
    expectedOutputs?: Array<{ type: string; languages?: string[] }>;
  }

  interface LanguageModelDownloadMonitor {
    addEventListener(
      type: 'downloadprogress',
      callback: (event: { loaded: number }) => void
    ): void;
  }

  interface LanguageModelSession {
    prompt(text: string, options?: { signal?: AbortSignal }): Promise<string>;
    prompt(messages: Array<{ role: string; content: Array<{ type: 'text'; value: string } | { type: 'image'; value: Blob }> }>, options?: { signal?: AbortSignal }): Promise<string>;
    promptStreaming(text: string): ReadableStream<string>;
    destroy(): Promise<void>;
    inputUsage: number;
    inputQuota: number;
    clone(options?: { signal?: AbortSignal }): Promise<LanguageModelSession>;
  }

  interface LanguageModel {
    availability(options?: LanguageModelCreateOptions): Promise<GeminiAvailability>;
    create(options?: LanguageModelCreateOptions): Promise<LanguageModelSession>;
    params(): Promise<LanguageModelParams>;
  }

  const LanguageModel: LanguageModel;
}
