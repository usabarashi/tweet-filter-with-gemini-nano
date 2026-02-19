module Content.Main where

import Prelude

import Content.TweetFilter as TweetFilter
import Content.TweetObserver as TweetObserver
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, try)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import FFI.Chrome.Runtime as Runtime
import FFI.WebApi as WebApi
import Shared.EffectUtils as EffectUtils
import Shared.Logger as Logger
import Shared.Messaging.Client as Client
import Shared.Messaging.Types as Types
import Shared.Storage as Storage
import Shared.Types.Storage (FilterConfig, defaultFilterConfig, isFilteringActive, normalizeFilterConfig)

data FilteringMode
  = FilteringEnabled
  | FilteringDisabled

derive instance eqFilteringMode :: Eq FilteringMode

data TransitionAction
  = NoTransition
  | DisableAction
  | EnableAction
  | ReconfigureAction

derive instance eqTransitionAction :: Eq TransitionAction

data InitOutcome
  = InitSucceeded
  | InitFailed String

type ActiveRuntime =
  { filterRef :: Ref.Ref TweetFilter.FilterState
  , observerRef :: Ref.Ref TweetObserver.ObserverState
  , processTweet :: TweetObserver.TweetCallback
  , urlWatchActiveRef :: Ref.Ref Boolean
  , intervalIdRef :: Ref.Ref (Maybe Int)
  , popstateCleanupRef :: Ref.Ref (Effect Unit)
  }

main :: Effect Unit
main = do
  valid <- Runtime.isContextValid
  when valid do
    loggerRef <- Logger.newLogger
    retryTimerRef <- Ref.new Nothing
    configChangeCleanupRef <- Ref.new (pure unit :: Effect Unit)
    configRef <- Ref.new defaultFilterConfig
    activeRuntimeRef <- Ref.new Nothing
    setupConfigChangeListener loggerRef retryTimerRef configChangeCleanupRef configRef activeRuntimeRef
    launchAff_ $ initializeContentScript loggerRef retryTimerRef configRef activeRuntimeRef

initializeContentScript
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> Aff Unit
initializeContentScript loggerRef retryTimerRef configRef activeRuntimeRef = do
  config <- Storage.getFilterConfig
  let normalizedConfig = normalizeFilterConfig config
  let mode = classifyFilteringMode normalizedConfig
  liftEffect do
    Ref.write normalizedConfig configRef

  when (mode == FilteringEnabled) do
    result <- try $ ensureInitializedAndEnabled loggerRef retryTimerRef configRef activeRuntimeRef normalizedConfig
    case result of
      Right _ -> pure unit
      Left err -> do
        liftEffect $ Logger.logError loggerRef ("[Tweet Filter] Initialization failed: " <> show err)
        liftEffect $ scheduleRetry retryTimerRef loggerRef configRef activeRuntimeRef

scheduleRetry
  :: Ref.Ref (Maybe Int)
  -> Ref.Ref Logger.LoggerState
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> Effect Unit
scheduleRetry retryTimerRef loggerRef configRef activeRuntimeRef = do
  EffectUtils.clearMaybeRef retryTimerRef WebApi.clearTimeout
  tid <- WebApi.setTimeout 30000 do
    Ref.write Nothing retryTimerRef
    valid <- Runtime.isContextValid
    when valid do
      config <- Ref.read configRef
      when (classifyFilteringMode config == FilteringEnabled) $
        ensureInitializedAndEnabledAsync loggerRef retryTimerRef configRef activeRuntimeRef config
  Ref.write (Just tid) retryTimerRef

ensureInitializedAndEnabled
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> FilterConfig
  -> Aff Unit
ensureInitializedAndEnabled loggerRef retryTimerRef configRef activeRuntimeRef config = do
  resp <- Client.initialize config.prompt config.outputLanguage
  case decodeInitOutcome (Types.decodeMessage resp) of
    InitSucceeded ->
      liftEffect $ enableFiltering loggerRef activeRuntimeRef
    InitFailed reason -> do
      liftEffect $ Logger.logError loggerRef ("[Tweet Filter] Service worker initialization failed: " <> reason)
      liftEffect $ scheduleRetry retryTimerRef loggerRef configRef activeRuntimeRef

