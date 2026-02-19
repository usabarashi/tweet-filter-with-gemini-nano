module Shared.Messaging.Types where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.Maybe (Maybe(..), isNothing)
import Data.Nullable (toNullable)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign (Foreign, unsafeFromForeign, unsafeToForeign, readString, readBoolean, readNumber, typeOf, isNull, isUndefined, isArray)
import Foreign.Object (Object)
import Foreign.Object as Object
import Shared.Messaging.Constants as C
import Shared.Types.Storage (OutputLanguage, SessionType, outputLanguageToString, parseOutputLanguage, sessionTypeFromString, sessionTypeToString)
import Shared.Types.Tweet (MediaData, MediaType, QuotedTweet, mediaTypeToString, parseMediaType)

-- | Session configuration sent in init/reinit requests
type SessionConfig =
  { prompt :: String
  , outputLanguage :: OutputLanguage
  }

-- | Session status returned in init response
type SessionStatus =
  { isMultimodal :: Boolean
  , sessionType :: Maybe SessionType
  }

-- | Full config sent in CONFIG_CHANGED messages
type FullConfig =
  { enabled :: Boolean
  , prompt :: String
  , outputLanguage :: OutputLanguage
  }

-- | Sum type for all extension messages
data Message
  = InitRequest
      { requestId :: String
      , timestamp :: Number
      , config :: SessionConfig
      }
  | InitResponse
      { requestId :: String
      , timestamp :: Number
      , success :: Boolean
      , sessionStatus :: SessionStatus
      , error :: Maybe String
      }
  | EvaluateRequest
      { requestId :: String
      , timestamp :: Number
      , tweetId :: String
      , textContent :: String
      , media :: Maybe (Array MediaData)
      , quotedTweet :: Maybe QuotedTweet
      }
  | EvaluateResponse
      { requestId :: String
      , timestamp :: Number
      , tweetId :: String
      , shouldShow :: Boolean
      , cacheHit :: Boolean
      , evaluationTime :: Number
      , error :: Maybe String
      }
  | CacheCheckRequest
      { requestId :: String
      , timestamp :: Number
      , tweetIds :: Array String
      }
  | CacheCheckResponse
      { requestId :: String
      , timestamp :: Number
      , results :: Object Boolean
      }
  | ConfigChanged
      { requestId :: String
      , timestamp :: Number
      , config :: FullConfig
      }
  | SessionStatusRequest
      { requestId :: String
      , timestamp :: Number
      }
  | SessionStatusResponse
      { requestId :: String
      , timestamp :: Number
      , initialized :: Boolean
      , isMultimodal :: Boolean
      , currentConfig :: Maybe SessionConfig
      }
  | ReinitRequest
      { requestId :: String
      , timestamp :: Number
      , config :: SessionConfig
      }
  | ErrorMessage
      { requestId :: String
      , timestamp :: Number
      , error :: String
      , originalRequestId :: Maybe String
      }

-- | Get the message type string
messageType :: Message -> String
messageType (InitRequest _) = C.initRequest
messageType (InitResponse _) = C.initResponse
messageType (EvaluateRequest _) = C.evaluateRequest
messageType (EvaluateResponse _) = C.evaluateResponse
messageType (CacheCheckRequest _) = C.cacheCheckRequest
messageType (CacheCheckResponse _) = C.cacheCheckResponse
messageType (ConfigChanged _) = C.configChanged
messageType (SessionStatusRequest _) = C.sessionStatusRequest
messageType (SessionStatusResponse _) = C.sessionStatusResponse
messageType (ReinitRequest _) = C.reinitRequest
messageType (ErrorMessage _) = C.errorType

-- | Get requestId from any message
requestId :: Message -> String
requestId (InitRequest r) = r.requestId
requestId (InitResponse r) = r.requestId
requestId (EvaluateRequest r) = r.requestId
requestId (EvaluateResponse r) = r.requestId
requestId (CacheCheckRequest r) = r.requestId
requestId (CacheCheckResponse r) = r.requestId
requestId (ConfigChanged r) = r.requestId
requestId (SessionStatusRequest r) = r.requestId
requestId (SessionStatusResponse r) = r.requestId
requestId (ReinitRequest r) = r.requestId
requestId (ErrorMessage r) = r.requestId

