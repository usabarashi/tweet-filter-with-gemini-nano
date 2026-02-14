import type { FilterConfig } from '../types/storage';
import { DEFAULT_FILTER_CONFIG } from '../types/storage';
import { STORAGE_KEYS } from './constants';

export const storage = {
  async getFilterConfig(): Promise<FilterConfig> {
    if (!chrome.storage?.sync) return { ...DEFAULT_FILTER_CONFIG };
    const result = await chrome.storage.sync.get([STORAGE_KEYS.FILTER_CONFIG]);
    const saved = result[STORAGE_KEYS.FILTER_CONFIG] as Partial<FilterConfig> | undefined;
    return { ...DEFAULT_FILTER_CONFIG, ...saved };
  },

  async setFilterConfig(config: Partial<FilterConfig>): Promise<void> {
    if (!chrome.storage?.sync) return;
    const current = await this.getFilterConfig();
    await chrome.storage.sync.set({
      [STORAGE_KEYS.FILTER_CONFIG]: { ...current, ...config },
    });
  },

  onFilterConfigChange(callback: (config: FilterConfig) => void): void {
    if (!chrome.storage?.onChanged) return;
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'sync' && changes[STORAGE_KEYS.FILTER_CONFIG]?.newValue) {
        callback(changes[STORAGE_KEYS.FILTER_CONFIG].newValue as FilterConfig);
      }
    });
  },
};
