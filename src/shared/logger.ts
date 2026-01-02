import { storage } from './storage';

class Logger {
  private showLogs = false;

  async initialize(): Promise<void> {
    const config = await storage.getFilterConfig();
    this.showLogs = config.showStatistics;

    // Listen for config changes
    storage.onFilterConfigChange((newConfig) => {
      this.showLogs = newConfig.showStatistics;
    });
  }

  log(...args: unknown[]): void {
    if (this.showLogs) {
      console.log(...args);
    }
  }

  warn(...args: unknown[]): void {
    if (this.showLogs) {
      console.warn(...args);
    }
  }

  // Always output errors regardless of settings
  error(...args: unknown[]): void {
    console.error(...args);
  }
}

export const logger = new Logger();
