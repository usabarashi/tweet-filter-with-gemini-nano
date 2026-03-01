module Background.Main where

import Prelude

import Background.CacheManager as Cache
import Background.MessageHandler as Handler
import Background.OffscreenManager as Offscreen
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.AVar as EAVar
import Effect.Aff (launchAff_, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.Chrome.Runtime as Runtime
import FFI.WebApi as WebApi
import Foreign (Foreign)
import Shared.Logger as Logger
import Shared.Messaging.Types as Types
import Shared.Storage as Storage
import Shared.Types.Storage (FilterConfig, isFilteringActive, normalizeFilterConfig)

main :: Effect Unit
main = do
  loggerRef <- Logger.newLogger
  Logger.log loggerRef "[ServiceWorker] Tweet Filter Service Worker initializing..."

  -- Create an empty AVar that blocks readers until deps are ready
  depsVar <- EAVar.empty
  configChangeInProgressRef <- Ref.new false
  pendingConfigRef <- Ref.new (Nothing :: Maybe FilterConfig)

  -- Register message listener synchronously so it's ready before content scripts fire
  Runtime.addMessageListener (messageListener loggerRef depsVar)

  -- Register config change listener synchronously
  void $ Storage.onFilterConfigChange (onConfigChange configChangeInProgressRef pendingConfigRef loggerRef depsVar)

  -- Service worker lifecycle events
  WebApi.addServiceWorkerEventListener "activate" $
    Logger.log loggerRef "[ServiceWorker] Activated"

  WebApi.addServiceWorkerEventListener "install" do
    Logger.log loggerRef "[ServiceWorker] Installed"
    WebApi.skipWaiting

  -- Initialize state asynchronously; AVar.put unblocks waiting message handlers
  launchAff_ do
    cache <- Cache.new loggerRef
    offscreen <- Offscreen.new loggerRef
    let deps = { cache, offscreen, logger: loggerRef }
    AVar.put deps depsVar
    liftEffect $ Logger.log loggerRef "[ServiceWorker] Tweet Filter Service Worker initialized"

-- | Message listener callback.
-- | Waits for deps to be ready (AVar.read blocks until put).
messageListener
  :: Ref Logger.LoggerState
  -> AVar Handler.Deps
  -> Foreign -> Foreign -> (Foreign -> Effect Unit) -> Effect Boolean
messageListener loggerRef depsVar message _sender sendResponse = do
  Logger.log loggerRef "[ServiceWorker] Received message"
  launchAff_ do
    deps <- AVar.read depsVar
    response <- Handler.handleMessage deps message
    liftEffect $ sendResponse response
  pure true  -- will call sendResponse asynchronously

-- | Config change handler with coalescing.
-- | If a config change arrives during processing, it is stored as pending
-- | and applied after the current handler completes.
onConfigChange :: Ref Boolean -> Ref (Maybe FilterConfig) -> Ref Logger.LoggerState -> AVar Handler.Deps -> FilterConfig -> Effect Unit
onConfigChange configChangeInProgressRef pendingConfigRef loggerRef depsVar newConfig = do
  inProgress <- Ref.read configChangeInProgressRef
  if inProgress
    then Ref.write (Just newConfig) pendingConfigRef
    else do
      Ref.write true configChangeInProgressRef
      Ref.write Nothing pendingConfigRef
      Logger.log loggerRef "[ServiceWorker] Config changed"
      launchAff_ do
        void $ try do
          deps <- AVar.read depsVar
          let normalizedConfig = normalizeFilterConfig newConfig
          if not (isFilteringActive normalizedConfig) then do
            liftEffect $ Logger.log deps.logger "[ServiceWorker] Filtering disabled, clearing resources"
            Offscreen.destroy deps.offscreen
            Cache.clear deps.cache
          else do
            liftEffect $ Logger.log deps.logger "[ServiceWorker] Config updated, reinitializing"
            Cache.clear deps.cache
            let reinitMsg = Types.encodeMessage $ Types.ReinitRequest
                  { requestId: ""
                  , timestamp: 0.0
                  , config: { prompt: normalizedConfig.prompt, outputLanguage: normalizedConfig.outputLanguage }
                  }
            response <- Offscreen.sendToOffscreen deps.offscreen reinitMsg
            case Types.decodeMessage response of
              Right (Types.InitResponse initResp) ->
                if initResp.success then
                  liftEffect $ Logger.log deps.logger "[ServiceWorker] Reinitialize succeeded"
                else
                  liftEffect $ Logger.warn deps.logger ("[ServiceWorker] Reinitialize failed: " <> show initResp.error)
              Right (Types.ErrorMessage errResp) ->
                liftEffect $ Logger.warn deps.logger ("[ServiceWorker] Reinitialize error response: " <> errResp.error)
              Right other ->
                liftEffect $ Logger.warn deps.logger ("[ServiceWorker] Unexpected reinitialize response type: " <> Types.messageType other)
              Left decodeErr ->
                liftEffect $ Logger.warn deps.logger ("[ServiceWorker] Failed to decode reinitialize response: " <> decodeErr)
        liftEffect $ Ref.write false configChangeInProgressRef
        pending <- liftEffect $ Ref.read pendingConfigRef
        case pending of
          Nothing -> pure unit
          Just nextConfig ->
            liftEffect $ onConfigChange configChangeInProgressRef pendingConfigRef loggerRef depsVar nextConfig