setupUrlChangeDetection
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref TweetObserver.ObserverState
  -> TweetObserver.TweetCallback
  -> Ref.Ref Boolean
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref (Effect Unit)
  -> Effect Unit
setupUrlChangeDetection loggerRef observerRef cb activeRef intervalIdRef popstateCleanupRef = do
  EffectUtils.runCleanupRef popstateCleanupRef
  EffectUtils.clearMaybeRef intervalIdRef WebApi.clearInterval

  currentUrlRef <- WebApi.getLocationHref >>= Ref.new
  let
    checkUrlChange = do
      active <- Ref.read activeRef
      when active do
        currentUrl <- Ref.read currentUrlRef
        newUrl <- WebApi.getLocationHref
        when (newUrl /= currentUrl) do
          Logger.log loggerRef ("[Tweet Filter] Page navigation detected: " <> currentUrl <> " -> " <> newUrl)
          Ref.write newUrl currentUrlRef
          TweetObserver.stop observerRef
          void $ WebApi.setTimeout 500 $ TweetObserver.start observerRef cb

  intervalId <- WebApi.setInterval 1000 checkUrlChange
  Ref.write (Just intervalId) intervalIdRef
  cleanup <- WebApi.addPopstateListener checkUrlChange
  Ref.write cleanup popstateCleanupRef

setupConfigChangeListener
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref (Effect Unit)
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> Effect Unit
setupConfigChangeListener loggerRef retryTimerRef configChangeCleanupRef configRef activeRuntimeRef = do
  EffectUtils.runCleanupRef configChangeCleanupRef
  timeoutRef <- Ref.new Nothing
  cleanupRaw <- Storage.onFilterConfigChange \newConfig -> do
    EffectUtils.clearMaybeRef timeoutRef WebApi.clearTimeout
    tid <- WebApi.setTimeout 300 do
      prevConfig <- Ref.read configRef
      let normalizedConfig = normalizeFilterConfig newConfig
      let action = decideTransition prevConfig normalizedConfig
      Ref.write normalizedConfig configRef
      applyTransition loggerRef retryTimerRef configRef activeRuntimeRef action normalizedConfig
    Ref.write (Just tid) timeoutRef

  let cleanup = do
        EffectUtils.clearMaybeRef timeoutRef WebApi.clearTimeout
        cleanupRaw
  Ref.write cleanup configChangeCleanupRef

applyTransition
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> TransitionAction
  -> FilterConfig
  -> Effect Unit
applyTransition loggerRef retryTimerRef configRef activeRuntimeRef action newConfig =
  case action of
    DisableAction ->
      disableFiltering activeRuntimeRef retryTimerRef
    EnableAction ->
      ensureInitializedAndEnabledAsync loggerRef retryTimerRef configRef activeRuntimeRef newConfig
    ReconfigureAction ->
      ensureInitializedAndEnabledAsync loggerRef retryTimerRef configRef activeRuntimeRef newConfig
    NoTransition ->
      pure unit

ensureInitializedAndEnabledAsync
  :: Ref.Ref Logger.LoggerState
  -> Ref.Ref (Maybe Int)
  -> Ref.Ref FilterConfig
  -> Ref.Ref (Maybe ActiveRuntime)
  -> FilterConfig
  -> Effect Unit
ensureInitializedAndEnabledAsync loggerRef retryTimerRef configRef activeRuntimeRef config =
  launchAff_ do
    result <- try $ ensureInitializedAndEnabled loggerRef retryTimerRef configRef activeRuntimeRef config
    case result of
      Left err -> do
        liftEffect $ Logger.logError loggerRef ("[Tweet Filter] Async initialization failed: " <> show err)
        liftEffect $ when (classifyFilteringMode config == FilteringEnabled) $
          scheduleRetry retryTimerRef loggerRef configRef activeRuntimeRef
      Right _ ->
        pure unit

classifyFilteringMode :: FilterConfig -> FilteringMode
classifyFilteringMode config =
  if isFilteringActive config then FilteringEnabled else FilteringDisabled

decideTransition :: FilterConfig -> FilterConfig -> TransitionAction
decideTransition prevConfig nextConfig =
  case classifyFilteringMode prevConfig, classifyFilteringMode nextConfig of
    FilteringDisabled, FilteringDisabled -> NoTransition
    FilteringEnabled, FilteringDisabled -> DisableAction
    FilteringDisabled, FilteringEnabled -> EnableAction
    FilteringEnabled, FilteringEnabled ->
      if runtimeConfigChanged prevConfig nextConfig then ReconfigureAction else NoTransition

