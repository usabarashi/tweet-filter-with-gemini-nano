export type OutputLanguage = 'en' | 'es' | 'ja';

export interface FilterConfig {
  enabled: boolean;
  prompt: string;
  showStatistics: boolean;
  outputLanguage: OutputLanguage;
}

export interface StorageSchema {
  filterConfig: FilterConfig;
}

export const DEFAULT_FILTER_CONFIG: FilterConfig = {
  enabled: true,
  prompt: 'technical content, programming and development, AI/ML research',
  showStatistics: false,
  outputLanguage: 'en',
};
