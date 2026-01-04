import type { GeminiAvailability } from '../types/gemini';
import type { MediaData } from '../types/tweet';
import type { OutputLanguage } from '../types/storage';
import { logger } from './logger';

class GeminiNanoService {
  private baseSession: LanguageModelSession | null = null;
  private filterCriteria: string = '';
  private currentOutputLanguage: OutputLanguage = 'en';
  private supportsMultimodal: boolean = false;
  private createSessionResult: 'multimodal' | 'text-only' | null = null;

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

  async initialize(systemPrompt: string, requireUserGesture = false, onProgress?: (progress: number) => void, outputLanguage: OutputLanguage = 'en'): Promise<boolean> {
    try {
      // Check if we need to reinitialize base session
      const needsReinit = !this.baseSession ||
                          this.filterCriteria !== systemPrompt ||
                          this.currentOutputLanguage !== outputLanguage;

      if (!needsReinit) {
        // Base session already exists with same config, no need to reinitialize
        return true;
      }

      this.filterCriteria = systemPrompt;
      this.currentOutputLanguage = outputLanguage;

      // Destroy old base session if exists
      await this._destroyBaseSession();

      // Helper function to create session with given options
      const createSession = async (expectedInputs: Array<{ type: string }>) => {
        const options: LanguageModelCreateOptions = {
          temperature: 0.1,
          topK: 1,
          expectedInputs,
          expectedOutputs: [
            { type: 'text', languages: [outputLanguage] }
          ],
        };

        if (onProgress) {
          options.monitor = (m: LanguageModelDownloadMonitor) => {
            m.addEventListener('downloadprogress', (e: { loaded: number }) => {
              onProgress(e.loaded * 100);
            });
          };
        }

        return await LanguageModel.create(options);
      };

      // 1. Check multimodal availability first
      const multimodalAvailability = await this.checkMultimodalAvailability(outputLanguage);

      // 2. If multimodal is available or downloadable, try to create multimodal session
      if (multimodalAvailability === 'available' ||
          multimodalAvailability === 'downloadable' ||
          multimodalAvailability === 'after-download') {

        // Check user gesture requirement for downloadable states
        if ((multimodalAvailability === 'downloadable' || multimodalAvailability === 'after-download') &&
            !requireUserGesture) {
          // Fall through to text-only check
        } else {
          this.baseSession = await createSession([{ type: 'text' }, { type: 'image' }]);
          this.supportsMultimodal = true;
          this.createSessionResult = 'multimodal';
          return true;
        }
      }

      // 3. Check text-only availability
      const textAvailability = await this.checkAvailability(outputLanguage);

      if (textAvailability === 'unavailable' || textAvailability === 'downloading') {
        return false;
      }

      // Check user gesture requirement
      if (textAvailability === 'downloadable' || textAvailability === 'after-download') {
        if (!requireUserGesture) {
          return false;
        }
      }

      // 4. Create text-only base session
      this.baseSession = await createSession([{ type: 'text' }]);
      this.supportsMultimodal = false;
      this.createSessionResult = 'text-only';
      return true;

    } catch (error) {
      logger.error('[Tweet Filter] Failed to initialize:', error);
      this.createSessionResult = null;
      return false;
    }
  }

  private ensureBaseSession(): LanguageModelSession {
    if (!this.baseSession) {
      throw new Error('Base session not initialized');
    }
    return this.baseSession;
  }

  private async _destroyBaseSession(): Promise<void> {
    if (this.baseSession) {
      try {
        await this.baseSession.destroy();
      } catch (error) {
        logger.error('[Tweet Filter] Failed to destroy base session:', error);
      } finally {
        this.baseSession = null;
      }
    }
  }

  async createClonedSession(): Promise<LanguageModelSession> {
    const baseSession = this.ensureBaseSession();
    return await baseSession.clone();
  }

  private async fetchImageAsBlob(url: string): Promise<Blob | null> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);

    try {
      const response = await fetch(url, { signal: controller.signal });
      clearTimeout(timeout);
      if (!response.ok) return null;
      return await response.blob();
    } catch (error) {
      clearTimeout(timeout);
      logger.error('[Tweet Filter] Failed to fetch image:', error);
      return null;
    }
  }

  async describeImages(media: MediaData[], session: LanguageModelSession): Promise<string[]> {
    if (!this.supportsMultimodal) {
      logger.warn('[Tweet Filter] Multimodal not supported, skipping image description');
      return [];
    }

    const descriptions: string[] = [];

    for (const item of media) {
      try {
        const blob = await this.fetchImageAsBlob(item.url);
        if (!blob) {
          logger.warn('[Tweet Filter] Failed to fetch image, skipping');
          continue;
        }

        const response = await session.prompt([
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Describe this image in 1-2 sentences. Focus on the main subject and content.' },
              { type: 'image', data: blob }
            ]
          }
        ]);
        descriptions.push(response.trim());
      } catch (error) {
        logger.error('[Tweet Filter] Failed to describe image:', error);
      }
    }

    return descriptions;
  }

  async evaluateText(tweetText: string, session: LanguageModelSession): Promise<boolean> {
    try {
      const promptText = `Evaluate if this tweet matches the following criteria:
"${this.filterCriteria}"

Tweet text: "${tweetText}"

If the tweet MATCHES the criteria, respond: {"show": true}
If the tweet does NOT match the criteria, respond: {"show": false}

Response (JSON only):`;

      const response = await session.prompt(promptText);

      const jsonMatch = response.match(/\{"show":\s*(true|false)\}/);
      if (jsonMatch) {
        return jsonMatch[1] === 'true';
      }

      try {
        const result = JSON.parse(response.trim());
        return result.show === true;
      } catch {
        return true;
      }
    } catch (error) {
      logger.error('[Tweet Filter] Failed to evaluate text:', error);
      return true;
    }
  }

  async destroy(): Promise<void> {
    await this._destroyBaseSession();
  }

  isMultimodalEnabled(): boolean {
    return this.supportsMultimodal;
  }

  getCreateSessionResult(): 'multimodal' | 'text-only' | null {
    return this.createSessionResult;
  }
}

export const geminiNano = new GeminiNanoService();
