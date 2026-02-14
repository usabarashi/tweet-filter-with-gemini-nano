import type { Message, InitRequest, InitResponse } from '../shared/messaging/types';
import { OFFSCREEN_DOCUMENT, MESSAGE_TYPES } from '../shared/messaging/constants';
import { logger } from '../shared/logger';
import { storage } from '../shared/storage';

export class OffscreenManager {
  private isCreating = false;
  private creationPromise: Promise<void> | null = null;

  async ensureOffscreenReady(): Promise<void> {
    // Check if offscreen document already exists
    const existingContexts = await chrome.runtime.getContexts({
      contextTypes: ['OFFSCREEN_DOCUMENT' as chrome.runtime.ContextType],
    });

    if (existingContexts.length > 0) {
      logger.log('[OffscreenManager] Offscreen document already exists');
      return;
    }

    // If already creating, wait for it
    if (this.creationPromise) {
      return this.creationPromise;
    }

    // Create offscreen document
    this.creationPromise = this.createOffscreen();
    try {
      await this.creationPromise;
    } finally {
      this.creationPromise = null;
    }
  }

  private async createOffscreen(): Promise<void> {
    if (this.isCreating) {
      return;
    }

    this.isCreating = true;

    try {
      await chrome.offscreen.createDocument({
        url: OFFSCREEN_DOCUMENT.PATH,
        reasons: [OFFSCREEN_DOCUMENT.REASON],
        justification: OFFSCREEN_DOCUMENT.JUSTIFICATION,
      });

      logger.log('[OffscreenManager] Offscreen document created');

      // Auto-initialize session with current config
      await this.initializeOffscreenSession();
    } catch (error) {
      // Check if error is because document already exists
      if (error instanceof Error && error.message.includes('Only a single offscreen')) {
        logger.log('[OffscreenManager] Offscreen document already exists (race condition handled)');
        return;
      }
      logger.error('[OffscreenManager] Failed to create offscreen document:', error);
      throw error;
    } finally {
      this.isCreating = false;
    }
  }

  private async initializeOffscreenSession(): Promise<void> {
    const maxRetries = 3;
    const retryDelay = 500; // ms

    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        // Read current filter config from storage
        const config = await storage.getFilterConfig();

        if (!config.enabled || !config.prompt.trim()) {
          logger.log('[OffscreenManager] Filtering disabled, skipping session initialization');
          return;
        }

        logger.log(`[OffscreenManager] Initializing offscreen session (attempt ${attempt}/${maxRetries})`);

        // Wait a bit for offscreen document to fully load (especially on first attempt)
        if (attempt === 1) {
          await new Promise(resolve => setTimeout(resolve, 300));
        }

        // Send INIT_REQUEST to offscreen document
        const initMessage: Omit<InitRequest, 'requestId' | 'timestamp'> = {
          type: MESSAGE_TYPES.INIT_REQUEST,
          config: {
            prompt: config.prompt,
            outputLanguage: config.outputLanguage,
          },
        } as any;

        const fullMessage: Message = {
          ...initMessage,
          requestId: crypto.randomUUID(),
          timestamp: Date.now(),
        } as Message;

        const response = await chrome.runtime.sendMessage(fullMessage) as InitResponse;

        if (response && response.success) {
          logger.log('[OffscreenManager] Offscreen session initialized successfully');
          return; // Success - exit retry loop
        } else {
          logger.warn('[OffscreenManager] Offscreen session initialization failed, will retry');
        }
      } catch (error) {
        logger.error(`[OffscreenManager] Init attempt ${attempt} failed:`, error);

        if (attempt < maxRetries) {
          // Wait before retrying
          await new Promise(resolve => setTimeout(resolve, retryDelay * attempt));
        }
      }
    }

    logger.error('[OffscreenManager] Failed to initialize offscreen session after all retries');
  }

  async sendToOffscreen<T extends Message>(message: Omit<Message, 'requestId' | 'timestamp'>): Promise<T> {
    await this.ensureOffscreenReady();

    const fullMessage: Message = {
      ...message,
      requestId: crypto.randomUUID(),
      timestamp: Date.now(),
    } as Message;

    try {
      const response = await chrome.runtime.sendMessage(fullMessage);
      return response as T;
    } catch (error) {
      logger.error('[OffscreenManager] Failed to send message to offscreen:', error);
      throw error;
    }
  }

  async destroy(): Promise<void> {
    try {
      await chrome.offscreen.closeDocument();
      logger.log('[OffscreenManager] Offscreen document closed');
    } catch (error) {
      // Document might not exist, which is fine
      logger.log('[OffscreenManager] Could not close offscreen document (may not exist):', error);
    }
  }
}

export const offscreenManager = new OffscreenManager();
