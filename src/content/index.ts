import { tweetObserver } from './tweetObserver';
import { tweetFilter } from './tweetFilter';
import { storage } from '../shared/storage';
import { serviceWorkerClient } from '../shared/messaging/client';
import { logger } from '../shared/logger';
import type { TweetData } from '../types/tweet';
import './styles.css';

async function main(): Promise<void> {
  // Guard: abort if the extension context has been invalidated
  // (e.g. after extension reload/update while the page is still open)
  if (!chrome.runtime?.id) return;

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

  try {
    // Initialize via service worker (no connection needed with sendMessage)
    const initResponse = await serviceWorkerClient.initialize(
      config.prompt,
      config.outputLanguage
    );

    if (!initResponse.success) {
      logger.error('[Tweet Filter] Service worker initialization failed');
      setTimeout(main, 30000);
      return;
    }

    logger.log('[Tweet Filter] Service worker initialized:', initResponse.sessionStatus);

    // Initialize tweet filter (no longer manages Gemini session)
    await tweetFilter.initialize();

    const processTweet = (tweet: TweetData) => tweetFilter.processTweet(tweet);
    tweetObserver.start(processTweet);

    // Handle SPA navigation (page transitions within Twitter)
    let currentUrl = location.href;
    const checkUrlChange = () => {
      if (location.href !== currentUrl) {
        logger.log('[Tweet Filter] Page navigation detected:', currentUrl, '→', location.href);
        currentUrl = location.href;

        // Restart observer to ensure it's monitoring the current page
        tweetObserver.stop();
        setTimeout(() => {
          tweetObserver.start(processTweet);
        }, 500);
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
          tweetFilter.destroy();
          if (urlCheckInterval) {
            clearInterval(urlCheckInterval);
          }
        } else {
          tweetObserver.stop();
          tweetFilter.destroy();

          // Service worker handles session reinitialization
          // We just need to restart observation
          await tweetFilter.initialize();
          tweetObserver.start(processTweet);
        }
      }, 300);
    });

  } catch (error) {
    logger.error('[Tweet Filter] Initialization failed:', error);
    setTimeout(main, 30000);
  }
}

// Wait for page to be ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', main);
} else {
  main();
}
