import { MESSAGE_TYPES } from '../shared/messaging/constants';
import type { Message } from '../shared/messaging/types';
import { messageHandler } from './messageHandler';
import { offscreenManager } from './offscreenManager';
import { cacheManager } from './cacheManager';
import { storage } from '../shared/storage';
import { logger } from '../shared/logger';

// Initialize logger
logger.initialize();

logger.log('[ServiceWorker] Tweet Filter Service Worker initializing...');

// Handle messages from content scripts
chrome.runtime.onMessage.addListener((message: Message, _sender, sendResponse) => {
  logger.log('[ServiceWorker] Received message:', message.type);

  // Handle message asynchronously
  messageHandler.handleMessage(message).then(sendResponse).catch((error) => {
    logger.error('[ServiceWorker] Message handling error:', error);
    sendResponse({
      type: MESSAGE_TYPES.ERROR,
      requestId: message.requestId,
      timestamp: Date.now(),
      error: error instanceof Error ? error.message : String(error),
    });
  });

  // Return true to indicate we'll send response asynchronously
  return true;
});

// Handle config changes from options page
storage.onFilterConfigChange(async (newConfig) => {
  logger.log('[ServiceWorker] Config changed:', newConfig);

  if (!newConfig.enabled || !newConfig.prompt.trim()) {
    // Disable filtering - destroy offscreen and clear cache
    logger.log('[ServiceWorker] Filtering disabled, clearing resources');
    await offscreenManager.destroy();
    await cacheManager.clear();
  } else {
    // Config changed - clear cache and reinitialize offscreen
    logger.log('[ServiceWorker] Filtering config updated, reinitializing');
    await cacheManager.clear();

    try {
      // Send REINIT_REQUEST to offscreen document
      await offscreenManager.sendToOffscreen<any>({
        type: MESSAGE_TYPES.REINIT_REQUEST as any,
        config: {
          prompt: newConfig.prompt,
          outputLanguage: newConfig.outputLanguage,
        },
      } as any);
    } catch (error) {
      logger.error('[ServiceWorker] Failed to reinitialize offscreen:', error);
    }
  }

  // Note: Content scripts will detect config changes via chrome.storage.onChanged
});

// Handle service worker lifecycle
self.addEventListener('activate', () => {
  logger.log('[ServiceWorker] Activated');
});

self.addEventListener('install', () => {
  logger.log('[ServiceWorker] Installed');
  // Skip waiting to activate immediately
  (self as any).skipWaiting();
});

logger.log('[ServiceWorker] Tweet Filter Service Worker initialized');
