export const MESSAGE_TYPES = {
  INIT_REQUEST: 'INIT_REQUEST',
  INIT_RESPONSE: 'INIT_RESPONSE',
  EVALUATE_REQUEST: 'EVALUATE_REQUEST',
  EVALUATE_RESPONSE: 'EVALUATE_RESPONSE',
  CACHE_CHECK_REQUEST: 'CACHE_CHECK_REQUEST',
  CACHE_CHECK_RESPONSE: 'CACHE_CHECK_RESPONSE',
  CONFIG_CHANGED: 'CONFIG_CHANGED',
  SESSION_STATUS_REQUEST: 'SESSION_STATUS_REQUEST',
  SESSION_STATUS_RESPONSE: 'SESSION_STATUS_RESPONSE',
  REINIT_REQUEST: 'REINIT_REQUEST',
  ERROR: 'ERROR',
} as const;

export const TIMEOUTS = {
  INIT_REQUEST: 30000,        // 30s for initialization
  EVALUATE_REQUEST: 15000,    // 15s for evaluation
  CACHE_CHECK_REQUEST: 1000,  // 1s for cache check
  SESSION_STATUS_REQUEST: 2000, // 2s for status
  IMAGE_FETCH: 5000,           // 5s for image fetch
  PROMPT: 10000,               // 10s for AI prompt inference
} as const;

// Offscreen Document Configuration
export const OFFSCREEN_DOCUMENT = {
  PATH: 'offscreen/index.html',
  REASON: (globalThis as any).chrome?.offscreen?.Reason?.WORKERS ?? 'WORKERS',
  JUSTIFICATION: 'Run Gemini Nano AI processing in a Window context',
} as const;
