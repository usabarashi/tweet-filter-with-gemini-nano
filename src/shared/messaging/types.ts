import type { OutputLanguage } from '../../types/storage';
import type { MediaData, QuotedTweet } from '../../types/tweet';

export type { QuotedTweet };

// Message Types
export type MessageType =
  | 'INIT_REQUEST'
  | 'INIT_RESPONSE'
  | 'EVALUATE_REQUEST'
  | 'EVALUATE_RESPONSE'
  | 'CACHE_CHECK_REQUEST'
  | 'CACHE_CHECK_RESPONSE'
  | 'CONFIG_CHANGED'
  | 'SESSION_STATUS_REQUEST'
  | 'SESSION_STATUS_RESPONSE'
  | 'REINIT_REQUEST'
  | 'ERROR';

// Base message structure
export interface BaseMessage {
  type: MessageType;
  requestId: string;
  timestamp: number;
}

// Initialization
export interface InitRequest extends BaseMessage {
  type: 'INIT_REQUEST';
  config: {
    prompt: string;
    outputLanguage: OutputLanguage;
  };
}

export interface InitResponse extends BaseMessage {
  type: 'INIT_RESPONSE';
  success: boolean;
  sessionStatus: {
    isMultimodal: boolean;
    sessionType: 'multimodal' | 'text-only' | null;
  };
  error?: string;
}

// Tweet Evaluation
export interface EvaluateRequest extends BaseMessage {
  type: 'EVALUATE_REQUEST';
  tweetId: string;
  textContent: string;
  media?: MediaData[];
  quotedTweet?: QuotedTweet;
}

export interface EvaluateResponse extends BaseMessage {
  type: 'EVALUATE_RESPONSE';
  tweetId: string;
  shouldShow: boolean;
  cacheHit: boolean;
  evaluationTime: number;
  error?: string;
}

// Cache Check
export interface CacheCheckRequest extends BaseMessage {
  type: 'CACHE_CHECK_REQUEST';
  tweetIds: string[];
}

export interface CacheCheckResponse extends BaseMessage {
  type: 'CACHE_CHECK_RESPONSE';
  results: Record<string, boolean>;
}

// Config Change Notification
export interface ConfigChangedMessage extends BaseMessage {
  type: 'CONFIG_CHANGED';
  config: {
    enabled: boolean;
    prompt: string;
    outputLanguage: OutputLanguage;
  };
}

// Session Status
export interface SessionStatusRequest extends BaseMessage {
  type: 'SESSION_STATUS_REQUEST';
}

export interface SessionStatusResponse extends BaseMessage {
  type: 'SESSION_STATUS_RESPONSE';
  initialized: boolean;
  isMultimodal: boolean;
  currentConfig: {
    prompt: string;
    outputLanguage: OutputLanguage;
  } | null;
}

// Reinitialization (for config changes)
export interface ReinitRequest extends BaseMessage {
  type: 'REINIT_REQUEST';
  config: {
    prompt: string;
    outputLanguage: OutputLanguage;
  };
}

// Error
export interface ErrorMessage extends BaseMessage {
  type: 'ERROR';
  error: string;
  originalRequestId?: string;
}

// Distributive Omit for union types (standard Omit collapses unions)
export type DistributiveOmit<T, K extends keyof any> = T extends any ? Omit<T, K> : never;

export type Message =
  | InitRequest
  | InitResponse
  | EvaluateRequest
  | EvaluateResponse
  | CacheCheckRequest
  | CacheCheckResponse
  | ConfigChangedMessage
  | SessionStatusRequest
  | SessionStatusResponse
  | ReinitRequest
  | ErrorMessage;
