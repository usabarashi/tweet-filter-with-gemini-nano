module Content.DomManipulator where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Effect (Effect)
import FFI.WebApi (Element)
import FFI.WebApi as WebApi
import Shared.Constants (collapsedAttribute, placeholderClass)

-- | Collapse a tweet by inserting a placeholder and hiding content
collapseTweet :: Element -> Effect Unit
collapseTweet element = do
  connected <- WebApi.isConnected element
  when connected do
    existing <- WebApi.getDataset element collapsedAttribute
    case toMaybe existing of
      Nothing -> do
        placeholder <- WebApi.createElement "div"
        WebApi.setClassName placeholder placeholderClass
        WebApi.setInnerHTML placeholder placeholderHtml
        -- Add expand handler on the button
        expandBtn <- WebApi.querySelector placeholder ".tweet-filter-expand-btn"
        case toMaybe expandBtn of
          Nothing -> pure unit
          Just btn -> void $ WebApi.addClickListener btn \ev -> do
            WebApi.stopPropagation ev
            WebApi.preventDefault ev
            expandTweet element
        WebApi.prependChild element placeholder
        WebApi.setDataset element collapsedAttribute "true"
      _ -> pure unit -- Already collapsed

-- | Expand a collapsed tweet
expandTweet :: Element -> Effect Unit
expandTweet element = do
  mPlaceholder <- WebApi.querySelector element ("." <> placeholderClass)
  case toMaybe mPlaceholder of
    Nothing -> pure unit
    Just ph -> do
      -- Remove placeholder by setting innerHTML to empty
      -- (Using parent.removeChild pattern via FFI)
      WebApi.removeElement ph
  WebApi.removeDataset element collapsedAttribute

-- | Mark a tweet as processed
markAsProcessed :: Element -> Effect Unit
markAsProcessed element =
  WebApi.setDataset element "tweetFilterProcessed" "true"

-- | Check if a tweet is already processed
isProcessed :: Element -> Effect Boolean
isProcessed element = do
  val <- WebApi.getDataset element "tweetFilterProcessed"
  case toMaybe val of
    Just "true" -> pure true
    _ -> pure false

-- Placeholder HTML template
placeholderHtml :: String
placeholderHtml =
  """
  <div class="tweet-filter-placeholder-content">
    <span class="tweet-filter-icon">&#128274;</span>
    <span class="tweet-filter-text">Tweet hidden by filter</span>
    <button class="tweet-filter-expand-btn">Show</button>
  </div>
  """
