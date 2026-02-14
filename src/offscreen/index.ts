import type {
  Message,
  InitRequest,
  InitResponse,
  EvaluateRequest,
  EvaluateResponse,
  SessionStatusRequest,
  SessionStatusResponse,
  ReinitRequest,
} from '../shared/messaging/types';
import { MESSAGE_TYPES } from '../shared/messaging/constants';
import { sessionManager } from './sessionManager';
import { evaluationService, type EvaluationRequest, type EvaluationResult } from './evaluationService';
import { EvaluationQueue } from './evaluationQueue';
import { logger } from '../shared/logger';

// Initialize logger
logger.initialize();

logger.log('[Offscreen] Offscreen document initialized');

// Create evaluation queue to serialize requests
const evaluationQueue = new EvaluationQueue<EvaluationRequest, EvaluationResult>(
  (request) => evaluationService.evaluateTweet(request)
);

// Handle messages from Service Worker only (ignore content script messages)
chrome.runtime.onMessage.addListener((message: Message, sender, sendResponse) => {
  // Content scripts have sender.tab; service worker does not
  if (sender.tab) {
    return false;
  }

  logger.log('[Offscreen] Received message:', message.type);

  // Handle message asynchronously
  handleMessage(message).then(sendResponse);

  // Return true to indicate we'll send response asynchronously
  return true;
});

async function handleMessage(message: Message): Promise<Message> {
  try {
    switch (message.type) {
      case MESSAGE_TYPES.INIT_REQUEST:
        return await handleInitRequest(message as InitRequest);

      case MESSAGE_TYPES.EVALUATE_REQUEST:
        return await handleEvaluateRequest(message as EvaluateRequest);

      case MESSAGE_TYPES.SESSION_STATUS_REQUEST:
        return await handleSessionStatusRequest(message as SessionStatusRequest);

      case MESSAGE_TYPES.REINIT_REQUEST:
        return await handleReinitRequest(message as ReinitRequest);

      default:
        return {
          type: MESSAGE_TYPES.ERROR,
          requestId: message.requestId,
          timestamp: Date.now(),
          error: `Unknown message type: ${message.type}`,
        };
    }
  } catch (error) {
    logger.error('[Offscreen] Error handling message:', error);
    return {
      type: MESSAGE_TYPES.ERROR,
      requestId: message.requestId,
      timestamp: Date.now(),
      error: error instanceof Error ? error.message : String(error),
      originalRequestId: message.requestId,
    };
  }
}

async function handleInitRequest(message: InitRequest): Promise<InitResponse> {
  logger.log('[Offscreen] Handling INIT_REQUEST');

  const success = await sessionManager.initialize(message.config);

  return {
    type: MESSAGE_TYPES.INIT_RESPONSE,
    requestId: message.requestId,
    timestamp: Date.now(),
    success,
    sessionStatus: {
      isMultimodal: sessionManager.isMultimodalEnabled(),
      sessionType: sessionManager.getSessionType(),
    },
  };
}

async function handleEvaluateRequest(message: EvaluateRequest): Promise<EvaluateResponse> {
  logger.log('[Offscreen] Handling EVALUATE_REQUEST for tweet:', message.tweetId);

  try {
    // Queue the evaluation to prevent overloading the AI session
    const result = await evaluationQueue.enqueue({
      tweetId: message.tweetId,
      textContent: message.textContent,
      media: message.media,
      quotedTweet: message.quotedTweet,
    });

    return {
      type: MESSAGE_TYPES.EVALUATE_RESPONSE,
      requestId: message.requestId,
      timestamp: Date.now(),
      tweetId: message.tweetId,
      shouldShow: result.shouldShow,
      cacheHit: false, // Offscreen doesn't know about cache
      evaluationTime: result.evaluationTime,
    };
  } catch (error) {
    logger.error('[Offscreen] Evaluation failed for tweet:', message.tweetId, error);
    // Return EvaluateResponse (not ErrorMessage) to match the expected return type
    return {
      type: MESSAGE_TYPES.EVALUATE_RESPONSE,
      requestId: message.requestId,
      timestamp: Date.now(),
      tweetId: message.tweetId,
      shouldShow: true, // Show tweet by default on error
      cacheHit: false,
      evaluationTime: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

async function handleSessionStatusRequest(message: SessionStatusRequest): Promise<SessionStatusResponse> {
  logger.log('[Offscreen] Handling SESSION_STATUS_REQUEST');

  return {
    type: MESSAGE_TYPES.SESSION_STATUS_RESPONSE,
    requestId: message.requestId,
    timestamp: Date.now(),
    initialized: sessionManager.isInitialized(),
    isMultimodal: sessionManager.isMultimodalEnabled(),
    currentConfig: sessionManager.getCurrentConfig(),
  };
}

async function handleReinitRequest(message: ReinitRequest): Promise<InitResponse> {
  logger.log('[Offscreen] Handling REINIT_REQUEST');

  // Destroy old session and initialize with new config
  await sessionManager.destroy();

  // Clear evaluation queue
  evaluationQueue.clear();

  const success = await sessionManager.initialize(message.config);

  return {
    type: MESSAGE_TYPES.INIT_RESPONSE,
    requestId: message.requestId,
    timestamp: Date.now(),
    success,
    sessionStatus: {
      isMultimodal: sessionManager.isMultimodalEnabled(),
      sessionType: sessionManager.getSessionType(),
    },
  };
}

logger.log('[Offscreen] Message handlers registered');