runtimeConfigChanged :: FilterConfig -> FilterConfig -> Boolean
runtimeConfigChanged prevConfig nextConfig =
  let prev = normalizeFilterConfig prevConfig
      next = normalizeFilterConfig nextConfig
  in prev.prompt /= next.prompt
      || prev.outputLanguage /= next.outputLanguage

decodeInitOutcome :: Either String Types.Message -> InitOutcome
decodeInitOutcome decodeResult = case decodeResult of
  Right (Types.InitResponse r)
    | Types.isInitResponseSuccess r -> InitSucceeded
    | otherwise -> InitFailed (fromMaybe "init response indicated failure" r.error)
  Right (Types.ErrorMessage r) ->
    InitFailed ("error response: " <> r.error)
  Right other ->
    InitFailed ("unexpected response type: " <> Types.messageType other)
  Left err ->
    InitFailed ("decode error: " <> err)

ensureActiveRuntime :: Ref.Ref Logger.LoggerState -> Ref.Ref (Maybe ActiveRuntime) -> Effect ActiveRuntime
ensureActiveRuntime loggerRef activeRuntimeRef = do
  existing <- Ref.read activeRuntimeRef
  case existing of
    Just runtime -> pure runtime
    Nothing -> do
      filterRef <- TweetFilter.new loggerRef
      observerRef <- TweetObserver.new loggerRef
      urlWatchActiveRef <- Ref.new false
      intervalIdRef <- Ref.new Nothing
      popstateCleanupRef <- Ref.new (pure unit :: Effect Unit)
      let processTweet = TweetFilter.processTweet filterRef
      let runtime = { filterRef, observerRef, processTweet, urlWatchActiveRef, intervalIdRef, popstateCleanupRef }
      Ref.write (Just runtime) activeRuntimeRef
      pure runtime

disableFiltering :: Ref.Ref (Maybe ActiveRuntime) -> Ref.Ref (Maybe Int) -> Effect Unit
disableFiltering activeRuntimeRef retryTimerRef = do
  cancelRetryTimer retryTimerRef
  mRuntime <- Ref.read activeRuntimeRef
  case mRuntime of
    Nothing -> pure unit
    Just runtime -> do
      stopUrlWatcher runtime.intervalIdRef runtime.popstateCleanupRef
      Ref.write false runtime.urlWatchActiveRef
      TweetObserver.stop runtime.observerRef
      TweetFilter.destroy runtime.filterRef

enableFiltering :: Ref.Ref Logger.LoggerState -> Ref.Ref (Maybe ActiveRuntime) -> Effect Unit
enableFiltering loggerRef activeRuntimeRef = do
  runtime <- ensureActiveRuntime loggerRef activeRuntimeRef
  TweetObserver.stop runtime.observerRef
  TweetFilter.destroy runtime.filterRef
  Ref.write true runtime.urlWatchActiveRef
  restartUrlWatcherIfNeeded loggerRef runtime
  TweetObserver.start runtime.observerRef runtime.processTweet

cancelRetryTimer :: Ref.Ref (Maybe Int) -> Effect Unit
cancelRetryTimer retryTimerRef = EffectUtils.clearMaybeRef retryTimerRef WebApi.clearTimeout

stopUrlWatcher :: Ref.Ref (Maybe Int) -> Ref.Ref (Effect Unit) -> Effect Unit
stopUrlWatcher intervalIdRef popstateCleanupRef = do
  EffectUtils.clearMaybeRef intervalIdRef WebApi.clearInterval
  EffectUtils.runCleanupRef popstateCleanupRef

restartUrlWatcherIfNeeded :: Ref.Ref Logger.LoggerState -> ActiveRuntime -> Effect Unit
restartUrlWatcherIfNeeded loggerRef runtime = do
  iid <- Ref.read runtime.intervalIdRef
  when (isNothing iid) $
    setupUrlChangeDetection
      loggerRef
      runtime.observerRef
      runtime.processTweet
      runtime.urlWatchActiveRef
      runtime.intervalIdRef
      runtime.popstateCleanupRef
