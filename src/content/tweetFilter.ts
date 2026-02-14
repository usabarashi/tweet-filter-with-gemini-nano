import type { TweetData } from '../types/tweet';
import { serviceWorkerClient } from '../shared/messaging/client';
import { domManipulator } from './domManipulator';
import { PROCESSING_CONFIG } from '../shared/constants';
import { logger } from '../shared/logger';

class TweetFilter {
  private processingQueue: TweetData[] = [];
  private isProcessing = false;
  private readonly delayBetweenBatches = PROCESSING_CONFIG.DELAY_BETWEEN_BATCHES;

  async initialize(): Promise<void> {
    // No local initialization needed - service worker handles Gemini session
    logger.log('[TweetFilter] Initialized (delegating to service worker)');
  }

  async processTweet(tweet: TweetData): Promise<void> {
    // Skip only if completely empty
    const hasContent = tweet.textContent.trim() ||
                       (tweet.media && tweet.media.length > 0) ||
                       tweet.quotedTweet;

    if (!hasContent) {
      logger.log('[Tweet Filter] Skipping completely empty tweet');
      domManipulator.markAsProcessed(tweet.element);
      return;
    }

    // Skip already processed tweets
    if (domManipulator.isProcessed(tweet.element)) {
      return;
    }

    this.processingQueue.push(tweet);
    this.processQueue();
  }

  private async processQueue(): Promise<void> {
    if (this.isProcessing) return;
    this.isProcessing = true;

    while (this.processingQueue.length > 0) {
      const tweet = this.processingQueue.shift();
      if (!tweet) continue;

      // Check if tweet has content to evaluate
      const mainText = tweet.textContent.trim();
      const hasQuotedContent = !!(tweet.quotedTweet?.textContent?.trim() || tweet.quotedTweet?.media?.length);

      if (!mainText && !tweet.media?.length && !hasQuotedContent) {
        logger.log('[Tweet Filter] No content to evaluate, showing tweet by default');
        domManipulator.markAsProcessed(tweet.element);
        continue;
      }

      try {
        // Send evaluation request to service worker
        const response = await serviceWorkerClient.evaluateTweet({
          tweetId: tweet.id,
          textContent: tweet.textContent,
          media: tweet.media,
          quotedTweet: tweet.quotedTweet,
        });

        logger.log(
          `[Tweet Filter] ${response.cacheHit ? 'Cache hit' : 'Evaluated'} for tweet ${tweet.id}:`,
          `shouldShow=${response.shouldShow}, time=${response.evaluationTime}ms`
        );

        if (!response.shouldShow) {
          logger.log('[Tweet Filter] Collapsing tweet');
          domManipulator.collapseTweet(tweet.element);
        } else {
          logger.log('[Tweet Filter] Showing tweet');
        }
      } catch (error) {
        logger.error('[Tweet Filter] Failed to evaluate tweet:', error);
        // On error, show the tweet by default
      } finally {
        domManipulator.markAsProcessed(tweet.element);
      }

      // Small delay to prevent overwhelming the messaging system
      await this.delay(this.delayBetweenBatches);
    }

    this.isProcessing = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  destroy(): void {
    this.processingQueue = [];
    // No need to destroy Gemini session - service worker manages it
  }
}

export const tweetFilter = new TweetFilter();
