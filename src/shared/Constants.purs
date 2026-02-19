module Shared.Constants where

-- Storage keys

storageKeyFilterConfig :: String
storageKeyFilterConfig = "filterConfig"

-- Tweet selectors (tried in order)

tweetSelectors :: Array String
tweetSelectors =
  [ "article[data-testid=\"tweet\"]"
  , "div[data-testid=\"cellInnerDiv\"] article"
  , "article[role=\"article\"]"
  ]

-- CSS classes

placeholderClass :: String
placeholderClass = "tweet-filter-placeholder"

-- Data attributes

collapsedAttribute :: String
collapsedAttribute = "tweetFilterCollapsed"

-- Processing config

batchSize :: Int
batchSize = 1

delayBetweenBatches :: Int
delayBetweenBatches = 100
