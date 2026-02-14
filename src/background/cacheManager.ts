import { logger } from '../shared/logger';

const CACHE_KEY = 'tweet-filter-cache';
const ORDER_KEY = 'tweet-filter-cache-order';

interface CacheData {
  [tweetId: string]: boolean;
}

export class EvaluationCacheManager {
  private readonly MAX_CACHE_SIZE = 500;
  private _lock: Promise<void> = Promise.resolve(); // Mutex for race condition prevention

  /**
   * Acquire lock to prevent race conditions on storage operations
   * Returns a release function that must be called in finally block
   */
  private async acquireLock(): Promise<() => void> {
    let releaseLock: () => void;

    // Create next lock promise
    const nextLock = new Promise<void>((resolve) => {
      releaseLock = resolve;
    });

    // Wait for previous lock to be released
    const previousLock = this._lock;
    this._lock = nextLock; // Set our lock for the next caller

    await previousLock;

    return releaseLock!;
  }

  async get(tweetId: string): Promise<boolean | null> {
    const release = await this.acquireLock();

    try {
      const result = await chrome.storage.session.get([CACHE_KEY, ORDER_KEY]);
      const cache: CacheData = (result[CACHE_KEY] || {}) as CacheData;

      if (!(tweetId in cache)) {
        return null;
      }

      // Update access order for LRU in-place (single storage write)
      const order: string[] = (result[ORDER_KEY] || []) as string[];
      const index = order.indexOf(tweetId);
      if (index > -1) {
        order.splice(index, 1);
      }
      order.push(tweetId);
      await chrome.storage.session.set({ [ORDER_KEY]: order });

      return cache[tweetId];
    } catch (error) {
      logger.error('[CacheManager] Failed to get from cache:', error);
      return null;
    } finally {
      release();
    }
  }

  async set(tweetId: string, shouldShow: boolean): Promise<void> {
    const release = await this.acquireLock();

    try {
      const result = await chrome.storage.session.get([CACHE_KEY, ORDER_KEY]);
      const cache: CacheData = (result[CACHE_KEY] || {}) as CacheData;
      const order: string[] = (result[ORDER_KEY] || []) as string[];

      // If cache is full and this is a new entry, evict LRU
      const isNewEntry = !(tweetId in cache);
      if (Object.keys(cache).length >= this.MAX_CACHE_SIZE && isNewEntry) {
        this.evictLRULocked(cache, order);
      }

      // Set cache value
      cache[tweetId] = shouldShow;

      // Update access order
      const index = order.indexOf(tweetId);
      if (index > -1) {
        order.splice(index, 1);
      }
      order.push(tweetId);

      // Save to storage
      await chrome.storage.session.set({
        [CACHE_KEY]: cache,
        [ORDER_KEY]: order,
      });

      logger.log(`[CacheManager] Cached result for tweet ${tweetId}: ${shouldShow}`);
    } catch (error) {
      logger.error('[CacheManager] Failed to set cache:', error);
    } finally {
      release();
    }
  }

  async has(tweetId: string): Promise<boolean> {
    // Read-only: no lock needed. May return stale data during concurrent writes (acceptable for cache).
    try {
      const result = await chrome.storage.session.get(CACHE_KEY);
      const cache: CacheData = (result[CACHE_KEY] || {}) as CacheData;
      return tweetId in cache;
    } catch (error) {
      logger.error('[CacheManager] Failed to check cache:', error);
      return false;
    }
  }

  async getBatch(tweetIds: string[]): Promise<Record<string, boolean>> {
    // Read-only: no lock needed. May return stale data during concurrent writes (acceptable for cache).
    try {
      const result = await chrome.storage.session.get(CACHE_KEY);
      const cache: CacheData = (result[CACHE_KEY] || {}) as CacheData;
      const results: Record<string, boolean> = {};

      for (const id of tweetIds) {
        if (id in cache) {
          results[id] = cache[id];
        }
      }

      return results;
    } catch (error) {
      logger.error('[CacheManager] Failed to get batch from cache:', error);
      return {};
    }
  }

  async clear(): Promise<void> {
    const release = await this.acquireLock();

    try {
      await chrome.storage.session.remove([CACHE_KEY, ORDER_KEY]);
      logger.log('[CacheManager] Cache cleared');
    } catch (error) {
      logger.error('[CacheManager] Failed to clear cache:', error);
    } finally {
      release();
    }
  }

  async getSize(): Promise<number> {
    // Read-only: no lock needed. May return stale data during concurrent writes (acceptable for cache).
    try {
      const result = await chrome.storage.session.get(CACHE_KEY);
      const cache: CacheData = (result[CACHE_KEY] || {}) as CacheData;
      return Object.keys(cache).length;
    } catch (error) {
      logger.error('[CacheManager] Failed to get cache size:', error);
      return 0;
    }
  }

  async getStats(): Promise<{ size: number; maxSize: number }> {
    const size = await this.getSize();
    return {
      size,
      maxSize: this.MAX_CACHE_SIZE,
    };
  }

  /**
   * Evict LRU entry - must be called within a lock
   * Modifies cache and order in-place
   */
  private evictLRULocked(cache: CacheData, order: string[]): void {
    if (order.length === 0) {
      // Fallback: remove first key
      const keys = Object.keys(cache);
      if (keys.length > 0) {
        delete cache[keys[0]];
        logger.log(`[CacheManager] Evicted entry (fallback): ${keys[0]}`);
      }
      return;
    }

    const lruKey = order.shift()!;
    delete cache[lruKey];
    logger.log(`[CacheManager] Evicted LRU entry: ${lruKey}`);
  }
}

export const cacheManager = new EvaluationCacheManager();
