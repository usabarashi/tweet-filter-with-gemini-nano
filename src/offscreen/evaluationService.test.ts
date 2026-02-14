import { describe, it, expect, beforeEach, vi } from 'vitest';
import { EvaluationService } from './evaluationService';
import type { EvaluationRequest } from './evaluationService';
import { sessionManager } from './sessionManager';

// Mock sessionManager
vi.mock('./sessionManager', () => ({
  sessionManager: {
    waitForInitialization: vi.fn(),
    createClonedSession: vi.fn(),
    isMultimodalEnabled: vi.fn(),
    getFilterCriteria: vi.fn(),
  },
}));

describe('EvaluationService', () => {
  let evaluationService: EvaluationService;
  let mockSession: any;

  beforeEach(() => {
    evaluationService = new EvaluationService();

    // Create mock session
    mockSession = {
      prompt: vi.fn(),
      destroy: vi.fn(),
    };

    // Default mock behavior
    vi.mocked(sessionManager.waitForInitialization).mockResolvedValue(true);
    vi.mocked(sessionManager.createClonedSession).mockResolvedValue(mockSession);
    vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(false);
    vi.mocked(sessionManager.getFilterCriteria).mockReturnValue('technical content');

    // Mock global fetch
    globalThis.fetch = vi.fn();
  });

  describe('Basic evaluation', () => {
    it('should show tweet when text matches criteria', async () => {
      mockSession.prompt.mockResolvedValue('{"show": true}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'This is a technical article about TypeScript',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
      expect(result.evaluationTime).toBeGreaterThanOrEqual(0);
      expect(mockSession.prompt).toHaveBeenCalledOnce();
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });

    it('should hide tweet when text does not match criteria', async () => {
      mockSession.prompt.mockResolvedValue('{"show": false}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'This is a random tweet about nothing',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(false);
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });

    it('should skip evaluation for empty text', async () => {
      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: '   ', // Whitespace only
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true); // show by default when no evaluable content
      expect(mockSession.prompt).not.toHaveBeenCalled();
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });
  });

  describe('Short-circuit evaluation', () => {
    it('should stop at stage 1 if main text matches', async () => {
      mockSession.prompt.mockResolvedValue('{"show": true}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Technical content',
        quotedTweet: {
          textContent: 'Non-technical content',
        },
        media: [{ type: 'image', url: 'https://example.com/image.jpg' }],
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
      // Only main text evaluated (single call)
      expect(mockSession.prompt).toHaveBeenCalledOnce();
    });

    it('should evaluate quoted tweet text if main text does not match', async () => {
      // First call returns false, second returns true
      mockSession.prompt
        .mockResolvedValueOnce('{"show": false}')  // main text
        .mockResolvedValueOnce('{"show": true}');  // quoted text

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Random content',
        quotedTweet: {
          textContent: 'Technical content',
          author: 'techguru',
        },
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
      // Main text + quoted tweet (2 calls)
      expect(mockSession.prompt).toHaveBeenCalledTimes(2);
      // Quoted tweet evaluation should include @author
      expect(mockSession.prompt).toHaveBeenNthCalledWith(
        2,
        expect.stringContaining('@techguru'),
        expect.objectContaining({ signal: expect.any(AbortSignal) })
      );
    });

    it('should evaluate all stages if none match until one does', async () => {
      vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(true);

      // All false until the last image description returns true
      mockSession.prompt
        .mockResolvedValueOnce('{"show": false}')  // main text
        .mockResolvedValueOnce('{"show": false}')  // quoted text
        .mockResolvedValueOnce('A screenshot')     // quoted image description
        .mockResolvedValueOnce('{"show": false}')  // quoted image eval
        .mockResolvedValueOnce('A diagram')        // main image description
        .mockResolvedValueOnce('{"show": true}');  // main image eval

      // Mock fetch
      vi.mocked(globalThis.fetch).mockResolvedValue({
        ok: true,
        blob: () => Promise.resolve(new Blob()),
      } as Response);

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Random content',
        quotedTweet: {
          textContent: 'More random',
          media: [{ type: 'image', url: 'https://example.com/quoted.jpg' }],
        },
        media: [{ type: 'image', url: 'https://example.com/main.jpg' }],
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
      // Main text + quoted text + quoted image description + quoted image eval + main image description + main image eval
      expect(mockSession.prompt).toHaveBeenCalledTimes(6);
    });
  });

  describe('Image processing', () => {
    it('should skip image description if multimodal not enabled', async () => {
      vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(false);
      mockSession.prompt.mockResolvedValue('{"show": false}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Text',
        media: [{ type: 'image', url: 'https://example.com/image.jpg' }],
      };

      await evaluationService.evaluateTweet(request);

      // Image fetch should not be called
      expect(globalThis.fetch).not.toHaveBeenCalled();
      // Text evaluation only (single call)
      expect(mockSession.prompt).toHaveBeenCalledOnce();
    });

    it('should handle image fetch timeout', async () => {
      vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(true);
      mockSession.prompt.mockResolvedValue('{"show": false}');

      // Fetch times out
      vi.mocked(globalThis.fetch).mockImplementation(() => {
        return new Promise((_, reject) => {
          setTimeout(() => reject(new Error('Timeout')), 10);
        });
      });

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: '',
        media: [{ type: 'image', url: 'https://example.com/image.jpg' }],
      };

      const result = await evaluationService.evaluateTweet(request);

      // Show by default when image fetch fails and no text to evaluate
      expect(result.shouldShow).toBe(true);
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });

    it('should handle image fetch failure gracefully', async () => {
      vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(true);
      mockSession.prompt.mockResolvedValue('{"show": false}');

      // Fetch fails
      vi.mocked(globalThis.fetch).mockResolvedValue({
        ok: false,
        status: 404,
      } as Response);

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: '',
        media: [{ type: 'image', url: 'https://example.com/notfound.jpg' }],
      };

      const result = await evaluationService.evaluateTweet(request);

      // Show by default when image cannot be fetched and no text to evaluate
      expect(result.shouldShow).toBe(true);
    });

    it('should process multiple images in parallel', async () => {
      vi.mocked(sessionManager.isMultimodalEnabled).mockReturnValue(true);
      mockSession.prompt
        .mockResolvedValueOnce('{"show": false}')  // main text
        .mockResolvedValueOnce('Image 1')          // image 1 description
        .mockResolvedValueOnce('Image 2')          // image 2 description
        .mockResolvedValueOnce('{"show": true}');  // image eval

      vi.mocked(globalThis.fetch).mockResolvedValue({
        ok: true,
        blob: () => Promise.resolve(new Blob()),
      } as Response);

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Text',
        media: [
          { type: 'image', url: 'https://example.com/image1.jpg' },
          { type: 'image', url: 'https://example.com/image2.jpg' },
        ],
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
      // Fetch should be called twice (in parallel)
      expect(globalThis.fetch).toHaveBeenCalledTimes(2);
    });
  });

  describe('JSON response parsing', () => {
    it('should parse JSON with regex match', async () => {
      mockSession.prompt.mockResolvedValue('Some text {"show": true} more text');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
    });

    it('should parse clean JSON', async () => {
      mockSession.prompt.mockResolvedValue('{"show": false}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(false);
    });

    it('should parse JSON with extra properties', async () => {
      mockSession.prompt.mockResolvedValue('{"show": true, "reason": "matches criteria"}');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
    });

    it('should default to true for invalid JSON', async () => {
      mockSession.prompt.mockResolvedValue('Invalid JSON response');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Defaults to true when parsing fails
      expect(result.shouldShow).toBe(true);
    });

    it('should handle whitespace in JSON', async () => {
      mockSession.prompt.mockResolvedValue('  {"show":  true}  ');

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      expect(result.shouldShow).toBe(true);
    });
  });

  describe('Error handling', () => {
    it('should show tweet when session not initialized', async () => {
      vi.mocked(sessionManager.waitForInitialization).mockResolvedValue(false);

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Default to show when session is not initialized
      expect(result.shouldShow).toBe(true);
      expect(mockSession.prompt).not.toHaveBeenCalled();
    });

    it('should show tweet on evaluation error', async () => {
      mockSession.prompt.mockRejectedValue(new Error('AI Error'));

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Default to show on error
      expect(result.shouldShow).toBe(true);
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });

    it('should destroy session even if destroy fails', async () => {
      mockSession.prompt.mockResolvedValue('{"show": true}');
      mockSession.destroy.mockRejectedValue(new Error('Destroy failed'));

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Should not fail even when destroy fails
      expect(result.shouldShow).toBe(true);
      expect(mockSession.destroy).toHaveBeenCalledOnce();
    });

    it('should handle session creation failure', async () => {
      vi.mocked(sessionManager.createClonedSession).mockRejectedValue(
        new Error('Failed to create session')
      );

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Default to show when session creation fails
      expect(result.shouldShow).toBe(true);
    });
  });

  describe('evaluationTime measurement', () => {
    it('should measure evaluation time', async () => {
      mockSession.prompt.mockImplementation(() => {
        return new Promise((resolve) => {
          setTimeout(() => resolve('{"show": true}'), 50);
        });
      });

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Should take at least 50ms
      expect(result.evaluationTime).toBeGreaterThanOrEqual(50);
    });

    it('should measure time even on error', async () => {
      mockSession.prompt.mockRejectedValue(new Error('Error'));

      const request: EvaluationRequest = {
        tweetId: 'tweet1',
        textContent: 'Test',
      };

      const result = await evaluationService.evaluateTweet(request);

      // Should measure time even on error
      expect(result.evaluationTime).toBeGreaterThanOrEqual(0);
    });
  });
});