isInitResponseSuccess :: forall r. { success :: Boolean, error :: Maybe String | r } -> Boolean
isInitResponseSuccess response =
  response.success && isNothing response.error

-- | Encode a Message to Foreign for chrome.runtime.sendMessage
encodeMessage :: Message -> Foreign
encodeMessage msg = unsafeToForeign (toObj msg)
  where
  toObj :: Message -> Object Foreign
  toObj (InitRequest r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.initRequest
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , config: unsafeToForeign (Object.fromHomogeneous
        { prompt: unsafeToForeign r.config.prompt
        , outputLanguage: unsafeToForeign (outputLanguageToString r.config.outputLanguage)
        })
    }
  toObj (EvaluateRequest r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.evaluateRequest
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , tweetId: unsafeToForeign r.tweetId
    , textContent: unsafeToForeign r.textContent
    , media: encodeNullableMedia r.media
    , quotedTweet: encodeNullableQuotedTweet r.quotedTweet
    }
  toObj (EvaluateResponse r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.evaluateResponse
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , tweetId: unsafeToForeign r.tweetId
    , shouldShow: unsafeToForeign r.shouldShow
    , cacheHit: unsafeToForeign r.cacheHit
    , evaluationTime: unsafeToForeign r.evaluationTime
    , error: unsafeToForeign (toNullable r.error)
    }
  toObj (ErrorMessage r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.errorType
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , error: unsafeToForeign r.error
    , originalRequestId: unsafeToForeign (toNullable r.originalRequestId)
    }
  toObj (SessionStatusRequest r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.sessionStatusRequest
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    }
  toObj (SessionStatusResponse r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.sessionStatusResponse
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , initialized: unsafeToForeign r.initialized
    , isMultimodal: unsafeToForeign r.isMultimodal
    , currentConfig: encodeNullableConfig r.currentConfig
    }
  toObj (InitResponse r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.initResponse
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , success: unsafeToForeign r.success
    , sessionStatus: unsafeToForeign $ Object.fromHomogeneous
        { isMultimodal: unsafeToForeign r.sessionStatus.isMultimodal
        , sessionType: unsafeToForeign (toNullable (map sessionTypeToString r.sessionStatus.sessionType))
        }
    , error: unsafeToForeign (toNullable r.error)
    }
  toObj (CacheCheckRequest r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.cacheCheckRequest
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , tweetIds: unsafeToForeign r.tweetIds
    }
  toObj (CacheCheckResponse r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.cacheCheckResponse
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , results: unsafeToForeign r.results
    }
  toObj (ConfigChanged r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.configChanged
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , config: unsafeToForeign $ Object.fromHomogeneous
        { enabled: unsafeToForeign r.config.enabled
        , prompt: unsafeToForeign r.config.prompt
        , outputLanguage: unsafeToForeign (outputLanguageToString r.config.outputLanguage)
        }
    }
  toObj (ReinitRequest r) = Object.fromHomogeneous
    { "type": unsafeToForeign C.reinitRequest
    , requestId: unsafeToForeign r.requestId
    , timestamp: unsafeToForeign r.timestamp
    , config: unsafeToForeign (Object.fromHomogeneous
        { prompt: unsafeToForeign r.config.prompt
        , outputLanguage: unsafeToForeign (outputLanguageToString r.config.outputLanguage)
        })
    }
  encodeNullableConfig :: Maybe SessionConfig -> Foreign
  encodeNullableConfig Nothing = unsafeToForeign (toNullable (Nothing :: Maybe Foreign))
  encodeNullableConfig (Just c) = unsafeToForeign $ Object.fromHomogeneous
    { prompt: unsafeToForeign c.prompt
    , outputLanguage: unsafeToForeign (outputLanguageToString c.outputLanguage)
    }

  encodeMediaData :: MediaData -> Foreign
  encodeMediaData media = unsafeToForeign $ Object.fromHomogeneous
    { "type": unsafeToForeign (mediaTypeToString media.mediaType)
    , url: unsafeToForeign media.url
    }

  encodeQuotedTweet :: QuotedTweet -> Foreign
  encodeQuotedTweet qt = unsafeToForeign $ Object.fromHomogeneous
    { textContent: unsafeToForeign qt.textContent
    , author: unsafeToForeign (toNullable qt.author)
    , media: encodeNullableMedia qt.media
    }

  encodeNullableMedia :: Maybe (Array MediaData) -> Foreign
  encodeNullableMedia Nothing = unsafeToForeign (toNullable (Nothing :: Maybe Foreign))
  encodeNullableMedia (Just media) = unsafeToForeign (map encodeMediaData media)

  encodeNullableQuotedTweet :: Maybe QuotedTweet -> Foreign
  encodeNullableQuotedTweet Nothing = unsafeToForeign (toNullable (Nothing :: Maybe Foreign))
  encodeNullableQuotedTweet (Just qt) = encodeQuotedTweet qt

