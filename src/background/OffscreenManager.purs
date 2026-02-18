module Background.OffscreenManager where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (toNumber)
import Effect.Aff (Aff, bracket, delay, error, throwError, try)
import Effect.Aff as Aff
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import FFI.Chrome.Offscreen as ChromeOffscreen
import FFI.Chrome.Runtime as ChromeRuntime
import FFI.WebApi as WebApi
import Foreign (Foreign, unsafeFromForeign, unsafeToForeign, typeOf, isArray, isNull, isUndefined)
import Foreign.Object as Object
import Shared.Logger as Logger
import Shared.Messaging.Constants as C
import Shared.Messaging.Types as Types
import Shared.Storage as Storage
import Shared.Types.Storage (isFilteringActive, normalizeFilterConfig)

-- | Offscreen manager state
type OffscreenState =
  { lock :: AVar Unit   -- mutex: full = idle, empty = creation in progress
  , logger :: Ref Logger.LoggerState
  }

-- | Create a new offscreen manager
new :: Ref Logger.LoggerState -> Aff OffscreenState
new loggerRef = do
  lock <- AVar.new unit
  pure { lock, logger: loggerRef }

-- | Ensure the offscreen document is ready.
-- | Uses an AVar mutex so concurrent callers block until creation completes.
ensureOffscreenReady :: OffscreenState -> Aff Unit
ensureOffscreenReady state =
  bracket
    (AVar.take state.lock)
    (\_ -> AVar.put unit state.lock)
    (\_ -> ensureImpl)
  where
  ensureImpl = do
    contexts <- getOffscreenContexts
    when (Array.null contexts) do
      createResult <- try do
        ChromeOffscreen.createDocument
          { url: C.offscreenDocumentPath
          , reasons: [ C.offscreenReason ]
          , justification: C.offscreenJustification
          }
        liftEffect $ Logger.log state.logger "[OffscreenManager] Offscreen document created"
        success <- initializeOffscreenSession state
        unless success $
          liftEffect $ Logger.warn state.logger "[OffscreenManager] Session initialization failed after retries"
      case createResult of
        Right _ -> pure unit
        Left err -> do
          -- Re-check: if document now exists, a concurrent call created it (benign race)
          contexts' <- getOffscreenContexts
          if Array.null contexts' then do
            -- Document still doesn't exist: real error, surface it
            liftEffect $ Logger.logError state.logger
              ("[OffscreenManager] Failed to create offscreen document: " <> show err)
            throwError err
          else
            liftEffect $ Logger.log state.logger
              "[OffscreenManager] Offscreen document created by concurrent request"

-- | Query Chrome for existing offscreen document contexts
getOffscreenContexts :: Aff (Array Foreign)
getOffscreenContexts = do
  let filter = unsafeToForeign $ Object.fromHomogeneous
        { contextTypes: unsafeToForeign ["OFFSCREEN_DOCUMENT"]
        }
  contexts <- ChromeRuntime.getContexts filter
  if isArray contexts then
    pure ((unsafeFromForeign contexts) :: Array Foreign)
  else
    throwError (error ("Failed to decode runtime contexts: expected array, found " <> typeOf contexts))

-- | Initialize session with current config (with retries).
-- | Returns true on success, false if all retries exhausted.
initializeOffscreenSession :: OffscreenState -> Aff Boolean
initializeOffscreenSession state = do
  config <- normalizeFilterConfig <$> Storage.getFilterConfig
  if not (isFilteringActive config) then
    pure true  -- Initialization not needed; treat as success
  else
    go 1 config
  where
  maxRetries = 3
  go attempt config = do
    liftEffect $ Logger.log state.logger
      ("[OffscreenManager] Initializing offscreen session (attempt " <> show attempt <> "/" <> show maxRetries <> ")")
    when (attempt == 1) $ delay (Aff.Milliseconds 300.0)
    let initMsg = Types.encodeMessage $ Types.InitRequest
          { requestId: ""  -- sendToOffscreenDirect will override
          , timestamp: 0.0
          , config:
              { prompt: config.prompt
              , outputLanguage: config.outputLanguage
              }
          }
    result <- try $ sendToOffscreenDirect state initMsg
    case result of
      Right resp -> do
        let respResult = Types.decodeMessage resp
        case respResult of
          Right (Types.InitResponse r) | Types.isInitResponseSuccess r -> do
            liftEffect $ Logger.log state.logger "[OffscreenManager] Session initialized successfully"
            pure true
          Right (Types.InitResponse _) -> retry attempt config
          _ -> retry attempt config
      Left _ -> retry attempt config

  retry attempt config =
    if attempt < maxRetries then do
      delay (Aff.Milliseconds (500.0 * toNumber attempt))
      go (attempt + 1) config
    else do
      liftEffect $ Logger.logError state.logger "[OffscreenManager] All initialization retries exhausted"
      pure false

-- | Send message to offscreen document, ensuring it is ready first
sendToOffscreen :: OffscreenState -> Foreign -> Aff Foreign
sendToOffscreen state msg = do
  ensureOffscreenReady state
  sendToOffscreenDirect state msg

-- | Send message directly to offscreen document (no readiness check).
-- | Validates that msg is a non-null object before casting.
sendToOffscreenDirect :: OffscreenState -> Foreign -> Aff Foreign
sendToOffscreenDirect _ msg = do
  baseObj <- case asObject "offscreen message payload" msg of
    Left decodeErr -> throwError (error decodeErr)
    Right obj -> pure obj
  reqId <- liftEffect WebApi.randomUUID
  ts <- liftEffect WebApi.dateNow
  let
    fullMsg = unsafeToForeign
      $ Object.insert "requestId" (unsafeToForeign reqId)
      $ Object.insert "timestamp" (unsafeToForeign ts)
      $ baseObj
  ChromeRuntime.sendMessage fullMsg

asObject :: String -> Foreign -> Either String (Object.Object Foreign)
asObject label raw
  | typeOf raw /= "object" || isArray raw || isNull raw || isUndefined raw =
      Left (label <> " expected object, found " <> typeOf raw)
  | otherwise =
      Right ((unsafeFromForeign raw) :: Object.Object Foreign)

-- | Destroy offscreen document
destroy :: OffscreenState -> Aff Unit
destroy state = do
  result <- try ChromeOffscreen.closeDocument
  case result of
    Left _ -> liftEffect $ Logger.log state.logger "[OffscreenManager] Could not close offscreen document"
    Right _ -> liftEffect $ Logger.log state.logger "[OffscreenManager] Offscreen document closed"
