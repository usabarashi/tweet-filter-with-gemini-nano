import type { TweetData, MediaData } from '../types/tweet';
import { TWEET_SELECTORS } from '../shared/constants';
import { logger } from '../shared/logger';

type TweetCallback = (tweet: TweetData) => void;

class TweetObserver {
  private observer: MutationObserver | null = null;
  private onTweetDetected: TweetCallback | null = null;

  start(callback: TweetCallback): void {
    this.onTweetDetected = callback;

    // Process existing tweets first
    this.processExistingTweets();

    // Set up observer for new tweets
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node instanceof HTMLElement) {
            this.findAndProcessTweets(node);
          }
        }
      }
    });

    // Observe the main timeline container
    const timeline = document.querySelector('main') ?? document.body;
    this.observer.observe(timeline, {
      childList: true,
      subtree: true,
    });
  }

  stop(): void {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
  }

  private processExistingTweets(): void {
    const tweets = this.findTweetElements(document.body);
    this.processElementList(tweets);
  }

  private findAndProcessTweets(root: HTMLElement): void {
    // Check if root itself is a tweet
    if (this.isTweetElement(root)) {
      this.processTweetElement(root);
      return;
    }

    // Find tweets within the added node
    const tweets = this.findTweetElements(root);
    this.processElementList(tweets);
  }

  private findTweetElements(root: HTMLElement): NodeListOf<Element> {
    for (const selector of TWEET_SELECTORS) {
      const tweets = root.querySelectorAll(selector);
      if (tweets.length > 0) return tweets;
    }
    return root.querySelectorAll('article');
  }

  private isTweetElement(element: HTMLElement): boolean {
    return TWEET_SELECTORS.some((selector) => element.matches(selector));
  }

  private processTweetElement(element: HTMLElement): void {
    if (!element.isConnected) return;

    const tweetId = this.extractTweetId(element);
    const media = this.extractMedia(element);
    const quotedTweet = this.extractQuotedTweet(element);
    const repostInfo = this.extractRepostInfo(element);

    const tweetData: TweetData = {
      id: tweetId,
      element,
      textContent: this.extractTweetText(element),
      author: this.extractAuthor(element),
      media: media.length > 0 ? media : undefined,
      quotedTweet,
      isRepost: repostInfo.isRepost,
      repostedBy: repostInfo.repostedBy,
    };

    logger.log('[Tweet Filter] 🔍 Detected tweet:', {
      id: tweetId,
      author: tweetData.author,
      text: tweetData.textContent.substring(0, 50) + '...',
      mediaCount: media.length,
      hasQuotedTweet: !!quotedTweet,
      isRepost: repostInfo.isRepost,
      repostedBy: repostInfo.repostedBy,
    });

    // Only delay for tweets with media (for lazy loading)
    if (media.length > 0 || (quotedTweet?.media && quotedTweet.media.length > 0)) {
      setTimeout(() => {
        this.onTweetDetected?.(tweetData);
      }, 100);
    } else {
      this.onTweetDetected?.(tweetData);
    }
  }

  private extractTweetId(element: HTMLElement): string {
    // Try to find tweet link with status ID
    const link = element.querySelector('a[href*="/status/"]');
    if (link) {
      const href = link.getAttribute('href') ?? '';
      const match = href.match(/\/status\/(\d+)/);
      if (match) return match[1];
    }
    // Fallback to element position
    return `tweet-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
  }

  private extractTweetText(element: HTMLElement): string {
    const textElement = element.querySelector('[data-testid="tweetText"]');
    return textElement?.textContent?.trim() ?? '';
  }

  private extractAuthor(element: HTMLElement): string | undefined {
    const userElement = element.querySelector('[data-testid="User-Name"]');
    return userElement?.textContent?.trim();
  }

  private extractMedia(element: HTMLElement, excludeQuoted = true): MediaData[] {
    const media: MediaData[] = [];
    const quotedElement = excludeQuoted ? this.findQuotedTweetContainer(element) : null;

    // Get ALL img elements and filter by URL pattern
    const allImages = element.querySelectorAll('img');
    const foundUrls = new Set<string>();

    allImages.forEach((img) => {
      if (!(img instanceof HTMLImageElement)) return;

      // Check if this is a tweet media image (not profile image, emoji, etc.)
      if (!img.src.includes('pbs.twimg.com/media/')) {
        return;
      }

      // Skip if inside quoted tweet
      if (quotedElement && quotedElement.contains(img)) {
        return;
      }

      // Skip duplicates
      if (foundUrls.has(img.src)) {
        return;
      }

      const originalUrl = this.normalizeImageUrl(img.src);
      foundUrls.add(originalUrl);
      media.push({ type: 'image', url: originalUrl });
    });

    return media;
  }

  private extractQuotedTweet(element: HTMLElement): import('../types/tweet').QuotedTweet | undefined {
    const quotedContainer = this.findQuotedTweetContainer(element);
    if (!quotedContainer) {
      return undefined;
    }

    // Extract text from quoted tweet
    // Look for tweetText within the quoted container
    const quotedTextElements = quotedContainer.querySelectorAll('[data-testid="tweetText"]');
    let quotedText = '';

    // If there are multiple tweetText elements, the last one is usually the quoted tweet
    if (quotedTextElements.length > 0) {
      const quotedTextElement = quotedTextElements[quotedTextElements.length - 1];
      quotedText = quotedTextElement.textContent?.trim() || '';
    } else {
      // Fallback: try to get any text content from the quoted container
      // But exclude the main tweet text
      const mainTweetText = element.querySelector('[data-testid="tweetText"]');
      const allText = quotedContainer.textContent?.trim() || '';
      const mainText = mainTweetText?.textContent?.trim() || '';
      quotedText = allText.replace(mainText, '').trim();
    }

    // Extract media from quoted tweet
    const quotedMedia: MediaData[] = [];
    const quotedImages = quotedContainer.querySelectorAll('img[src*="pbs.twimg.com/media"]');
    quotedImages.forEach((img) => {
      if (img instanceof HTMLImageElement) {
        const originalUrl = this.normalizeImageUrl(img.src);
        quotedMedia.push({ type: 'image', url: originalUrl });
      }
    });

    // Extract author from quoted tweet
    const quotedAuthor = quotedContainer.querySelector('[data-testid="User-Name"]')?.textContent?.trim();

    // Only return if we actually found some content
    if (!quotedText && quotedMedia.length === 0) {
      return undefined;
    }

    return {
      textContent: quotedText,
      author: quotedAuthor,
      media: quotedMedia.length > 0 ? quotedMedia : undefined,
    };
  }

  private findQuotedTweetContainer(element: HTMLElement): Element | null {
    return element.querySelector('[data-testid="card.layoutSmall.media"]') ||
           element.querySelector('div[role="link"] article') ||
           element.querySelector('div[role="link"][href*="/status/"]');
  }

  private normalizeImageUrl(url: string): string {
    return url
      .replace(/&name=\w+/, '&name=large')
      .replace(/\?format=(\w+)&name=\w+/, '?format=$1&name=large');
  }

  private processElementList(elements: NodeListOf<Element>): void {
    elements.forEach((element) => {
      if (element instanceof HTMLElement) {
        this.processTweetElement(element);
      }
    });
  }

  private extractRepostInfo(element: HTMLElement): { isRepost: boolean; repostedBy?: string } {
    // Look for repost indicator outside the article element
    // Twitter shows "Username Reposted" or similar text above reposted tweets

    // Try to find the parent container that includes the repost indicator
    let parent = element.parentElement;
    while (parent && parent !== document.body) {
      // Look for repost text indicators
      const repostIndicators = parent.querySelectorAll('[data-testid="socialContext"]');
      for (const indicator of repostIndicators) {
        const text = indicator.textContent?.trim() || '';

        // Check for "Reposted", "retweeted", or localized versions
        if (text.includes('Reposted') || text.includes('retweeted') || text.includes('リポスト')) {
          // Try to extract the username
          const userLink = indicator.querySelector('a[href^="/"]');
          const username = userLink?.textContent?.trim() || undefined;

          return {
            isRepost: true,
            repostedBy: username,
          };
        }
      }

      parent = parent.parentElement;
    }

    return { isRepost: false };
  }
}

export const tweetObserver = new TweetObserver();
