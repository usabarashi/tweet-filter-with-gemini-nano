import { describe, it, expect, beforeEach, vi } from 'vitest';
import { MessageHandler } from './messageHandler';
import { offscreenManager } from './offscreenManager';
import { cacheManager } from './cacheManager';
import type {
  InitRequest,
  EvaluateRequest,
  SessionStatusRequest,
  CacheCheckRequest,
} from '../shared/messaging/types';

// Mock constants
vi.mock('../shared/messaging/constants', () => ({
  MESSAGE_TYPES: {
    INIT_REQUEST: 'INIT_REQUEST',
    INIT_RESPONSE: 'INIT_RESPONSE',
    EVALUATE_REQUEST: 'EVALUATE_REQUEST',
    EVALUATE_RESPONSE: 'EVALUATE_RESPONSE',
    SESSION_STATUS_REQUEST: 'SESSION_STATUS_REQUEST',
    SESSION_STATUS_RESPONSE: 'SESSION_STATUS_RESPONSE',
    CACHE_CHECK_REQUEST: 'CACHE_CHECK_REQUEST',
    CACHE_CHECK_RESPONSE: 'CACHE_CHECK_RESPONSE',
    ERROR: 'ERROR',
  },
}));

// Mock logger
vi.mock('../shared/logger', () => ({
  logger: {
    log: vi.fn(),
    error: vi.fn(),
  },
}));

// Mock OffscreenManager
vi.mock('./offscreenManager', () => ({
  offscreenManager: {
    sendToOffscreen: vi.fn(),
  },
}));

// Mock CacheManager
vi.mock('./cacheManager', () => ({
  cacheManager: {
    get: vi.fn(),
    set: vi.fn(),
    getBatch: vi.fn(),
  },
}));

