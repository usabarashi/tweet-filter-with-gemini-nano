module Background.MessageHandler where

import Prelude

import Background.CacheManager as Cache
import Background.OffscreenManager as Offscreen
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), isNothing)
import Effect.Aff (Aff, try)
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import FFI.WebApi as WebApi
import Foreign (Foreign)
import Shared.Logger as Logger
import Shared.Messaging.Types as Types
import Shared.Types.Tweet (MediaData, QuotedTweet)

-- | Dependencies for the message handler
type Deps =
  { cache :: Cache.CacheState
  , offscreen :: Offscreen.OffscreenState
  , logger :: Ref Logger.LoggerState
  }

-- | Handle an incoming message and return a response.
-- | Uses decodeMessage for type-safe dispatch instead of raw unsafeFromForeign.
handleMessage :: Deps -> Foreign -> Aff Foreign
handleMessage deps msg = do
  let decodeResult = Types.decodeMessage msg
  case decodeResult of
    Left err -> do
      ts <- liftEffect WebApi.dateNow
      pure $ mkErrorResponse "" ("Failed to decode message: " <> err) ts
    Right message -> do
      result <- try $ dispatch deps message
      case result of
        Right resp -> pure resp
        Left err -> do
          ts <- liftEffect WebApi.dateNow
          pure $ mkErrorResponse (Types.requestId message) (show err) ts

-- | Dispatch by Message ADT constructor.
dispatch :: Deps -> Types.Message -> Aff Foreign
dispatch deps (Types.InitRequest r) = handleInitRequest deps r
dispatch deps (Types.EvaluateRequest r) = handleEvaluateRequest deps r
dispatch deps (Types.SessionStatusRequest r) = handleSessionStatusRequest deps r
dispatch deps (Types.CacheCheckRequest r) = handleCacheCheckRequest deps r
dispatch _ message = do
  ts <- liftEffect WebApi.dateNow
  pure $ mkErrorResponse (Types.requestId message) ("Unknown message type: " <> Types.messageType message) ts

-- | Forward INIT_REQUEST to offscreen using encodeMessage for type-safe re-encoding.
handleInitRequest
  :: Deps
  -> { requestId :: String, timestamp :: Number, config :: Types.SessionConfig }
  -> Aff Foreign
handleInitRequest deps r = do
  liftEffect $ Logger.log deps.logger "[MessageHandler] Handling INIT_REQUEST"
  let fwdMsg = Types.encodeMessage (Types.InitRequest r)
  resp <- Offscreen.sendToOffscreen deps.offscreen fwdMsg
  case Types.decodeMessage resp of
    Right (Types.InitResponse ir) ->
      pure $ Types.encodeMessage (setInitResponseRequestId r.requestId ir)
    Right (Types.ErrorMessage er) ->
      pure $ Types.encodeMessage (setErrorMessageRequestId r.requestId er)
    _ -> do
      ts <- liftEffect WebApi.dateNow
      pure $ mkErrorResponse r.requestId "Failed to decode init response from offscreen" ts

-- | Handle EVALUATE_REQUEST: check cache, then forward to offscreen.
handleEvaluateRequest
  :: Deps
  -> { requestId :: String, timestamp :: Number, tweetId :: String, textContent :: String, media :: Maybe (Array MediaData), quotedTweet :: Maybe QuotedTweet }
  -> Aff Foreign
handleEvaluateRequest deps r = do
  liftEffect $ Logger.log deps.logger ("[MessageHandler] Handling EVALUATE_REQUEST for tweet: " <> r.tweetId)
  -- Check cache
  cached <- Cache.get deps.cache r.tweetId
  case cached of
    Just shouldShow -> do
      liftEffect $ Logger.log deps.logger ("[MessageHandler] Cache hit for tweet: " <> r.tweetId)
      ts <- liftEffect WebApi.dateNow
      pure $ Types.encodeMessage $ Types.EvaluateResponse
        { requestId: r.requestId, timestamp: ts, tweetId: r.tweetId
        , shouldShow, cacheHit: true, evaluationTime: 0.0, error: Nothing }
    Nothing -> do
      liftEffect $ Logger.log deps.logger ("[MessageHandler] Cache miss for tweet: " <> r.tweetId)
      -- Forward to offscreen using encodeMessage
      let fwdMsg = Types.encodeMessage (Types.EvaluateRequest r)
      resp <- Offscreen.sendToOffscreen deps.offscreen fwdMsg
      -- Decode response to extract shouldShow for caching
      let respResult = Types.decodeMessage resp
      case respResult of
        Right (Types.EvaluateResponse er) -> do
          when (shouldCacheEvaluation er) do
            cacheWrite <- try $ Cache.set deps.cache r.tweetId er.shouldShow
            case cacheWrite of
              Left cacheErr ->
                liftEffect $ Logger.warn deps.logger ("[MessageHandler] Failed to persist cache entry for tweet " <> r.tweetId <> ": " <> show cacheErr)
              Right _ -> pure unit
          -- Return response with original requestId
          pure $ Types.encodeMessage (setEvaluateResponseRequestId r.requestId er)
        Right (Types.ErrorMessage er) ->
          pure $ Types.encodeMessage (setErrorMessageRequestId r.requestId er)
        _ -> do
          ts <- liftEffect WebApi.dateNow
          pure $ mkErrorResponse r.requestId "Unexpected response type from offscreen" ts

