export const STORAGE_KEYS = {
  FILTER_CONFIG: 'filterConfig',
} as const;

export const TWEET_SELECTORS = [
  'article[data-testid="tweet"]',
  'div[data-testid="cellInnerDiv"] article',
  'article[role="article"]',
] as const;

export const CSS_CLASSES = {
  COLLAPSED: 'tweet-filter-collapsed',
  PLACEHOLDER: 'tweet-filter-placeholder',
} as const;

export const PROCESSING_CONFIG = {
  BATCH_SIZE: 1,
  DELAY_BETWEEN_BATCHES: 100, // ms
  QUOTA_WARNING_THRESHOLD: 0.9, // 90% of quota
} as const;
