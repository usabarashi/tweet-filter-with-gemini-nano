import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { tweetObserver } from './tweetObserver';
import type { TweetData } from '../types/tweet';

// Mock constants
vi.mock('../shared/constants', () => ({
  TWEET_SELECTORS: [
    'article[data-testid="tweet"]',
    'div[data-testid="cellInnerDiv"] article',
    'article[role="article"]',
  ],
}));

// Mock logger
vi.mock('../shared/logger', () => ({
  logger: {
    log: vi.fn(),
    error: vi.fn(),
  },
}));

describe('TweetObserver', () => {
  let callback: (tweet: TweetData) => void;
  let detectedTweets: TweetData[];

  beforeEach(() => {
    // Clear document body
    document.body.innerHTML = '';

    // Mock callback function
    detectedTweets = [];
    callback = vi.fn((tweet: TweetData) => {
      detectedTweets.push(tweet);
    });

    // Mock timers
    vi.useFakeTimers();
  });

  afterEach(() => {
    // Stop observer
    tweetObserver.stop();
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  describe('Observer lifecycle', () => {
    it('should start observing and process existing tweets', async () => {
      // Create existing tweet
      createTweet('123', 'Hello World', 'user1');

      tweetObserver.start(callback);

      // Existing tweet should be processed
      expect(callback).toHaveBeenCalledOnce();
      expect(detectedTweets[0].id).toBe('123');
      expect(detectedTweets[0].textContent).toBe('Hello World');
    });

    it('should stop observing when stopped', () => {
      tweetObserver.start(callback);
      tweetObserver.stop();

      // Add new tweet
      createTweet('123', 'Hello World', 'user1');

      // Should not be detected since observer is stopped
      expect(callback).not.toHaveBeenCalled();
    });

    it('should detect new tweets added to DOM', async () => {
      tweetObserver.start(callback);

      // Add new tweet
      createTweet('456', 'New tweet', 'user2');

      // Process MutationObserver and microtasks
      await Promise.resolve();
      vi.runAllTimers();

      expect(callback).toHaveBeenCalled();
      const newTweet = detectedTweets.find((t) => t.id === '456');
      expect(newTweet).toBeDefined();
      expect(newTweet?.textContent).toBe('New tweet');
    });
  });

  describe('Tweet ID extraction', () => {
    it('should extract tweet ID from status link', () => {
      createTweet('789', 'Test tweet', 'user1');
      tweetObserver.start(callback);

      expect(callback).toHaveBeenCalled();
      expect(detectedTweets[0].id).toBe('789');
    });

    it('should generate fallback ID when no status link found', () => {
      // Tweet without status link
      const article = document.createElement('article');
      article.setAttribute('data-testid', 'tweet');
      article.innerHTML = `
        <div data-testid="tweetText">Test tweet</div>
        <div data-testid="User-Name">@user1</div>
      `;
      document.body.appendChild(article);

      tweetObserver.start(callback);

      expect(callback).toHaveBeenCalled();
      expect(detectedTweets[0].id).toMatch(/^tweet-/);
    });
  });

  describe('Text extraction', () => {
    it('should extract tweet text', () => {
      createTweet('123', 'This is a test tweet', 'user1');
      tweetObserver.start(callback);

      expect(detectedTweets[0].textContent).toBe('This is a test tweet');
    });

    it('should return empty string when no text found', () => {
      const article = document.createElement('article');
      article.setAttribute('data-testid', 'tweet');
      article.innerHTML = `
        <a href="/user1/status/123">Link</a>
        <div data-testid="User-Name">@user1</div>
      `;
      document.body.appendChild(article);

      tweetObserver.start(callback);

      expect(detectedTweets[0].textContent).toBe('');
    });
  });

  describe('Author extraction', () => {
    it('should extract author from User-Name', () => {
      createTweet('123', 'Test', 'John Doe');
      tweetObserver.start(callback);

      expect(detectedTweets[0].author).toBe('John Doe');
    });

    it('should return undefined when author not found', () => {
      const article = document.createElement('article');
      article.setAttribute('data-testid', 'tweet');
      article.innerHTML = `
        <a href="/user1/status/123">Link</a>
        <div data-testid="tweetText">Test</div>
      `;
      document.body.appendChild(article);

      tweetObserver.start(callback);

      expect(detectedTweets[0].author).toBeUndefined();
    });
  });

  describe('Media extraction', () => {
    it('should extract media images', () => {
      createTweetWithMedia('123', 'Tweet with image', 'user1', [
        'https://pbs.twimg.com/media/abc123?format=jpg&name=small',
      ]);

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100); // Wait for media delay

      expect(detectedTweets[0].media).toBeDefined();
      expect(detectedTweets[0].media?.length).toBe(1);
      expect(detectedTweets[0].media?.[0].url).toContain('name=large');
    });

    it('should normalize image URLs to large format', () => {
      createTweetWithMedia('123', 'Tweet', 'user1', [
        'https://pbs.twimg.com/media/abc123?format=jpg&name=small',
      ]);

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100);

      expect(detectedTweets[0].media?.[0].url).toBe(
        'https://pbs.twimg.com/media/abc123?format=jpg&name=large'
      );
    });

    it('should deduplicate identical image URLs (same src)', () => {
      const article = createTweet('123', 'Tweet', 'user1');

      // Add the same src image twice
      const img1 = document.createElement('img');
      img1.src = 'https://pbs.twimg.com/media/abc123?format=jpg&name=small';
      article.appendChild(img1);

      const img2 = document.createElement('img');
      img2.src = 'https://pbs.twimg.com/media/abc123?format=jpg&name=small';
      article.appendChild(img2);

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100);

      // Should be deduplicated to only one since same src (after fix)
      expect(detectedTweets[0].media?.length).toBe(1);
      expect(detectedTweets[0].media?.[0].url).toContain('name=large');
    });

    it('should skip non-media images (profile images, emojis)', () => {
      createTweetWithMedia('123', 'Tweet', 'user1', [
        'https://pbs.twimg.com/profile_images/abc123',
      ]);

      tweetObserver.start(callback);

      // Profile images should be ignored (processed immediately)
      expect(detectedTweets[0].media).toBeUndefined();
    });

    it('should extract multiple media images', () => {
      createTweetWithMedia('123', 'Tweet with multiple images', 'user1', [
        'https://pbs.twimg.com/media/abc123?format=jpg&name=small',
        'https://pbs.twimg.com/media/def456?format=jpg&name=small',
      ]);

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100);

      expect(detectedTweets[0].media?.length).toBe(2);
    });
  });

  describe('Quoted tweet extraction', () => {
    it('should extract quoted tweet text and author', () => {
      createTweetWithQuotedTweet(
        '123',
        'Quoting this',
        'user1',
        'Original tweet content',
        '@originalAuthor'
      );

      tweetObserver.start(callback);

      expect(detectedTweets[0].quotedTweet).toBeDefined();
      expect(detectedTweets[0].quotedTweet?.textContent).toBe('Original tweet content');
      expect(detectedTweets[0].quotedTweet?.author).toBe('@originalAuthor');
    });

    it('should extract quoted tweet media', () => {
      createTweetWithQuotedTweet(
        '123',
        'Quoting',
        'user1',
        'Quoted text',
        '@quotedUser',
        ['https://pbs.twimg.com/media/quoted123?format=jpg&name=small']
      );

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100); // Wait for media delay

      expect(detectedTweets[0].quotedTweet?.media).toBeDefined();
      expect(detectedTweets[0].quotedTweet?.media?.length).toBe(1);
      expect(detectedTweets[0].quotedTweet?.media?.[0].url).toContain('name=large');
    });

    it('should exclude quoted tweet images from main media', () => {
      createTweetWithMediaAndQuotedTweet(
        '123',
        'Quoting',
        'user1',
        ['https://pbs.twimg.com/media/main123?format=jpg&name=small'],
        'Quoted text',
        '@quotedUser',
        ['https://pbs.twimg.com/media/quoted123?format=jpg&name=small']
      );

      tweetObserver.start(callback);
      vi.advanceTimersByTime(100);

      // Main tweet should have only one image
      expect(detectedTweets[0].media?.length).toBe(1);
      expect(detectedTweets[0].media?.[0].url).toContain('main123');

      // Quoted tweet images should be separate
      expect(detectedTweets[0].quotedTweet?.media?.length).toBe(1);
      expect(detectedTweets[0].quotedTweet?.media?.[0].url).toContain('quoted123');
    });

    it('should return undefined when no quoted tweet found', () => {
      createTweet('123', 'Normal tweet', 'user1');
      tweetObserver.start(callback);

      expect(detectedTweets[0].quotedTweet).toBeUndefined();
    });
  });

  describe('Repost detection', () => {
    it('should detect reposted tweets', () => {
      const container = document.createElement('div');
      container.innerHTML = `
        <div data-testid="socialContext">
          <a href="/reposter">Reposter Name</a> Reposted
        </div>
      `;
      const article = createTweet('123', 'Original content', 'user1');
      container.appendChild(article);
      document.body.appendChild(container);

      tweetObserver.start(callback);

      expect(detectedTweets[0].isRepost).toBe(true);
      expect(detectedTweets[0].repostedBy).toBe('Reposter Name');
    });

    it('should detect retweeted tweets', () => {
      const container = document.createElement('div');
      container.innerHTML = `
        <div data-testid="socialContext">
          <a href="/retweeter">User</a> retweeted
        </div>
      `;
      const article = createTweet('123', 'Content', 'user1');
      container.appendChild(article);
      document.body.appendChild(container);

      tweetObserver.start(callback);

      expect(detectedTweets[0].isRepost).toBe(true);
      expect(detectedTweets[0].repostedBy).toBe('User');
    });

    it('should return false when not a repost', () => {
      createTweet('123', 'Original tweet', 'user1');
      tweetObserver.start(callback);

      expect(detectedTweets[0].isRepost).toBe(false);
      expect(detectedTweets[0].repostedBy).toBeUndefined();
    });
  });

  describe('Batch processing', () => {
    it('should delay processing for tweets with media', () => {
      const article = createTweet('123', 'Tweet with image', 'user1');
      const img = document.createElement('img');
      img.src = 'https://pbs.twimg.com/media/abc123?format=jpg&name=small';
      article.appendChild(img);

      tweetObserver.start(callback);

      // Should not be called immediately
      expect(callback).not.toHaveBeenCalled();

      // Should be called after 100ms
      vi.advanceTimersByTime(100);
      expect(callback).toHaveBeenCalledOnce();
    });

    it('should delay processing for tweets with quoted media', () => {
      const article = createTweet('123', 'Quoting', 'user1');
      const quotedContainer = document.createElement('div');
      quotedContainer.setAttribute('data-testid', 'card.layoutSmall.media');
      quotedContainer.innerHTML = `
        <div data-testid="tweetText">Quoted text</div>
        <img src="https://pbs.twimg.com/media/quoted123?format=jpg&name=small" />
      `;
      article.appendChild(quotedContainer);

      tweetObserver.start(callback);

      // Should not be called immediately
      expect(callback).not.toHaveBeenCalled();

      // Should be called after 100ms
      vi.advanceTimersByTime(100);
      expect(callback).toHaveBeenCalledOnce();
    });

    it('should process immediately for text-only tweets', () => {
      createTweet('123', 'Text only', 'user1');
      tweetObserver.start(callback);

      // Should be called immediately (without advancing timers)
      expect(callback).toHaveBeenCalledOnce();
    });
  });

  describe('Edge cases', () => {
    it('should skip disconnected elements', () => {
      const article = createTweet('123', 'Test', 'user1');
      // Remove from document
      article.remove();

      tweetObserver.start(callback);

      // Should not be processed
      expect(callback).not.toHaveBeenCalled();
    });

    it('should handle multiple tweet selectors as fallback', () => {
      // Tweet that does not match the first selector but matches the second
      const cellDiv = document.createElement('div');
      cellDiv.setAttribute('data-testid', 'cellInnerDiv');
      const article = document.createElement('article');
      article.innerHTML = `
        <a href="/user1/status/111">Link</a>
        <div data-testid="tweetText">Tweet from cell</div>
        <div data-testid="User-Name">User1</div>
      `;
      cellDiv.appendChild(article);
      document.body.appendChild(cellDiv);

      tweetObserver.start(callback);

      // Should be detected by the second selector
      expect(callback).toHaveBeenCalledOnce();
      expect(detectedTweets[0].textContent).toBe('Tweet from cell');
    });

    it('should handle tweets without author', () => {
      const article = document.createElement('article');
      article.setAttribute('data-testid', 'tweet');
      article.innerHTML = `
        <a href="/status/123">Link</a>
        <div data-testid="tweetText">Test</div>
      `;
      document.body.appendChild(article);

      tweetObserver.start(callback);

      expect(detectedTweets[0].author).toBeUndefined();
    });

    it('should handle empty media arrays', () => {
      createTweet('123', 'No media', 'user1');
      tweetObserver.start(callback);

      expect(detectedTweets[0].media).toBeUndefined();
    });
  });
});