-- | Forward SESSION_STATUS_REQUEST to offscreen.
handleSessionStatusRequest
  :: Deps
  -> { requestId :: String, timestamp :: Number }
  -> Aff Foreign
handleSessionStatusRequest deps r = do
  liftEffect $ Logger.log deps.logger "[MessageHandler] Handling SESSION_STATUS_REQUEST"
  let fwdMsg = Types.encodeMessage (Types.SessionStatusRequest r)
  resp <- Offscreen.sendToOffscreen deps.offscreen fwdMsg
  case Types.decodeMessage resp of
    Right (Types.SessionStatusResponse sr) ->
      pure $ Types.encodeMessage (setSessionStatusResponseRequestId r.requestId sr)
    Right (Types.ErrorMessage er) ->
      pure $ Types.encodeMessage (setErrorMessageRequestId r.requestId er)
    _ -> do
      ts <- liftEffect WebApi.dateNow
      pure $ mkErrorResponse r.requestId "Failed to decode session status response from offscreen" ts

-- | Handle CACHE_CHECK_REQUEST locally (no offscreen forwarding needed).
handleCacheCheckRequest
  :: Deps
  -> { requestId :: String, timestamp :: Number, tweetIds :: Array String }
  -> Aff Foreign
handleCacheCheckRequest deps r = do
  liftEffect $ Logger.log deps.logger "[MessageHandler] Handling CACHE_CHECK_REQUEST"
  results <- Cache.getBatch deps.cache r.tweetIds
  ts <- liftEffect WebApi.dateNow
  pure $ Types.encodeMessage $ Types.CacheCheckResponse
    { requestId: r.requestId, timestamp: ts, results }

-- | Create an error response
mkErrorResponse :: String -> String -> Number -> Foreign
mkErrorResponse reqId err ts = Types.encodeMessage $ Types.ErrorMessage
  { requestId: reqId, timestamp: ts, error: err, originalRequestId: Nothing }

shouldCacheEvaluation
  :: { requestId :: String
     , timestamp :: Number
     , tweetId :: String
     , shouldShow :: Boolean
     , cacheHit :: Boolean
     , evaluationTime :: Number
     , error :: Maybe String
     }
  -> Boolean
shouldCacheEvaluation response = isNothing response.error

setInitResponseRequestId
  :: String
  -> { requestId :: String
     , timestamp :: Number
     , success :: Boolean
     , sessionStatus :: Types.SessionStatus
     , error :: Maybe String
     }
  -> Types.Message
setInitResponseRequestId requestId response =
  Types.InitResponse (response { requestId = requestId })

setSessionStatusResponseRequestId
  :: String
  -> { requestId :: String
     , timestamp :: Number
     , initialized :: Boolean
     , isMultimodal :: Boolean
     , currentConfig :: Maybe Types.SessionConfig
     }
  -> Types.Message
setSessionStatusResponseRequestId requestId response =
  Types.SessionStatusResponse (response { requestId = requestId })

setErrorMessageRequestId
  :: String
  -> { requestId :: String
     , timestamp :: Number
     , error :: String
     , originalRequestId :: Maybe String
     }
  -> Types.Message
setErrorMessageRequestId requestId response =
  Types.ErrorMessage (response { requestId = requestId })

setEvaluateResponseRequestId
  :: String
  -> { requestId :: String
     , timestamp :: Number
     , tweetId :: String
     , shouldShow :: Boolean
     , cacheHit :: Boolean
     , evaluationTime :: Number
     , error :: Maybe String
     }
  -> Types.Message
setEvaluateResponseRequestId requestId response =
  Types.EvaluateResponse (response { requestId = requestId, cacheHit = false })
