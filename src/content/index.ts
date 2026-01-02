import { tweetObserver } from './tweetObserver';
import { tweetFilter } from './tweetFilter';
import { storage } from '../shared/storage';
import { geminiNano } from '../shared/geminiNano';
import { logger } from '../shared/logger';
import type { TweetData } from '../types/tweet';
import './styles.css';

async function main(): Promise<void> {
  // Initialize logger first
  await logger.initialize();

  const config = await storage.getFilterConfig();

  if (!config.enabled) {
    return;
  }

  // If prompt is empty, don't initialize filter
  if (!config.prompt.trim()) {
    return;
  }

  const availability = await geminiNano.checkAvailability(config.outputLanguage);

  if (availability === 'unavailable') {
    return;
  }

  if (availability === 'downloading' || availability === 'downloadable' || availability === 'after-download') {
    setTimeout(main, 120000);
    return;
  }

  const initialized = await tweetFilter.initialize(config.prompt, config.outputLanguage);
  if (!initialized) {
    setTimeout(main, 30000);
    return;
  }

  const processTweet = (tweet: TweetData) => tweetFilter.processTweet(tweet);
  tweetObserver.start(processTweet);

  // Handle SPA navigation (page transitions within Twitter)
  let currentUrl = location.href;
  const checkUrlChange = () => {
    if (location.href !== currentUrl) {
      logger.log('[Tweet Filter] 🔄 Page navigation detected:', currentUrl, '→', location.href);
      currentUrl = location.href;

      // Restart observer to ensure it's monitoring the current page
      tweetObserver.stop();
      setTimeout(() => {
        tweetObserver.start(processTweet);
      }, 500); // Wait for page content to stabilize
    }
  };

  // Monitor URL changes (Twitter is a SPA)
  const urlCheckInterval = setInterval(checkUrlChange, 1000);

  // Also listen to browser history events
  window.addEventListener('popstate', checkUrlChange);

  // Debounced config change handler
  let configChangeTimeout: number | null = null;
  storage.onFilterConfigChange(async (newConfig) => {
    if (configChangeTimeout) {
      clearTimeout(configChangeTimeout);
    }

    configChangeTimeout = window.setTimeout(async () => {
      if (!newConfig.enabled || !newConfig.prompt.trim()) {
        tweetObserver.stop();
        await tweetFilter.destroy();
        if (urlCheckInterval) {
          clearInterval(urlCheckInterval);
        }
      } else {
        tweetObserver.stop();
        await tweetFilter.destroy();
        await tweetFilter.initialize(newConfig.prompt, newConfig.outputLanguage);
        tweetObserver.start(processTweet);
      }
    }, 300);
  });
}

// Wait for page to be ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', main);
} else {
  main();
}