/**
 * Helper function to create a tweet element with status link
 */
function createTweet(tweetId: string, text: string, author: string): HTMLElement {
  const article = document.createElement('article');
  article.setAttribute('data-testid', 'tweet');
  article.innerHTML = `
    <a href="/user/status/${tweetId}">Link</a>
    <div data-testid="tweetText">${text}</div>
    <div data-testid="User-Name">${author}</div>
  `;
  document.body.appendChild(article);
  return article;
}

/**
 * Helper function to create a tweet with media images
 */
function createTweetWithMedia(
  tweetId: string,
  text: string,
  author: string,
  imageUrls: string[]
): HTMLElement {
  const article = createTweet(tweetId, text, author);
  imageUrls.forEach((url) => {
    const img = document.createElement('img');
    img.src = url;
    article.appendChild(img);
  });
  return article;
}

/**
 * Helper function to create a tweet with quoted tweet
 */
function createTweetWithQuotedTweet(
  tweetId: string,
  text: string,
  author: string,
  quotedText: string,
  quotedAuthor: string,
  quotedImageUrls: string[] = []
): HTMLElement {
  const article = createTweet(tweetId, text, author);
  const quotedContainer = document.createElement('div');
  quotedContainer.setAttribute('data-testid', 'card.layoutSmall.media');

  let quotedHTML = `
    <div data-testid="tweetText">${quotedText}</div>
    <div data-testid="User-Name">${quotedAuthor}</div>
  `;
  quotedContainer.innerHTML = quotedHTML;

  quotedImageUrls.forEach((url) => {
    const img = document.createElement('img');
    img.src = url;
    quotedContainer.appendChild(img);
  });

  article.appendChild(quotedContainer);
  return article;
}

/**
 * Helper function to create a tweet with both main media and quoted tweet with media
 */
function createTweetWithMediaAndQuotedTweet(
  tweetId: string,
  text: string,
  author: string,
  mainImageUrls: string[],
  quotedText: string,
  quotedAuthor: string,
  quotedImageUrls: string[]
): HTMLElement {
  const article = createTweet(tweetId, text, author);

  // Add main media
  mainImageUrls.forEach((url) => {
    const img = document.createElement('img');
    img.src = url;
    article.appendChild(img);
  });

  // Add quoted tweet container
  const quotedContainer = document.createElement('div');
  quotedContainer.setAttribute('data-testid', 'card.layoutSmall.media');
  quotedContainer.innerHTML = `
    <div data-testid="tweetText">${quotedText}</div>
    <div data-testid="User-Name">${quotedAuthor}</div>
  `;

  quotedImageUrls.forEach((url) => {
    const img = document.createElement('img');
    img.src = url;
    quotedContainer.appendChild(img);
  });

  article.appendChild(quotedContainer);
  return article;
}
