import { logger } from '../shared/logger';

interface QueueItem<T, R> {
  request: T;
  resolve: (result: R) => void;
  reject: (error: Error) => void;
}

export class EvaluationQueue<T, R> {
  private queue: QueueItem<T, R>[] = [];
  private isProcessing = false;
  private processFn: (request: T) => Promise<R>;

  constructor(processFn: (request: T) => Promise<R>) {
    this.processFn = processFn;
  }

  async enqueue(request: T): Promise<R> {
    return new Promise((resolve, reject) => {
      this.queue.push({ request, resolve, reject });
      this.processQueue();
    });
  }

  private async processQueue(): Promise<void> {
    if (this.isProcessing || this.queue.length === 0) {
      return;
    }

    this.isProcessing = true;

    while (this.queue.length > 0) {
      const item = this.queue.shift();
      if (!item) continue;

      try {
        const result = await this.processFn(item.request);
        item.resolve(result);
      } catch (error) {
        logger.error('[EvaluationQueue] Processing failed:', error);
        item.reject(error instanceof Error ? error : new Error(String(error)));
      }
    }

    this.isProcessing = false;
  }

  getQueueSize(): number {
    return this.queue.length;
  }

  clear(): void {
    // Reject all pending items
    for (const item of this.queue) {
      item.reject(new Error('Queue cleared'));
    }
    this.queue = [];
  }
}