-- | Decode a Foreign value into a Message by dispatching on the "type" field.
-- | Total: validates the top-level shape before any unsafeFromForeign cast.
decodeMessage :: Foreign -> Either String Message
decodeMessage = decodeMessageUnsafe

-- | Require a String field, validated via readString (checks JS tagOf).
requireString :: String -> Object Foreign -> Either String String
requireString key obj = case Object.lookup key obj of
  Nothing -> Left ("Missing required field: '" <> key <> "'")
  Just v -> case runExcept (readString v) of
    Left _ -> Left ("Field '" <> key <> "': expected String, found " <> typeOf v)
    Right s -> Right s

-- | Require a Boolean field, validated via readBoolean.
requireBoolean :: String -> Object Foreign -> Either String Boolean
requireBoolean key obj = case Object.lookup key obj of
  Nothing -> Left ("Missing required field: '" <> key <> "'")
  Just v -> case runExcept (readBoolean v) of
    Left _ -> Left ("Field '" <> key <> "': expected Boolean, found " <> typeOf v)
    Right b -> Right b

-- | Require a Number field, validated via readNumber.
requireNumber :: String -> Object Foreign -> Either String Number
requireNumber key obj = case Object.lookup key obj of
  Nothing -> Left ("Missing required field: '" <> key <> "'")
  Just v -> case runExcept (readNumber v) of
    Left _ -> Left ("Field '" <> key <> "': expected Number, found " <> typeOf v)
    Right n -> Right n

-- | Require an Array field, validated via isArray.
-- | Element types are validated by callers when needed.
requireArray :: forall a. String -> Object Foreign -> Either String (Array a)
requireArray key obj = case Object.lookup key obj of
  Nothing -> Left ("Missing required field: '" <> key <> "'")
  Just v
    | isArray v -> Right (unsafeFromForeign v)
    | otherwise -> Left ("Field '" <> key <> "': expected array, found " <> typeOf v)

requireStringArray :: String -> Object Foreign -> Either String (Array String)
requireStringArray key obj = do
  arr <- requireArray key obj :: Either String (Array Foreign)
  traverse decodeStringValue arr

-- | Require a nested Object field, validated via typeof check.
requireObj :: forall a. String -> Object Foreign -> Either String (Object a)
requireObj key obj = case Object.lookup key obj of
  Nothing -> Left ("Missing required field: '" <> key <> "'")
  Just v
    | typeOf v == "object" && not (isArray v) && not (isNull v) -> Right (unsafeFromForeign v)
    | otherwise -> Left ("Field '" <> key <> "': expected object, found " <> typeOf v)

requireBooleanObject :: String -> Object Foreign -> Either String (Object Boolean)
requireBooleanObject key obj = do
  rawObj <- requireObj key obj :: Either String (Object Foreign)
  foldM insertDecoded Object.empty (Object.toUnfoldable rawObj :: Array (Tuple String Foreign))
  where
  insertDecoded acc (Tuple prop value) = do
    decoded <- decodeBooleanValue value
    Right (Object.insert prop decoded acc)

