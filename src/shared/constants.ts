export const STORAGE_KEYS = {
  FILTER_CONFIG: 'filterConfig',
} as const;

export const TWEET_SELECTORS = [
  'article[data-testid="tweet"]',
  'div[data-testid="cellInnerDiv"] article',
  'article[role="article"]',
] as const;

export const CSS_CLASSES = {
  PLACEHOLDER: 'tweet-filter-placeholder',
} as const;

export const DATA_ATTRIBUTES = {
  COLLAPSED: 'tweetFilterCollapsed',
} as const;

export const PROCESSING_CONFIG = {
  BATCH_SIZE: 1,
  DELAY_BETWEEN_BATCHES: 100, // ms
} as const;
