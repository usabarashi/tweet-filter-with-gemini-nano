import type { TweetData } from '../types/tweet';
import type { OutputLanguage } from '../types/storage';
import { geminiNano } from '../shared/geminiNano';
import { domManipulator } from './domManipulator';
import { PROCESSING_CONFIG } from '../shared/constants';
import { storage } from '../shared/storage';
import { logger } from '../shared/logger';

class TweetFilter {
  private processingQueue: TweetData[] = [];
  private isProcessing = false;
  private readonly delayBetweenBatches = PROCESSING_CONFIG.DELAY_BETWEEN_BATCHES;
  private evaluationCache = new Map<string, boolean>();
  private readonly MAX_CACHE_SIZE = 500;

  async initialize(prompt: string, outputLanguage: OutputLanguage = 'en'): Promise<boolean> {
    const success = await geminiNano.initialize(prompt, false, undefined, outputLanguage);
    if (!success) {
      logger.warn('[Tweet Filter] Failed to initialize Gemini Nano');
    }
    return success;
  }

  async processTweet(tweet: TweetData): Promise<void> {
    // Skip only if completely empty (no text, no media, no quoted tweet)
    const hasContent = tweet.textContent.trim() ||
                       (tweet.media && tweet.media.length > 0) ||
                       tweet.quotedTweet;

    if (!hasContent) {
      logger.log('[Tweet Filter] ⏭️ Skipping completely empty tweet');
      domManipulator.markAsProcessed(tweet.element);
      return;
    }

    // Skip already processed tweets
    if (domManipulator.isProcessed(tweet.element)) {
      return;
    }

    // Check cache for previously evaluated tweets
    if (this.evaluationCache.has(tweet.id)) {
      const shouldShow = this.evaluationCache.get(tweet.id)!;
      logger.log('[Tweet Filter] 💾 Using cached result for tweet:', tweet.id, '- shouldShow:', shouldShow);
      if (!shouldShow) {
        domManipulator.collapseTweet(tweet.element);
      }
      domManipulator.markAsProcessed(tweet.element);
      return;
    }

    this.processingQueue.push(tweet);
    this.processQueue();
  }

  private async processQueue(): Promise<void> {
    if (this.isProcessing) return;
    this.isProcessing = true;

    // Initialize base session once before processing queue
    const config = await storage.getFilterConfig();
    const success = await geminiNano.initialize(
      config.prompt,
      false,
      undefined,
      config.outputLanguage
    );

    if (!success) {
      logger.error('[Tweet Filter] Failed to initialize base session');
      this.isProcessing = false;
      return;
    }

    while (this.processingQueue.length > 0) {
      const tweet = this.processingQueue.shift();
      if (!tweet) continue;

      // Check if tweet has content to evaluate before creating session
      const mainText = tweet.textContent.trim();
      const hasQuotedContent = tweet.quotedTweet && (tweet.quotedTweet.textContent.trim() || (tweet.quotedTweet.media && tweet.quotedTweet.media.length > 0));

      if (!mainText && (!tweet.media || tweet.media.length === 0) && !hasQuotedContent) {
        logger.log('[Tweet Filter] ⚠️ No content to evaluate, showing tweet by default');
        domManipulator.markAsProcessed(tweet.element);
        continue;
      }

      let clonedSession: LanguageModelSession | null = null;

      try {
        // Create cloned session for this tweet
        clonedSession = await geminiNano.createClonedSession();

        // Evaluate text and images with short-circuit evaluation
        let shouldShow = false;

        // Stage 1: Evaluate main text only
        if (mainText) {
          shouldShow = await geminiNano.evaluateText(mainText, clonedSession);
        }

        // Stage 2: If main text didn't match, evaluate quoted tweet text only
        if (!shouldShow && tweet.quotedTweet) {
          const quotedText = tweet.quotedTweet.textContent.trim();
          if (quotedText) {
            const quotedAuthor = tweet.quotedTweet.author ? `@${tweet.quotedTweet.author}` : 'someone';
            const quotedContent = `[Quoting ${quotedAuthor}: ${quotedText}]`;
            shouldShow = await geminiNano.evaluateText(quotedContent, clonedSession);
          }
        }

        // Stage 3: If text didn't match, evaluate quoted tweet images
        if (!shouldShow && tweet.quotedTweet?.media && tweet.quotedTweet.media.length > 0) {
          const quotedDescriptions = await geminiNano.describeImages(tweet.quotedTweet.media, clonedSession);
          if (quotedDescriptions.length > 0) {
            const quotedImageText = '[Images in quoted tweet: ' + quotedDescriptions.join('; ') + ']';
            shouldShow = await geminiNano.evaluateText(quotedImageText, clonedSession);
          }
        }

        // Stage 4: If still didn't match, evaluate main tweet images
        if (!shouldShow && tweet.media && tweet.media.length > 0) {
          const descriptions = await geminiNano.describeImages(tweet.media, clonedSession);
          if (descriptions.length > 0) {
            const imageText = '[Images in this tweet: ' + descriptions.join('; ') + ']';
            shouldShow = await geminiNano.evaluateText(imageText, clonedSession);
          }
        }

        // Cache the evaluation result
        this.addToCache(tweet.id, shouldShow);

        if (!shouldShow) {
          logger.log('[Tweet Filter] 🙈 Collapsing tweet');
          domManipulator.collapseTweet(tweet.element);
        } else {
          logger.log('[Tweet Filter] 👀 Showing tweet');
        }
      } catch (error) {
        logger.error('[Tweet Filter] Failed to evaluate tweet:', error);
        // On error, show the tweet by default
      } finally {
        // Always clean up resources
        if (clonedSession) {
          try {
            await clonedSession.destroy();
          } catch (destroyError) {
            logger.error('[Tweet Filter] Failed to destroy cloned session:', destroyError);
          }
        }
        domManipulator.markAsProcessed(tweet.element);
      }

      // Small delay to prevent overwhelming the API
      await this.delay(this.delayBetweenBatches);
    }

    this.isProcessing = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  private addToCache(id: string, value: boolean): void {
    if (this.evaluationCache.size >= this.MAX_CACHE_SIZE) {
      const firstKey = this.evaluationCache.keys().next().value;
      if (firstKey !== undefined) {
        this.evaluationCache.delete(firstKey);
      }
    }
    this.evaluationCache.set(id, value);
  }

  async destroy(): Promise<void> {
    this.processingQueue = [];
    this.evaluationCache.clear();
    await geminiNano.destroy();
  }
}

export const tweetFilter = new TweetFilter();
