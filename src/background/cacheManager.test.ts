import { describe, it, expect, beforeEach, vi } from 'vitest';
import { EvaluationCacheManager } from './cacheManager';
import { mockChromeStorage } from '../test-setup';

describe('EvaluationCacheManager', () => {
  let cacheManager: EvaluationCacheManager;
  let mockStorage: Record<string, any>;

  beforeEach(() => {
    // Create a new instance for each test
    cacheManager = new EvaluationCacheManager();

    // Mock storage (in-memory simulation)
    mockStorage = {};

    // Chrome Storage API mock implementation
    vi.mocked(chrome.storage.session.get).mockImplementation((keys) => {
      const result: any = {};
      if (typeof keys === 'string') {
        result[keys] = mockStorage[keys];
      } else if (Array.isArray(keys)) {
        keys.forEach((key) => {
          result[key] = mockStorage[key];
        });
      } else if (keys === null || keys === undefined) {
        Object.assign(result, mockStorage);
      }
      return Promise.resolve(result);
    });

    vi.mocked(chrome.storage.session.set).mockImplementation((items) => {
      Object.assign(mockStorage, items);
      return Promise.resolve();
    });

    vi.mocked(chrome.storage.session.remove).mockImplementation((keys) => {
      const keysArray = Array.isArray(keys) ? keys : [keys];
      keysArray.forEach((key) => {
        delete mockStorage[key];
      });
      return Promise.resolve();
    });
  });

  describe('Basic operations', () => {
    it('should set and get a cache entry', async () => {
      await cacheManager.set('tweet1', true);

      const result = await cacheManager.get('tweet1');
      expect(result).toBe(true);
    });

    it('should return null for cache miss', async () => {
      const result = await cacheManager.get('nonexistent');
      expect(result).toBe(null);
    });

    it('should check if tweet exists in cache', async () => {
      await cacheManager.set('tweet1', false);

      const exists = await cacheManager.has('tweet1');
      expect(exists).toBe(true);

      const notExists = await cacheManager.has('nonexistent');
      expect(notExists).toBe(false);
    });

    it('should get cache size', async () => {
      expect(await cacheManager.getSize()).toBe(0);

      await cacheManager.set('tweet1', true);
      expect(await cacheManager.getSize()).toBe(1);

      await cacheManager.set('tweet2', false);
      expect(await cacheManager.getSize()).toBe(2);
    });

    it('should get cache stats', async () => {
      await cacheManager.set('tweet1', true);

      const stats = await cacheManager.getStats();
      expect(stats.size).toBe(1);
      expect(stats.maxSize).toBe(500);
    });

    it('should clear cache', async () => {
      await cacheManager.set('tweet1', true);
      await cacheManager.set('tweet2', false);

      expect(await cacheManager.getSize()).toBe(2);

      await cacheManager.clear();

      expect(await cacheManager.getSize()).toBe(0);
      expect(await cacheManager.get('tweet1')).toBe(null);
    });
  });

  describe('Batch operations', () => {
    it('should get batch of tweets', async () => {
      await cacheManager.set('tweet1', true);
      await cacheManager.set('tweet2', false);
      await cacheManager.set('tweet3', true);

      const results = await cacheManager.getBatch(['tweet1', 'tweet2', 'tweet4']);

      expect(results).toEqual({
        tweet1: true,
        tweet2: false,
        // tweet4 is not in cache, so it's not in results
      });
    });

    it('should return empty object for empty batch', async () => {
      const results = await cacheManager.getBatch([]);
      expect(results).toEqual({});
    });

    it('should return empty object when none found', async () => {
      const results = await cacheManager.getBatch(['nonexistent1', 'nonexistent2']);
      expect(results).toEqual({});
    });
  });

  describe('LRU (Least Recently Used) eviction', () => {
    it('should evict LRU entry when cache is full', async () => {
      // MAX_CACHE_SIZE is 500
      // Add 500 entries
      for (let i = 0; i < 500; i++) {
        await cacheManager.set(`tweet${i}`, i % 2 === 0);
      }

      expect(await cacheManager.getSize()).toBe(500);

      // Adding the 501st entry should evict the first entry (tweet0)
      await cacheManager.set('tweet500', true);

      expect(await cacheManager.getSize()).toBe(500);
      expect(await cacheManager.has('tweet0')).toBe(false); // LRU evicted
      expect(await cacheManager.has('tweet500')).toBe(true); // Newly added
    });

    it('should update LRU order on get', async () => {
      // Add 3 entries (order: tweet0, tweet1, tweet2)
      await cacheManager.set('tweet0', true);
      await cacheManager.set('tweet1', false);
      await cacheManager.set('tweet2', true);

      // Access tweet0 to update LRU order (tweet1, tweet2, tweet0)
      await cacheManager.get('tweet0');

      // Add 497 more to fill up to 500
      for (let i = 3; i < 500; i++) {
        await cacheManager.set(`tweet${i}`, true);
      }

      // Verify size is 500
      expect(await cacheManager.getSize()).toBe(500);

      // Adding the 501st entry should evict tweet1 (tweet0 was recently accessed so it stays)
      await cacheManager.set('tweet500', true);

      expect(await cacheManager.has('tweet0')).toBe(true); // Stays because recently accessed
      expect(await cacheManager.has('tweet1')).toBe(false); // LRU evicted
      expect(await cacheManager.has('tweet2')).toBe(true); // Stays
      expect(await cacheManager.getSize()).toBe(500); // Size remains 500
    });

    it('should update LRU order on set (overwrite)', async () => {
      // Add 3 entries
      await cacheManager.set('tweet0', true);
      await cacheManager.set('tweet1', false);
      await cacheManager.set('tweet2', true);

      // Overwrite tweet0 to update LRU order
      await cacheManager.set('tweet0', false);

      // Add 498 more to fill up
      for (let i = 3; i < 501; i++) {
        await cacheManager.set(`tweet${i}`, true);
      }

      // Adding the 501st entry should evict tweet1
      await cacheManager.set('tweet501', true);

      expect(await cacheManager.has('tweet0')).toBe(true); // Stays because updated by overwrite
      expect(await cacheManager.has('tweet1')).toBe(false); // LRU evicted
    });
  });

  describe('Concurrent access (race conditions)', () => {
    it('should handle concurrent set operations without corruption', async () => {
      // Multiple concurrent set operations (lock mechanism test)
      const promises = [];
      for (let i = 0; i < 10; i++) {
        promises.push(cacheManager.set(`tweet${i}`, i % 2 === 0));
      }

      await Promise.all(promises);

      // Verify all entries are correctly stored
      expect(await cacheManager.getSize()).toBe(10);
      for (let i = 0; i < 10; i++) {
        const result = await cacheManager.get(`tweet${i}`);
        expect(result).toBe(i % 2 === 0);
      }
    });

    it('should handle concurrent get and set operations', async () => {
      // Set up initial data
      await cacheManager.set('tweet1', true);

      // Concurrent get/set operations
      const operations = [
        cacheManager.get('tweet1'),
        cacheManager.set('tweet2', false),
        cacheManager.get('tweet1'),
        cacheManager.set('tweet3', true),
        cacheManager.get('tweet2'),
      ];

      const results = await Promise.all(operations);

      // Verify final state
      expect(await cacheManager.getSize()).toBe(3);
      expect(await cacheManager.get('tweet1')).toBe(true);
      expect(await cacheManager.get('tweet2')).toBe(false);
      expect(await cacheManager.get('tweet3')).toBe(true);
    });
  });

  describe('Error handling', () => {
    it('should return null on get error', async () => {
      // chrome.storage.session.get throws an error
      vi.mocked(chrome.storage.session.get).mockRejectedValueOnce(
        new Error('Storage error')
      );

      const result = await cacheManager.get('tweet1');
      expect(result).toBe(null);
    });

    it('should handle set error gracefully', async () => {
      // chrome.storage.session.set throws an error
      vi.mocked(chrome.storage.session.set).mockRejectedValueOnce(
        new Error('Storage error')
      );

      // Verify it completes without throwing an error
      await expect(cacheManager.set('tweet1', true)).resolves.toBeUndefined();
    });

    it('should return false on has error', async () => {
      vi.mocked(chrome.storage.session.get).mockRejectedValueOnce(
        new Error('Storage error')
      );

      const result = await cacheManager.has('tweet1');
      expect(result).toBe(false);
    });

    it('should return empty object on getBatch error', async () => {
      vi.mocked(chrome.storage.session.get).mockRejectedValueOnce(
        new Error('Storage error')
      );

      const results = await cacheManager.getBatch(['tweet1', 'tweet2']);
      expect(results).toEqual({});
    });

    it('should return 0 on getSize error', async () => {
      vi.mocked(chrome.storage.session.get).mockRejectedValueOnce(
        new Error('Storage error')
      );

      const size = await cacheManager.getSize();
      expect(size).toBe(0);
    });

    it('should handle clear error gracefully', async () => {
      vi.mocked(chrome.storage.session.remove).mockRejectedValueOnce(
        new Error('Storage error')
      );

      // Verify it completes without throwing an error
      await expect(cacheManager.clear()).resolves.toBeUndefined();
    });
  });

  describe('Edge cases', () => {
    it('should handle eviction with empty order array', async () => {
      // When LRU eviction occurs with an empty order array (fallback)
      // Directly manipulate storage to set order to empty
      mockStorage['tweet-filter-cache'] = {
        tweet1: true,
        tweet2: false,
      };
      mockStorage['tweet-filter-cache-order'] = []; // Empty order array

      // Add entries to fill up to 500
      for (let i = 3; i < 501; i++) {
        await cacheManager.set(`tweet${i}`, true);
      }

      // Adding the 501st entry triggers fallback eviction
      await cacheManager.set('tweet501', true);

      // Verify size is 500 (eviction occurred)
      expect(await cacheManager.getSize()).toBe(500);
    });

    it('should handle setting same tweet ID multiple times', async () => {
      await cacheManager.set('tweet1', true);
      await cacheManager.set('tweet1', false);
      await cacheManager.set('tweet1', true);

      expect(await cacheManager.get('tweet1')).toBe(true);
      expect(await cacheManager.getSize()).toBe(1);
    });

    it('should handle special characters in tweet IDs', async () => {
      const specialIds = [
        'tweet-with-dash',
        'tweet_with_underscore',
        'tweet.with.dot',
        'tweet:with:colon',
      ];

      for (const id of specialIds) {
        await cacheManager.set(id, true);
      }

      for (const id of specialIds) {
        expect(await cacheManager.get(id)).toBe(true);
      }
    });
  });
});
