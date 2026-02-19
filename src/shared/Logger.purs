module Shared.Logger where

import Prelude

import Effect (Effect)
import Effect.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Shared.Storage as Storage
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)

-- | Logger state: whether logs are enabled
type LoggerState =
  { showLogs :: Boolean
  }

-- | Create a simple logger without chrome.storage dependency.
-- | Use this in contexts where chrome.storage is unavailable (e.g. offscreen documents).
newSimpleLogger :: Boolean -> Effect (Ref LoggerState)
newSimpleLogger showLogs = Ref.new { showLogs }

-- | Create a new logger, reading initial config and listening for changes.
-- | Requires chrome.storage access (service worker, content script, options page).
newLogger :: Effect (Ref LoggerState)
newLogger = do
  ref <- Ref.new { showLogs: false }
  -- Initialize from stored config asynchronously
  launchAff_ do
    config <- Storage.getFilterConfig
    liftEffect $ Ref.modify_ (_ { showLogs = config.showStatistics }) ref
  -- Listen for config changes
  void $ Storage.onFilterConfigChange \newConfig ->
    Ref.modify_ (_ { showLogs = newConfig.showStatistics }) ref
  pure ref

-- | Log message (only if showStatistics is enabled)
log :: Ref LoggerState -> String -> Effect Unit
log ref msg = do
  state <- Ref.read ref
  when state.showLogs $ Console.log msg

-- | Warn message (only if showStatistics is enabled)
warn :: Ref LoggerState -> String -> Effect Unit
warn ref msg = do
  state <- Ref.read ref
  when state.showLogs $ Console.warn msg

-- | Error message (always shown)
logError :: Ref LoggerState -> String -> Effect Unit
logError _ msg = Console.error msg
