import type { GeminiAvailability } from '../types/gemini';
import type { OutputLanguage } from '../types/storage';
import { logger } from '../shared/logger';

export interface SessionConfig {
  prompt: string;
  outputLanguage: OutputLanguage;
}

export class GeminiSessionManager {
  private baseSession: LanguageModelSession | null = null;
  private currentConfig: SessionConfig | null = null;
  private supportsMultimodal: boolean = false;
  private sessionType: 'multimodal' | 'text-only' | null = null;
  private initializationPromise: Promise<boolean> | null = null;

  private async checkAvailabilityWithInputs(
    inputTypes: Array<{ type: string }>,
    outputLanguage: OutputLanguage
  ): Promise<GeminiAvailability> {
    if (typeof LanguageModel === 'undefined') {
      return 'unavailable';
    }
    return await LanguageModel.availability({
      expectedInputs: inputTypes,
      expectedOutputs: [{ type: 'text', languages: [outputLanguage] }],
    });
  }

  async checkAvailability(outputLanguage: OutputLanguage = 'en'): Promise<GeminiAvailability> {
    return this.checkAvailabilityWithInputs([{ type: 'text' }], outputLanguage);
  }

  async checkMultimodalAvailability(outputLanguage: OutputLanguage = 'en'): Promise<GeminiAvailability> {
    return this.checkAvailabilityWithInputs([{ type: 'text' }, { type: 'image' }], outputLanguage);
  }

  async initialize(config: SessionConfig): Promise<boolean> {
    // If already initializing with same config, return existing promise
    if (this.initializationPromise && this.isSameConfig(config)) {
      return this.initializationPromise;
    }

    // If config changed, destroy old session
    if (this.baseSession && !this.isSameConfig(config)) {
      await this.destroy();
    }

    // If session exists with same config, no need to reinitialize
    if (this.baseSession && this.isSameConfig(config)) {
      return true;
    }

    this.initializationPromise = this.doInitialize(config);
    try {
      const result = await this.initializationPromise;
      return result;
    } finally {
      this.initializationPromise = null;
    }
  }

  private async doInitialize(config: SessionConfig): Promise<boolean> {
    try {
      this.currentConfig = config;

      const createSession = async (expectedInputs: Array<{ type: string }>) => {
        const options: LanguageModelCreateOptions = {
          temperature: 0.1,
          topK: 1,
          expectedInputs,
          expectedOutputs: [
            { type: 'text', languages: [config.outputLanguage] }
          ],
        };

        return await LanguageModel.create(options);
      };

      // 1. Check multimodal availability first
      const multimodalAvailability = await this.checkMultimodalAvailability(config.outputLanguage);

      // 2. Try to create multimodal session
      if (multimodalAvailability === 'available' ||
          multimodalAvailability === 'after-download') {
        try {
          this.baseSession = await createSession([{ type: 'text' }, { type: 'image' }]);
          this.supportsMultimodal = true;
          this.sessionType = 'multimodal';
          logger.log('[SessionManager] Initialized with multimodal support');
          return true;
        } catch (error) {
          logger.warn('[SessionManager] Multimodal init failed, falling back to text-only:', error);
        }
      }

      // 3. Check text-only availability
      const textAvailability = await this.checkAvailability(config.outputLanguage);

      if (textAvailability === 'unavailable' || textAvailability === 'downloading') {
        logger.error('[SessionManager] Text-only unavailable');
        return false;
      }

      // 4. Create text-only base session
      this.baseSession = await createSession([{ type: 'text' }]);
      this.supportsMultimodal = false;
      this.sessionType = 'text-only';
      logger.log('[SessionManager] Initialized with text-only support');
      return true;

    } catch (error) {
      logger.error('[SessionManager] Failed to initialize:', error);
      this.sessionType = null;
      this.currentConfig = null;
      return false;
    }
  }

  private isSameConfig(config: SessionConfig): boolean {
    return this.currentConfig !== null &&
           this.currentConfig.prompt === config.prompt &&
           this.currentConfig.outputLanguage === config.outputLanguage;
  }

  async waitForInitialization(timeoutMs: number = 30000): Promise<boolean> {
    // If already initialized, return immediately
    if (this.baseSession !== null) {
      return true;
    }

    // If initialization is in progress, wait for it
    if (this.initializationPromise) {
      try {
        const result = await Promise.race([
          this.initializationPromise,
          new Promise<boolean>((_, reject) =>
            setTimeout(() => reject(new Error('Initialization timeout')), timeoutMs)
          ),
        ]);
        return result;
      } catch (error) {
        logger.error('[SessionManager] Wait for initialization failed:', error);
        return false;
      }
    }

    // Not initialized and not initializing
    return false;
  }

  async createClonedSession(): Promise<LanguageModelSession> {
    if (!this.baseSession) {
      throw new Error('Base session not initialized');
    }
    return await this.baseSession.clone();
  }

  async destroy(): Promise<void> {
    if (this.baseSession) {
      try {
        await this.baseSession.destroy();
        logger.log('[SessionManager] Base session destroyed');
      } catch (error) {
        logger.error('[SessionManager] Failed to destroy base session:', error);
      } finally {
        this.baseSession = null;
        this.currentConfig = null;
        this.supportsMultimodal = false;
        this.sessionType = null;
      }
    }
  }

  isInitialized(): boolean {
    return this.baseSession !== null;
  }

  isMultimodalEnabled(): boolean {
    return this.supportsMultimodal;
  }

  getSessionType(): 'multimodal' | 'text-only' | null {
    return this.sessionType;
  }

  getCurrentConfig(): SessionConfig | null {
    return this.currentConfig;
  }

  getFilterCriteria(): string {
    return this.currentConfig?.prompt ?? '';
  }
}

export const sessionManager = new GeminiSessionManager();
