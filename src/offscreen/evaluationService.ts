import type { MediaData } from '../types/tweet';
import { TIMEOUTS } from '../shared/messaging/constants';
import { sessionManager } from './sessionManager';
import { logger } from '../shared/logger';

export interface EvaluationRequest {
  tweetId: string;
  textContent: string;
  media?: MediaData[];
  quotedTweet?: {
    textContent: string;
    author?: string;
    media?: MediaData[];
  };
}

export interface EvaluationResult {
  shouldShow: boolean;
  evaluationTime: number;
}

export class EvaluationService {
  async evaluateTweet(request: EvaluationRequest): Promise<EvaluationResult> {
    const startTime = Date.now();

    let clonedSession: LanguageModelSession | null = null;
    try {
      // Wait for session initialization to complete (if in progress)
      const initialized = await sessionManager.waitForInitialization();
      if (!initialized) {
        logger.error('[EvaluationService] Session not initialized, cannot evaluate tweet');
        // Show tweet by default when session is not ready
        return {
          shouldShow: true,
          evaluationTime: Date.now() - startTime,
        };
      }

      clonedSession = await sessionManager.createClonedSession();

      // Short-circuit evaluation: stop as soon as we find a match
      let shouldShow = false;
      let evaluated = false;

      // Stage 1: Evaluate main text
      if (request.textContent.trim()) {
        shouldShow = await this.evaluateText(request.textContent, clonedSession);
        evaluated = true;
      }

      // Stage 2: If main text didn't match, evaluate quoted tweet text
      if (!shouldShow && request.quotedTweet) {
        const quotedText = request.quotedTweet.textContent.trim();
        if (quotedText) {
          const rawAuthor = request.quotedTweet.author?.trim();
          const quotedAuthor = rawAuthor
            ? (rawAuthor.startsWith('@') ? rawAuthor : `@${rawAuthor}`)
            : 'someone';
          const quotedContent = `[Quoting ${quotedAuthor}: ${quotedText}]`;
          shouldShow = await this.evaluateText(quotedContent, clonedSession);
          evaluated = true;
        }
      }

      // Stage 3: If text didn't match, evaluate quoted tweet images
      if (!shouldShow && request.quotedTweet?.media && request.quotedTweet.media.length > 0) {
        const quotedDescriptions = await this.describeImages(request.quotedTweet.media, clonedSession);
        if (quotedDescriptions.length > 0) {
          const quotedImageText = '[Images in quoted tweet: ' + quotedDescriptions.join('; ') + ']';
          shouldShow = await this.evaluateText(quotedImageText, clonedSession);
          evaluated = true;
        }
      }

      // Stage 4: If still didn't match, evaluate main tweet images
      if (!shouldShow && request.media && request.media.length > 0) {
        const descriptions = await this.describeImages(request.media, clonedSession);
        if (descriptions.length > 0) {
          const imageText = '[Images in this tweet: ' + descriptions.join('; ') + ']';
          shouldShow = await this.evaluateText(imageText, clonedSession);
          evaluated = true;
        }
      }

      // Show tweet by default when no content could be evaluated
      if (!evaluated) {
        logger.warn('[EvaluationService] No evaluable content found, showing tweet by default');
        shouldShow = true;
      }

      return {
        shouldShow,
        evaluationTime: Date.now() - startTime,
      };

    } catch (error) {
      logger.error('[EvaluationService] Failed to evaluate tweet:', error);
      // On error, show the tweet by default
      return {
        shouldShow: true,
        evaluationTime: Date.now() - startTime,
      };
    } finally {
      if (clonedSession) {
        try {
          await clonedSession.destroy();
        } catch (error) {
          logger.error('[EvaluationService] Failed to destroy cloned session:', error);
        }
      }
    }
  }

  private async fetchImageAsBlob(url: string): Promise<Blob | null> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), TIMEOUTS.IMAGE_FETCH);

    try {
      const response = await fetch(url, { signal: controller.signal });
      clearTimeout(timeout);
      if (!response.ok) return null;
      return await response.blob();
    } catch (error) {
      clearTimeout(timeout);
      logger.error('[EvaluationService] Failed to fetch image:', error);
      return null;
    }
  }

  private async describeImages(media: MediaData[], session: LanguageModelSession): Promise<string[]> {
    if (!sessionManager.isMultimodalEnabled()) {
      logger.warn('[EvaluationService] Multimodal not supported, skipping image description');
      return [];
    }

    // Parallelize image fetching and description
    const descriptionPromises = media.map(async (item) => {
      try {
        const blob = await this.fetchImageAsBlob(item.url);
        if (!blob) {
          logger.warn('[EvaluationService] Failed to fetch image, skipping');
          return null;
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
        return response.trim();
      } catch (error) {
        logger.error('[EvaluationService] Failed to describe image:', error);
        return null;
      }
    });

    const results = await Promise.all(descriptionPromises);
    return results.filter((desc): desc is string => desc !== null);
  }

  private async evaluateText(tweetText: string, session: LanguageModelSession): Promise<boolean> {
    try {
      const filterCriteria = sessionManager.getFilterCriteria();
      const promptText = `Evaluate if this tweet matches the following criteria:
"${filterCriteria}"

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
      logger.error('[EvaluationService] Failed to evaluate text:', error);
      return true;
    }
  }
}

export const evaluationService = new EvaluationService();
