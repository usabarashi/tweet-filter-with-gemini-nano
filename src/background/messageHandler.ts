import type {
  Message,
  InitRequest,
  InitResponse,
  EvaluateRequest,
  EvaluateResponse,
  SessionStatusRequest,
  SessionStatusResponse,
  CacheCheckRequest,
  CacheCheckResponse,
} from '../shared/messaging/types';
import { MESSAGE_TYPES } from '../shared/messaging/constants';
import { offscreenManager } from './offscreenManager';
import { cacheManager } from './cacheManager';
import { logger } from '../shared/logger';

export class MessageHandler {
  async handleMessage(message: Message): Promise<Message> {
    try {
      switch (message.type) {
        case MESSAGE_TYPES.INIT_REQUEST:
          return await this.handleInitRequest(message as InitRequest);

        case MESSAGE_TYPES.EVALUATE_REQUEST:
          return await this.handleEvaluateRequest(message as EvaluateRequest);

        case MESSAGE_TYPES.SESSION_STATUS_REQUEST:
          return await this.handleSessionStatusRequest(message as SessionStatusRequest);

        case MESSAGE_TYPES.CACHE_CHECK_REQUEST:
          return await this.handleCacheCheckRequest(message as CacheCheckRequest);

        default:
          return this.createErrorResponse(message.requestId, `Unknown message type: ${message.type}`);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      return this.createErrorResponse(message.requestId, errorMessage);
    }
  }

  private async handleInitRequest(message: InitRequest): Promise<InitResponse> {
    logger.log('[MessageHandler] Handling INIT_REQUEST');

    // Forward to offscreen document
    const response = await offscreenManager.sendToOffscreen<InitResponse>({
      type: MESSAGE_TYPES.INIT_REQUEST,
      config: message.config,
    } as any);

    return {
      ...response,
      requestId: message.requestId,
    };
  }

  private async handleEvaluateRequest(message: EvaluateRequest): Promise<EvaluateResponse> {
    logger.log('[MessageHandler] Handling EVALUATE_REQUEST for tweet:', message.tweetId);

    // Check cache first
    const cached = await cacheManager.get(message.tweetId);
    if (cached !== null) {
      logger.log('[MessageHandler] Cache hit for tweet:', message.tweetId);
      return {
        type: MESSAGE_TYPES.EVALUATE_RESPONSE,
        requestId: message.requestId,
        timestamp: Date.now(),
        tweetId: message.tweetId,
        shouldShow: cached,
        cacheHit: true,
        evaluationTime: 0,
      } as EvaluateResponse;
    }

    // Cache miss - forward to offscreen document
    logger.log('[MessageHandler] Cache miss for tweet:', message.tweetId, '- forwarding to offscreen');
    const response = await offscreenManager.sendToOffscreen<EvaluateResponse>({
      type: MESSAGE_TYPES.EVALUATE_REQUEST,
      tweetId: message.tweetId,
      textContent: message.textContent,
      media: message.media,
      quotedTweet: message.quotedTweet,
    } as any);

    // Cache the result (don't await - fire and forget for performance)
    cacheManager.set(message.tweetId, response.shouldShow).catch(err => {
      logger.error('[MessageHandler] Failed to cache result:', err);
    });

    return {
      ...response,
      requestId: message.requestId,
      cacheHit: false,
    };
  }

  private async handleSessionStatusRequest(message: SessionStatusRequest): Promise<SessionStatusResponse> {
    logger.log('[MessageHandler] Handling SESSION_STATUS_REQUEST');

    const response = await offscreenManager.sendToOffscreen<SessionStatusResponse>({
      type: MESSAGE_TYPES.SESSION_STATUS_REQUEST,
    });

    return {
      ...response,
      requestId: message.requestId,
    };
  }

  private async handleCacheCheckRequest(message: CacheCheckRequest): Promise<CacheCheckResponse> {
    logger.log('[MessageHandler] Handling CACHE_CHECK_REQUEST');

    const results = await cacheManager.getBatch(message.tweetIds);

    return {
      type: MESSAGE_TYPES.CACHE_CHECK_RESPONSE,
      requestId: message.requestId,
      timestamp: Date.now(),
      results,
    } as CacheCheckResponse;
  }

  private createErrorResponse(requestId: string, error: string): Message {
    return {
      type: MESSAGE_TYPES.ERROR,
      requestId,
      timestamp: Date.now(),
      error,
    };
  }
}

export const messageHandler = new MessageHandler();
