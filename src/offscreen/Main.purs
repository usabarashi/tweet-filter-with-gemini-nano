module Offscreen.Main where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.AVar as EAVar
import Effect.Aff (Aff, launchAff_, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import FFI.Chrome.Runtime as Runtime
import FFI.WebApi as WebApi
import Foreign (Foreign, unsafeFromForeign, typeOf, isArray, isNull, isUndefined)
import Foreign.Object as Object
import Offscreen.EvaluationQueue as Queue
import Offscreen.EvaluationService as EvalService
import Offscreen.SessionManager as SessionManager
import Shared.Logger as Logger
import Shared.Messaging.Types as Types
import Shared.Types.Tweet (MediaData, QuotedTweet)

type OffscreenDeps =
  { sessionRef :: Ref SessionManager.SessionState
  , queue :: Queue.Queue
  , logger :: Ref Logger.LoggerState
  }

main :: Effect Unit
main = do
  loggerRef <- Logger.newSimpleLogger true
  Logger.log loggerRef "[Offscreen] Offscreen document initialized"

  sessionRef <- SessionManager.new loggerRef

  -- Create an empty AVar that blocks readers until deps are ready
  depsVar <- EAVar.empty

  -- Register message listener synchronously so it's ready immediately
  Runtime.addMessageListener (messageListener loggerRef depsVar)
  Logger.log loggerRef "[Offscreen] Message handlers registered"

  -- Initialize queue asynchronously; AVar.put unblocks waiting message handlers
  launchAff_ do
    queue <- Queue.new
    let deps = { sessionRef, queue, logger: loggerRef }
    AVar.put deps depsVar
    liftEffect $ Logger.log loggerRef "[Offscreen] Queue initialized"

-- | Message listener that ignores content script messages (those with sender.tab).
-- | Returns false for ignored messages so Chrome does not keep the channel open.
messageListener
  :: Ref Logger.LoggerState
  -> AVar OffscreenDeps
  -> Foreign -> Foreign -> (Foreign -> Effect Unit) -> Effect Boolean
messageListener loggerRef depsVar message sender sendResponse = do
  -- Content scripts have sender.tab; service worker does not.
  -- Defensively decode sender to avoid crashing on malformed Foreign.
  case hasSenderTab sender of
    Nothing -> pure false  -- Malformed sender, ignore
    Just true -> pure false  -- Content script message, ignore
    Just false -> do
      Logger.log loggerRef "[Offscreen] Received message"
      launchAff_ do
        deps <- AVar.read depsVar
        response <- handleMessage deps message
        liftEffect $ sendResponse response
      pure true  -- will call sendResponse asynchronously

-- | Decode incoming message with the typed decoder and dispatch by ADT constructor.
handleMessage :: OffscreenDeps -> Foreign -> Aff Foreign
handleMessage deps msg = do
  let decodeResult = Types.decodeMessage msg
  case decodeResult of
    Left err -> mkTimestampedError "" ("Failed to decode message: " <> err)
    Right message -> do
      result <- try $ dispatch deps message
      case result of
        Right resp -> pure resp
        Left err -> mkTimestampedError (Types.requestId message) (show err)

-- | Dispatch by Message ADT constructor (no string comparison).
dispatch :: OffscreenDeps -> Types.Message -> Aff Foreign
dispatch deps (Types.InitRequest r) = handleInitRequest deps r
dispatch deps (Types.EvaluateRequest r) = handleEvaluateRequest deps r
dispatch deps (Types.SessionStatusRequest r) = handleSessionStatusRequest deps r
dispatch deps (Types.ReinitRequest r) = handleReinitRequest deps r
dispatch _ message = mkTimestampedError (Types.requestId message)
  ("Unexpected message type in offscreen: " <> Types.messageType message)

handleInitRequest
  :: OffscreenDeps
  -> { requestId :: String, timestamp :: Number, config :: Types.SessionConfig }
  -> Aff Foreign
handleInitRequest deps r = do
  liftEffect $ Logger.log deps.logger "[Offscreen] Handling INIT_REQUEST"
  initResult <- SessionManager.initialize deps.sessionRef r.config
  isMulti <- liftEffect $ SessionManager.isMultimodalEnabled deps.sessionRef
  sessType <- liftEffect $ SessionManager.getSessionType deps.sessionRef
  ts <- liftEffect WebApi.dateNow
  pure $ Types.encodeMessage $ Types.InitResponse
    { requestId: r.requestId, timestamp: ts, success: SessionManager.isInitializeSuccess initResult
    , sessionStatus: { isMultimodal: isMulti, sessionType: sessType }
    , error: SessionManager.initializeErrorMessage initResult }

handleEvaluateRequest
  :: OffscreenDeps
  -> { requestId :: String, timestamp :: Number, tweetId :: String, textContent :: String, media :: Maybe (Array MediaData), quotedTweet :: Maybe QuotedTweet }
  -> Aff Foreign
handleEvaluateRequest deps r = do
  liftEffect $ Logger.log deps.logger "[Offscreen] Handling EVALUATE_REQUEST"
  result <- try $ Queue.enqueue deps.queue $
    EvalService.evaluateTweet deps.sessionRef
      { tweetId: r.tweetId
      , textContent: r.textContent
      , media: r.media
      , quotedTweet: r.quotedTweet
      }
  ts <- liftEffect WebApi.dateNow
  case result of
    Right queueResult -> case queueResult of
      Queue.Enqueued evalResult ->
        pure $ Types.encodeMessage $ Types.EvaluateResponse
          { requestId: r.requestId, timestamp: ts, tweetId: r.tweetId
          , shouldShow: evalResult.shouldShow, cacheHit: false
          , evaluationTime: evalResult.evaluationTime, error: evalResult.error }
      Queue.DroppedByClear ->
        pure $ Types.encodeMessage $ Types.ErrorMessage
          { requestId: r.requestId, timestamp: ts
          , error: "Evaluation canceled due to queue clear"
          , originalRequestId: Nothing
          }
    Left err ->
      pure $ Types.encodeMessage $ Types.ErrorMessage
        { requestId: r.requestId, timestamp: ts
        , error: "Evaluation failed: " <> show err
        , originalRequestId: Nothing
        }

handleSessionStatusRequest
  :: OffscreenDeps
  -> { requestId :: String, timestamp :: Number }
  -> Aff Foreign
handleSessionStatusRequest deps r = do
  liftEffect $ Logger.log deps.logger "[Offscreen] Handling SESSION_STATUS_REQUEST"
  initialized <- liftEffect $ SessionManager.isInitialized deps.sessionRef
  isMulti <- liftEffect $ SessionManager.isMultimodalEnabled deps.sessionRef
  config <- liftEffect $ SessionManager.getCurrentConfig deps.sessionRef
  ts <- liftEffect WebApi.dateNow
  pure $ Types.encodeMessage $ Types.SessionStatusResponse
    { requestId: r.requestId, timestamp: ts, initialized
    , isMultimodal: isMulti, currentConfig: config }

handleReinitRequest
  :: OffscreenDeps
  -> { requestId :: String, timestamp :: Number, config :: Types.SessionConfig }
  -> Aff Foreign
handleReinitRequest deps r = do
  liftEffect $ Logger.log deps.logger "[Offscreen] Handling REINIT_REQUEST"
  Queue.clear deps.queue
  initResult <- SessionManager.initialize deps.sessionRef r.config
  isMulti <- liftEffect $ SessionManager.isMultimodalEnabled deps.sessionRef
  sessType <- liftEffect $ SessionManager.getSessionType deps.sessionRef
  ts <- liftEffect WebApi.dateNow
  pure $ Types.encodeMessage $ Types.InitResponse
    { requestId: r.requestId, timestamp: ts, success: SessionManager.isInitializeSuccess initResult
    , sessionStatus: { isMultimodal: isMulti, sessionType: sessType }
    , error: SessionManager.initializeErrorMessage initResult }

-- | Construct a timestamped error response.
mkTimestampedError :: String -> String -> Aff Foreign
mkTimestampedError reqId errMsg = do
  ts <- liftEffect WebApi.dateNow
  pure $ Types.encodeMessage $ Types.ErrorMessage
    { requestId: reqId, timestamp: ts, error: errMsg, originalRequestId: Nothing }

hasSenderTab :: Foreign -> Maybe Boolean
hasSenderTab raw
  | typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw = Nothing
  | otherwise =
      let senderObj = (unsafeFromForeign raw) :: Object.Object Foreign
      in Just (case Object.lookup "tab" senderObj of
          Just tabVal | isNull tabVal || isUndefined tabVal -> false
          Just _ -> true
          Nothing -> false
         )