-- | Optional nullable field with shape validation, composable in Either monad.
-- | Returns Right Nothing for absent/null/undefined.
-- | Validates shape with guard before decode; provides field context on mismatch.
optionalNullable :: forall a. String -> (Foreign -> Boolean) -> (Foreign -> Either String a) -> Object Foreign -> Either String (Maybe a)
optionalNullable key guard decode obj = case Object.lookup key obj of
  Nothing -> Right Nothing
  Just v
    | isNull v || isUndefined v -> Right Nothing
    | guard v -> map Just (decode v)
    | otherwise -> Left ("Field '" <> key <> "': unexpected type " <> typeOf v)

-- | Optional nullable String field. Fully total — no unsafeFromForeign.
optionalNullableString :: String -> Object Foreign -> Either String (Maybe String)
optionalNullableString key obj = case Object.lookup key obj of
  Nothing -> Right Nothing
  Just v
    | isNull v || isUndefined v -> Right Nothing
    | otherwise -> case runExcept (readString v) of
        Left _ -> Left ("Field '" <> key <> "': expected String, found " <> typeOf v)
        Right s -> Right (Just s)

decodeStringValue :: Foreign -> Either String String
decodeStringValue v = case runExcept (readString v) of
  Left _ -> Left ("expected String, found " <> typeOf v)
  Right s -> Right s

decodeBooleanValue :: Foreign -> Either String Boolean
decodeBooleanValue v = case runExcept (readBoolean v) of
  Left _ -> Left ("expected Boolean, found " <> typeOf v)
  Right b -> Right b

decodeOutputLanguageStrict :: String -> Either String OutputLanguage
decodeOutputLanguageStrict = parseOutputLanguage

decodeSessionTypeStrict :: String -> Either String SessionType
decodeSessionTypeStrict raw = case sessionTypeFromString raw of
  Just sessionType -> Right sessionType
  Nothing -> Left ("invalid sessionType: " <> raw)

decodeSessionConfigObject :: Object Foreign -> Either String SessionConfig
decodeSessionConfigObject cfgObj = do
  prompt <- requireString "prompt" cfgObj
  langRaw <- requireString "outputLanguage" cfgObj
  outputLanguage <- decodeOutputLanguageStrict langRaw
  Right { prompt, outputLanguage }

decodeSessionConfigForeign :: Foreign -> Either String SessionConfig
decodeSessionConfigForeign raw
  | typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw =
      Left ("Expected SessionConfig object, found " <> typeOf raw)
  | otherwise =
      decodeSessionConfigObject ((unsafeFromForeign raw) :: Object Foreign)

decodeMediaData :: Foreign -> Either String MediaData
decodeMediaData raw =
  if typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw then
    Left ("Expected MediaData object, found " <> typeOf raw)
  else do
    let obj = (unsafeFromForeign raw) :: Object Foreign
    mediaType <- decodeMediaType obj
    url <- requireString "url" obj
    Right { mediaType, url }

decodeMediaType :: Object Foreign -> Either String MediaType
decodeMediaType obj = do
  mediaTypeValue <- requireString "type" obj
  case parseMediaType mediaTypeValue of
    Just mediaType -> Right mediaType
    Nothing -> Left ("Unsupported media type: " <> mediaTypeValue)

decodeMediaArray :: Foreign -> Either String (Array MediaData)
decodeMediaArray raw =
  if not (isArray raw) then
    Left ("Expected media array, found " <> typeOf raw)
  else
    traverse decodeMediaData ((unsafeFromForeign raw) :: Array Foreign)

decodeQuotedTweet :: Foreign -> Either String QuotedTweet
decodeQuotedTweet raw =
  if typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw then
    Left ("Expected quotedTweet object, found " <> typeOf raw)
  else do
    let obj = (unsafeFromForeign raw) :: Object Foreign
    textContent <- requireString "textContent" obj
    author <- optionalNullableString "author" obj
    media <- optionalNullable "media" isArray decodeMediaArray obj
    Right { textContent, author, media }

