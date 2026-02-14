import type {
  Message,
  DistributiveOmit,
  ErrorMessage,
  InitResponse,
  EvaluateResponse,
  SessionStatusResponse,
  QuotedTweet,
} from './types';
import type { MediaData } from '../../types/tweet';
import type { OutputLanguage } from '../../types/storage';
import { TIMEOUTS, MESSAGE_TYPES } from './constants';
import { logger } from '../logger';

export class ServiceWorkerClient {
  private async sendMessage<T extends Message>(
    message: DistributiveOmit<Message, 'requestId' | 'timestamp'>,
    timeout: number
  ): Promise<T> {
    if (!chrome.runtime?.id) {
      return Promise.reject(new Error('Extension context invalidated'));
    }

    const requestId = crypto.randomUUID();
    const fullMessage: Message = {
      ...message,
      requestId,
      timestamp: Date.now(),
    } as Message;

    return new Promise((resolve, reject) => {
      const timeoutId = window.setTimeout(() => {
        reject(new Error(`Request timeout: ${message.type}`));
      }, timeout);

      chrome.runtime.sendMessage(fullMessage, (response: T) => {
        clearTimeout(timeoutId);

        if (chrome.runtime.lastError) {
          reject(new Error(chrome.runtime.lastError.message));
          return;
        }

        if (!response) {
          reject(new Error('No response from service worker'));
          return;
        }

        if (response.type === MESSAGE_TYPES.ERROR) {
          reject(new Error((response as ErrorMessage).error));
          return;
        }

        resolve(response);
      });
    });
  }

  async initialize(prompt: string, outputLanguage: OutputLanguage): Promise<InitResponse> {
    logger.log('[ServiceWorkerClient] Sending INIT_REQUEST');
    return this.sendMessage<InitResponse>({
      type: MESSAGE_TYPES.INIT_REQUEST,
      config: { prompt, outputLanguage },
    } as DistributiveOmit<Message, 'requestId' | 'timestamp'>, TIMEOUTS.INIT_REQUEST);
  }

  async evaluateTweet(request: {
    tweetId: string;
    textContent: string;
    media?: MediaData[];
    quotedTweet?: QuotedTweet;
  }): Promise<EvaluateResponse> {
    return this.sendMessage<EvaluateResponse>({
      type: MESSAGE_TYPES.EVALUATE_REQUEST,
      ...request,
    }, TIMEOUTS.EVALUATE_REQUEST);
  }

  async getSessionStatus(): Promise<SessionStatusResponse> {
    return this.sendMessage<SessionStatusResponse>({
      type: MESSAGE_TYPES.SESSION_STATUS_REQUEST,
    }, TIMEOUTS.SESSION_STATUS_REQUEST);
  }
}

export const serviceWorkerClient = new ServiceWorkerClient();