describe('MessageHandler', () => {
  let messageHandler: MessageHandler;

  beforeEach(() => {
    messageHandler = new MessageHandler();
    vi.clearAllMocks();

    // Setup default mock behaviors
    vi.mocked(cacheManager.set).mockResolvedValue(undefined);
    vi.mocked(cacheManager.get).mockResolvedValue(null);
    vi.mocked(cacheManager.getBatch).mockResolvedValue({});
    vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({} as any);
  });

  describe('Message routing', () => {
    it('should route INIT_REQUEST to handleInitRequest', async () => {
      const message: InitRequest = {
        type: 'INIT_REQUEST',
        requestId: 'req-1',
        timestamp: Date.now(),
        config: {
          prompt: 'technical content',
          outputLanguage: 'en',
        },
      };

      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'INIT_RESPONSE',
        requestId: 'req-1',
        timestamp: Date.now(),
        success: true,
        sessionStatus: {
          isMultimodal: false,
          sessionType: 'text-only',
        },
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('INIT_RESPONSE');
      expect(response.requestId).toBe('req-1');
      expect(vi.mocked(offscreenManager.sendToOffscreen)).toHaveBeenCalledWith({
        type: 'INIT_REQUEST',
        config: message.config,
      });
    });

    it('should route EVALUATE_REQUEST to handleEvaluateRequest', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-2',
        timestamp: Date.now(),
        tweetId: 'tweet-123',
        textContent: 'Test tweet',
      };

      vi.mocked(cacheManager.get).mockResolvedValue(null); // Cache miss
      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'EVALUATE_RESPONSE',
        requestId: 'req-2',
        timestamp: Date.now(),
        tweetId: 'tweet-123',
        shouldShow: true,
        cacheHit: false,
        evaluationTime: 100,
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('EVALUATE_RESPONSE');
      expect(response.requestId).toBe('req-2');
      expect(vi.mocked(cacheManager.get)).toHaveBeenCalledWith('tweet-123');
    });

    it('should route SESSION_STATUS_REQUEST to handleSessionStatusRequest', async () => {
      const message: SessionStatusRequest = {
        type: 'SESSION_STATUS_REQUEST',
        requestId: 'req-3',
        timestamp: Date.now(),
      };

      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'SESSION_STATUS_RESPONSE',
        requestId: 'req-3',
        timestamp: Date.now(),
        initialized: true,
        isMultimodal: false,
        currentConfig: null,
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('SESSION_STATUS_RESPONSE');
      expect(response.requestId).toBe('req-3');
      expect(vi.mocked(offscreenManager.sendToOffscreen)).toHaveBeenCalledWith({
        type: 'SESSION_STATUS_REQUEST',
      });
    });

    it('should route CACHE_CHECK_REQUEST to handleCacheCheckRequest', async () => {
      const message: CacheCheckRequest = {
        type: 'CACHE_CHECK_REQUEST',
        requestId: 'req-4',
        timestamp: Date.now(),
        tweetIds: ['tweet1', 'tweet2'],
      };

      vi.mocked(cacheManager.getBatch).mockResolvedValue({
        tweet1: true,
        tweet2: false,
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('CACHE_CHECK_RESPONSE');
      expect(response.requestId).toBe('req-4');
      expect(vi.mocked(cacheManager.getBatch)).toHaveBeenCalledWith(['tweet1', 'tweet2']);
    });
  });

  describe('Error handling', () => {
    it('should return error response for unknown message type', async () => {
      const message: any = {
        type: 'UNKNOWN_TYPE',
        requestId: 'req-5',
        timestamp: Date.now(),
      };

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('ERROR');
      expect(response.requestId).toBe('req-5');
      expect((response as any).error).toContain('Unknown message type');
    });

    it('should catch and return error response for exceptions', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-6',
        timestamp: Date.now(),
        tweetId: 'tweet-123',
        textContent: 'Test',
      };

      vi.mocked(cacheManager.get).mockRejectedValue(new Error('Cache error'));

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('ERROR');
      expect(response.requestId).toBe('req-6');
      expect((response as any).error).toBe('Cache error');
    });

    it('should handle non-Error exceptions', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-7',
        timestamp: Date.now(),
        tweetId: 'tweet-123',
        textContent: 'Test',
      };

      vi.mocked(cacheManager.get).mockRejectedValue('String error');

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('ERROR');
      expect((response as any).error).toBe('String error');
    });
  });

  describe('Cache behavior', () => {
    it('should return cached result on cache hit', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-8',
        timestamp: Date.now(),
        tweetId: 'tweet-cached',
        textContent: 'Test',
      };

      vi.mocked(cacheManager.get).mockResolvedValue(true); // Cache hit

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('EVALUATE_RESPONSE');
      expect((response as any).shouldShow).toBe(true);
      expect((response as any).cacheHit).toBe(true);
      expect((response as any).evaluationTime).toBe(0);
      expect(vi.mocked(offscreenManager.sendToOffscreen)).not.toHaveBeenCalled(); // Should not forward to offscreen
    });

    it('should forward to offscreen on cache miss', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-9',
        timestamp: Date.now(),
        tweetId: 'tweet-new',
        textContent: 'Test tweet',
        media: [{ type: 'image', url: 'https://example.com/image.jpg' }],
      };

      vi.mocked(cacheManager.get).mockResolvedValue(null); // Cache miss
      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'EVALUATE_RESPONSE',
        requestId: 'req-9',
        timestamp: Date.now(),
        tweetId: 'tweet-new',
        shouldShow: false,
        cacheHit: false,
        evaluationTime: 150,
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('EVALUATE_RESPONSE');
      expect((response as any).shouldShow).toBe(false);
      expect((response as any).cacheHit).toBe(false);
      expect(vi.mocked(offscreenManager.sendToOffscreen)).toHaveBeenCalledWith({
        type: 'EVALUATE_REQUEST',
        tweetId: 'tweet-new',
        textContent: 'Test tweet',
        media: message.media,
        quotedTweet: undefined,
      });
    });

    it('should cache evaluation result after offscreen response', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-10',
        timestamp: Date.now(),
        tweetId: 'tweet-to-cache',
        textContent: 'Test',
      };

      vi.mocked(cacheManager.get).mockResolvedValue(null);
      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'EVALUATE_RESPONSE',
        requestId: 'req-10',
        timestamp: Date.now(),
        tweetId: 'tweet-to-cache',
        shouldShow: true,
        cacheHit: false,
        evaluationTime: 100,
      });
      vi.mocked(cacheManager.set).mockResolvedValue(undefined);

      await messageHandler.handleMessage(message);

      // Cache set is awaited in the handler, so it completes before the response is returned
      expect(vi.mocked(cacheManager.set)).toHaveBeenCalledWith('tweet-to-cache', true);
    });

    it('should not fail if cache set fails', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-11',
        timestamp: Date.now(),
        tweetId: 'tweet-fail-cache',
        textContent: 'Test',
      };

      vi.mocked(cacheManager.get).mockResolvedValue(null);
      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'EVALUATE_RESPONSE',
        requestId: 'req-11',
        timestamp: Date.now(),
        tweetId: 'tweet-fail-cache',
        shouldShow: true,
        cacheHit: false,
        evaluationTime: 100,
      });
      vi.mocked(cacheManager.set).mockRejectedValue(new Error('Cache set failed'));

      const response = await messageHandler.handleMessage(message);

      // Should still return success even if cache set fails
      expect(response.type).toBe('EVALUATE_RESPONSE');
      expect((response as any).shouldShow).toBe(true);
    });
  });

  describe('Request forwarding', () => {
    it('should forward INIT_REQUEST with config to offscreen', async () => {
      const message: InitRequest = {
        type: 'INIT_REQUEST',
        requestId: 'req-12',
        timestamp: Date.now(),
        config: {
          prompt: 'machine learning',
          outputLanguage: 'ja',
        },
      };

      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'INIT_RESPONSE',
        requestId: 'req-12',
        timestamp: Date.now(),
        success: true,
        sessionStatus: {
          isMultimodal: false,
          sessionType: 'text-only',
        },
      });

      await messageHandler.handleMessage(message);

      expect(vi.mocked(offscreenManager.sendToOffscreen)).toHaveBeenCalledWith({
        type: 'INIT_REQUEST',
        config: {
          prompt: 'machine learning',
          outputLanguage: 'ja',
        },
      });
    });

    it('should forward EVALUATE_REQUEST with all tweet data', async () => {
      const message: EvaluateRequest = {
        type: 'EVALUATE_REQUEST',
        requestId: 'req-13',
        timestamp: Date.now(),
        tweetId: 'tweet-complex',
        textContent: 'Main tweet text',
        media: [
          { type: 'image', url: 'https://example.com/img1.jpg' },
          { type: 'image', url: 'https://example.com/img2.jpg' },
        ],
        quotedTweet: {
          textContent: 'Quoted tweet text',
          author: '@quotedUser',
          media: [{ type: 'image', url: 'https://example.com/quoted.jpg' }],
        },
      };

      vi.mocked(cacheManager.get).mockResolvedValue(null);
      vi.mocked(offscreenManager.sendToOffscreen).mockResolvedValue({
        type: 'EVALUATE_RESPONSE',
        requestId: 'req-13',
        timestamp: Date.now(),
        tweetId: 'tweet-complex',
        shouldShow: true,
        cacheHit: false,
        evaluationTime: 200,
      });

      await messageHandler.handleMessage(message);

      expect(vi.mocked(offscreenManager.sendToOffscreen)).toHaveBeenCalledWith({
        type: 'EVALUATE_REQUEST',
        tweetId: 'tweet-complex',
        textContent: 'Main tweet text',
        media: message.media,
        quotedTweet: message.quotedTweet,
      });
    });
  });

  describe('CACHE_CHECK_REQUEST', () => {
    it('should return batch cache results', async () => {
      const message: CacheCheckRequest = {
        type: 'CACHE_CHECK_REQUEST',
        requestId: 'req-14',
        timestamp: Date.now(),
        tweetIds: ['tweet1', 'tweet2', 'tweet3'],
      };

      vi.mocked(cacheManager.getBatch).mockResolvedValue({
        tweet1: true,
        tweet3: false,
        // tweet2 not in cache
      });

      const response = await messageHandler.handleMessage(message);

      expect(response.type).toBe('CACHE_CHECK_RESPONSE');
      expect((response as any).results).toEqual({
        tweet1: true,
        tweet3: false,
      });
    });

    it('should return empty results if no tweets cached', async () => {
      const message: CacheCheckRequest = {
        type: 'CACHE_CHECK_REQUEST',
        requestId: 'req-15',
        timestamp: Date.now(),
        tweetIds: ['new1', 'new2'],
      };

      vi.mocked(cacheManager.getBatch).mockResolvedValue({});

      const response = await messageHandler.handleMessage(message);

      expect((response as any).results).toEqual({});
    });
  });
});
