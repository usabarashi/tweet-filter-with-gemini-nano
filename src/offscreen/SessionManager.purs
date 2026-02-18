module Offscreen.SessionManager where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Nullable (toNullable)
import Data.Traversable (for_)
import Effect (Effect)
import Effect.AVar as EAVar
import Effect.Aff (Aff, bracket, error, throwError, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.GeminiNano as GeminiNano
import Foreign (Foreign)
import Shared.GeminiModelOptions as ModelOpts
import Shared.GeminiAvailability as Availability
import Shared.Logger as Logger
import Shared.Types.Storage (OutputLanguage, SessionType(..), normalizePrompt, outputLanguageToString)

type SessionConfig =
  { prompt :: String
  , outputLanguage :: OutputLanguage
  }

type SessionState =
  { runtime :: SessionRuntime
  , initLock :: AVar Unit     -- mutex: serializes concurrent initialize calls
  , logger :: Ref Logger.LoggerState
  }

data InitializeError
  = TextModelUnavailable
  | TextSessionCreateFailed

data InitializeResult
  = InitializeSucceeded SessionType
  | InitializeFailed InitializeError

data SessionRuntime
  = Uninitialized
  | Initialized
      { baseSession :: GeminiNano.LanguageModelSession
      , currentConfig :: SessionConfig
      , sessionType :: SessionType
      }

-- | Create a new session manager
new :: Ref Logger.LoggerState -> Effect (Ref SessionState)
new loggerRef = do
  lock <- EAVar.new unit
  Ref.new
    { runtime: Uninitialized
    , initLock: lock
    , logger: loggerRef
    }

-- | Initialize session with config.
-- | Uses a mutex to serialize concurrent initialization requests.
initialize :: Ref SessionState -> SessionConfig -> Aff InitializeResult
initialize stateRef config = do
  let normalized = config { prompt = normalizePrompt config.prompt }
  withInitLock stateRef (initializeImpl stateRef normalized)

-- | Internal initialization logic (called under lock)
initializeImpl :: Ref SessionState -> SessionConfig -> Aff InitializeResult
initializeImpl stateRef config = do
  state <- liftEffect $ Ref.read stateRef
  case reusableSessionType state config of
    Just sessionType ->
      pure (InitializeSucceeded sessionType)
    Nothing -> do
      let previous = getBaseSession state.runtime
      initialized <- doInitialize stateRef config
      when (isInitializeSuccess initialized) $
        for_ previous (destroyStandaloneSession state.logger)
      pure initialized

-- | Internal initialization logic.
-- | Config is only committed to state after a session is successfully created.
doInitialize :: Ref SessionState -> SessionConfig -> Aff InitializeResult
doInitialize stateRef config = do
  state <- liftEffect $ Ref.read stateRef
  let langStr = outputLanguageToString config.outputLanguage
  multiAvail <- checkAvailabilitySafe (ModelOpts.makeAvailabilityOptions ModelOpts.modelInputsMultimodal langStr)
  if canInitializeMultimodal multiAvail then
    initMultimodal stateRef state.logger config langStr
  else
    initTextOnly stateRef config

initMultimodal :: Ref SessionState -> Ref Logger.LoggerState -> SessionConfig -> String -> Aff InitializeResult
initMultimodal stateRef loggerRef config langStr = do
  result <- try (GeminiNano.createSession (ModelOpts.makeCreateOptions ModelOpts.modelInputsMultimodal langStr))
  case result of
    Right session -> do
      liftEffect $ commitSession stateRef session config Multimodal
      liftEffect $ Logger.log loggerRef "[SessionManager] Initialized with multimodal support"
      pure (InitializeSucceeded Multimodal)
    Left _ -> do
      liftEffect $ Logger.warn loggerRef "[SessionManager] Multimodal init failed, falling back to text-only"
      initTextOnly stateRef config

-- | Initialize text-only session.
-- | Config is only committed to state on success.
initTextOnly :: Ref SessionState -> SessionConfig -> Aff InitializeResult
initTextOnly stateRef config = do
  state <- liftEffect $ Ref.read stateRef
  let langStr = outputLanguageToString config.outputLanguage
  textAvail <- checkAvailabilitySafe (ModelOpts.makeAvailabilityOptions ModelOpts.modelInputsText langStr)
  case textAvail of
    avail | Availability.isUnavailableOrDownloading avail -> do
      liftEffect $ Logger.logError state.logger "[SessionManager] Text-only unavailable"
      pure (InitializeFailed TextModelUnavailable)
    _ -> do
      result <- try (GeminiNano.createSession (ModelOpts.makeCreateOptions ModelOpts.modelInputsText langStr))
      case result of
        Right session -> do
          liftEffect $ commitSession stateRef session config TextOnly
          liftEffect $ Logger.log state.logger "[SessionManager] Initialized with text-only support"
          pure (InitializeSucceeded TextOnly)
        Left _ -> do
          liftEffect $ Logger.logError state.logger "[SessionManager] Failed to create text-only session"
          pure (InitializeFailed TextSessionCreateFailed)

-- | Create a cloned session for evaluation.
-- | Atomic: holds initLock to prevent destroy from racing.
createClonedSession :: Ref SessionState -> Aff GeminiNano.LanguageModelSession
createClonedSession stateRef =
  withInitLock stateRef do
    st <- liftEffect $ Ref.read stateRef
    case st.runtime of
      Uninitialized -> throwError (error "Base session not initialized")
      Initialized runtime -> GeminiNano.cloneSession runtime.baseSession (toNullable Nothing)

-- | Destroy the current session (acquires initLock).
destroy :: Ref SessionState -> Aff Unit
destroy stateRef = withInitLock stateRef (destroyImpl stateRef)

-- | Internal: destroy session. Caller must hold initLock.
destroyImpl :: Ref SessionState -> Aff Unit
destroyImpl stateRef = do
  state <- liftEffect $ Ref.read stateRef
  case state.runtime of
    Uninitialized -> pure unit
    Initialized runtime -> do
      _ <- try $ GeminiNano.destroySession runtime.baseSession
      liftEffect $ Ref.modify_ (_ { runtime = Uninitialized }) stateRef
      liftEffect $ Logger.log state.logger "[SessionManager] Base session destroyed"

-- | Check if session is initialized
isInitialized :: Ref SessionState -> Effect Boolean
isInitialized stateRef =
  map (isInitializedRuntime <<< _.runtime) (Ref.read stateRef)

-- | Check if multimodal is enabled
isMultimodalEnabled :: Ref SessionState -> Effect Boolean
isMultimodalEnabled stateRef =
  map (sessionTypeSupportsMultimodal <<< getSessionTypeFromRuntime <<< _.runtime) (Ref.read stateRef)

-- | Get session type
getSessionType :: Ref SessionState -> Effect (Maybe SessionType)
getSessionType stateRef =
  map (getSessionTypeFromRuntime <<< _.runtime) (Ref.read stateRef)

-- | Get current config
getCurrentConfig :: Ref SessionState -> Effect (Maybe SessionConfig)
getCurrentConfig stateRef =
  map (getCurrentConfigFromRuntime <<< _.runtime) (Ref.read stateRef)

-- | Get filter criteria prompt if configured
getFilterCriteria :: Ref SessionState -> Effect (Maybe String)
getFilterCriteria stateRef =
  map (map _.prompt <<< getCurrentConfigFromRuntime <<< _.runtime) (Ref.read stateRef)

reusableSessionType :: SessionState -> SessionConfig -> Maybe SessionType
reusableSessionType state config = case state.runtime of
  Initialized runtime | sameConfig runtime.currentConfig config -> Just runtime.sessionType
  _ -> Nothing

sameConfig :: SessionConfig -> SessionConfig -> Boolean
sameConfig left right =
  left.prompt == right.prompt && left.outputLanguage == right.outputLanguage

commitSession
  :: Ref SessionState
  -> GeminiNano.LanguageModelSession
  -> SessionConfig
  -> SessionType
  -> Effect Unit
commitSession stateRef session config sessionType =
  Ref.modify_
    (_
      { runtime = Initialized
          { baseSession: session
          , currentConfig: config
          , sessionType
          }
      }
    )
    stateRef

sessionTypeSupportsMultimodal :: Maybe SessionType -> Boolean
sessionTypeSupportsMultimodal = case _ of
  Just Multimodal -> true
  _ -> false

getBaseSession :: SessionRuntime -> Maybe GeminiNano.LanguageModelSession
getBaseSession runtime = case runtime of
  Uninitialized -> Nothing
  Initialized r -> Just r.baseSession

getSessionTypeFromRuntime :: SessionRuntime -> Maybe SessionType
getSessionTypeFromRuntime runtime = case runtime of
  Uninitialized -> Nothing
  Initialized r -> Just r.sessionType

getCurrentConfigFromRuntime :: SessionRuntime -> Maybe SessionConfig
getCurrentConfigFromRuntime runtime = case runtime of
  Uninitialized -> Nothing
  Initialized r -> Just r.currentConfig

isInitializedRuntime :: SessionRuntime -> Boolean
isInitializedRuntime runtime = case runtime of
  Uninitialized -> false
  Initialized _ -> true

destroyStandaloneSession :: Ref Logger.LoggerState -> GeminiNano.LanguageModelSession -> Aff Unit
destroyStandaloneSession loggerRef session = do
  result <- try $ GeminiNano.destroySession session
  case result of
    Left _ -> liftEffect $ Logger.warn loggerRef "[SessionManager] Failed to destroy previous base session"
    Right _ -> pure unit

checkAvailabilitySafe :: Foreign -> Aff Availability.Availability
checkAvailabilitySafe opts = do
  rawResult <- try $ GeminiNano.checkAvailability opts
  pure case rawResult of
    Right raw -> Availability.parseAvailability raw
    Left _ -> Availability.Unavailable

canInitializeMultimodal :: Availability.Availability -> Boolean
canInitializeMultimodal avail =
  avail == Availability.Available || avail == Availability.AfterDownload

isInitializeSuccess :: InitializeResult -> Boolean
isInitializeSuccess (InitializeSucceeded _) = true
isInitializeSuccess _ = false

initializeErrorMessage :: InitializeResult -> Maybe String
initializeErrorMessage (InitializeSucceeded _) = Nothing
initializeErrorMessage (InitializeFailed TextModelUnavailable) =
  Just "Text model is unavailable or downloading"
initializeErrorMessage (InitializeFailed TextSessionCreateFailed) =
  Just "Failed to create text-only session"

withInitLock :: forall a. Ref SessionState -> Aff a -> Aff a
withInitLock stateRef action = do
  state <- liftEffect $ Ref.read stateRef
  bracket
    (AVar.take state.initLock)
    (\_ -> void $ try $ AVar.put unit state.initLock)
    (\_ -> action)
