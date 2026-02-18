module Shared.Messaging.Client where

import Prelude

import Control.Alt ((<|>))
import Control.Parallel (sequential, parallel)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Aff (Aff, delay, error, throwError)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import FFI.Chrome.Runtime as Runtime
import FFI.WebApi as WebApi
import Foreign (Foreign, isNull, isUndefined)
import Shared.Messaging.Constants as C
import Shared.Messaging.Types (Message(..), decodeMessage, encodeMessage)
import Shared.Types.Storage (OutputLanguage)
import Data.Int (toNumber)
import Shared.Types.Tweet (MediaData, QuotedTweet)

-- | Send a message to the service worker with a timeout.
-- | Throws on timeout, extension context invalidation, error response, or null response.
-- | Uses ParAff Alt (<|>) to race message against timeout; the loser is cancelled.
sendMessage :: Foreign -> Int -> Aff Foreign
sendMessage msg timeoutMs = do
  valid <- liftEffect Runtime.isContextValid
  unless valid $ throwError (error "Extension context invalidated")
  resp <- sequential (parallel (Runtime.sendMessage msg) <|> parallel timeoutAff)
  -- Reject null/undefined responses (no listener handled the message)
  unless (isPresentForeign resp) $ throwError (error "No response received")
  -- Validate response shape and check protocol-level errors.
  let mErr = checkErrorResponse resp
  case mErr of
    Left decodeErr -> throwError (error ("Malformed service worker response: " <> decodeErr))
    Right (Just errMsg) -> throwError (error errMsg)
    Right Nothing -> pure resp
  where
  timeoutAff = do
    delay (Aff.Milliseconds (toNumber timeoutMs))
    throwError (error "Request timeout")

-- | Safely check if a response is an error message.
-- | Returns Just errorMessage if it is, Nothing otherwise.
checkErrorResponse :: Foreign -> Either String (Maybe String)
checkErrorResponse resp =
  case decodeMessage resp of
    Left err -> Left err
    Right (ErrorMessage r) -> Right (Just r.error)
    Right _ -> Right Nothing

-- | Initialize Gemini Nano session
initialize :: String -> OutputLanguage -> Aff Foreign
initialize prompt outputLang = do
  reqId <- liftEffect WebApi.randomUUID
  ts <- liftEffect WebApi.dateNow
  let msg = encodeMessage $ InitRequest
        { requestId: reqId
        , timestamp: ts
        , config: { prompt, outputLanguage: outputLang }
        }
  sendMessage msg C.timeoutInitRequest

-- | Request tweet evaluation
evaluateTweet
  :: { tweetId :: String
     , textContent :: String
     , media :: Maybe (Array MediaData)
     , quotedTweet :: Maybe QuotedTweet
     }
  -> Aff Foreign
evaluateTweet req = do
  reqId <- liftEffect WebApi.randomUUID
  ts <- liftEffect WebApi.dateNow
  let msg = encodeMessage $ EvaluateRequest
        { requestId: reqId
        , timestamp: ts
        , tweetId: req.tweetId
        , textContent: req.textContent
        , media: req.media
        , quotedTweet: req.quotedTweet
        }
  sendMessage msg C.timeoutEvaluateRequest

-- | Get session status
getSessionStatus :: Aff Foreign
getSessionStatus = do
  reqId <- liftEffect WebApi.randomUUID
  ts <- liftEffect WebApi.dateNow
  let msg = encodeMessage $ SessionStatusRequest
        { requestId: reqId
        , timestamp: ts
        }
  sendMessage msg C.timeoutSessionStatusRequest

isPresentForeign :: Foreign -> Boolean
isPresentForeign x = not (isNull x || isUndefined x)