-- | Internal decoder. Total: validates that raw is a non-null object before casting.
-- | All subsequent unsafeFromForeign calls are guarded by shape checks (isArray, typeOf).
decodeMessageUnsafe :: Foreign -> Either String Message
decodeMessageUnsafe raw =
  if typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw then
    Left "Expected message to be a non-null object"
  else
    let obj = (unsafeFromForeign raw) :: Object Foreign
    in do -- Either monad
      t <- requireString "type" obj
      reqId <- requireString "requestId" obj
      ts <- requireNumber "timestamp" obj
      decodeByType obj t reqId ts

-- | Dispatch decoding by message type string.
decodeByType :: Object Foreign -> String -> String -> Number -> Either String Message
decodeByType obj t reqId ts
  | t == C.initRequest = do
      configObj <- requireObj "config" obj
      config <- decodeSessionConfigObject configObj
      Right $ InitRequest { requestId: reqId, timestamp: ts, config }

  | t == C.initResponse = do
      success <- requireBoolean "success" obj
      statusObj <- requireObj "sessionStatus" obj
      isMulti <- requireBoolean "isMultimodal" statusObj
      sessTypeStr <- optionalNullableString "sessionType" statusObj
      sessType <- traverse decodeSessionTypeStrict sessTypeStr
      err <- optionalNullableString "error" obj
      Right $ InitResponse
        { requestId: reqId, timestamp: ts, success
        , sessionStatus: { isMultimodal: isMulti, sessionType: sessType }
        , error: err
        }

  | t == C.evaluateRequest = do
      tweetId <- requireString "tweetId" obj
      textContent <- requireString "textContent" obj
      media <- optionalNullable "media" isArray decodeMediaArray obj
      quotedTweet <- optionalNullable "quotedTweet" (\v -> typeOf v == "object" && not (isArray v) && not (isNull v)) decodeQuotedTweet obj
      Right $ EvaluateRequest
        { requestId: reqId, timestamp: ts, tweetId, textContent, media, quotedTweet }

  | t == C.evaluateResponse = do
      tweetId <- requireString "tweetId" obj
      shouldShow <- requireBoolean "shouldShow" obj
      cacheHit <- requireBoolean "cacheHit" obj
      evaluationTime <- requireNumber "evaluationTime" obj
      err <- optionalNullableString "error" obj
      Right $ EvaluateResponse
        { requestId: reqId, timestamp: ts, tweetId, shouldShow, cacheHit, evaluationTime, error: err }

  | t == C.cacheCheckRequest = do
      tweetIds <- requireStringArray "tweetIds" obj
      Right $ CacheCheckRequest { requestId: reqId, timestamp: ts, tweetIds }

  | t == C.cacheCheckResponse = do
      results <- requireBooleanObject "results" obj
      Right $ CacheCheckResponse { requestId: reqId, timestamp: ts, results }

  | t == C.configChanged = do
      cfgObj <- requireObj "config" obj
      enabled <- requireBoolean "enabled" cfgObj
      prompt <- requireString "prompt" cfgObj
      langRaw <- requireString "outputLanguage" cfgObj
      lang <- decodeOutputLanguageStrict langRaw
      Right $ ConfigChanged
        { requestId: reqId, timestamp: ts
        , config: { enabled, prompt, outputLanguage: lang }
        }

  | t == C.sessionStatusRequest =
      Right $ SessionStatusRequest { requestId: reqId, timestamp: ts }

  | t == C.sessionStatusResponse = do
      initialized <- requireBoolean "initialized" obj
      isMulti <- requireBoolean "isMultimodal" obj
      config <- optionalNullable "currentConfig" (\v -> typeOf v == "object" && not (isArray v) && not (isNull v)) decodeSessionConfigForeign obj
      Right $ SessionStatusResponse
        { requestId: reqId, timestamp: ts, initialized, isMultimodal: isMulti, currentConfig: config }

  | t == C.reinitRequest = do
      cfgObj <- requireObj "config" obj
      config <- decodeSessionConfigObject cfgObj
      Right $ ReinitRequest { requestId: reqId, timestamp: ts, config }

  | t == C.errorType = do
      err <- requireString "error" obj
      origReqId <- optionalNullableString "originalRequestId" obj
      Right $ ErrorMessage
        { requestId: reqId, timestamp: ts, error: err, originalRequestId: origReqId }

  | otherwise = Left ("Unknown message type: " <> t)
