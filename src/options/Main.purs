module Options.Main where

import Prelude

import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Data.String.CodeUnits as CU
import Data.String.Pattern (Pattern(..))
import Data.Traversable (for, for_)
import Effect (Effect)
import Effect.Aff (Aff, bracket, error, launchAff_, throwError, try)
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.GeminiNano as Gemini
import FFI.WebApi as WebApi
import FFI.WebApi (Element)
import Foreign (Foreign)
import Shared.EffectUtils as EffectUtils
import Shared.GeminiModelOptions as ModelOpts
import Shared.GeminiAvailability (Availability(..))
import Shared.GeminiAvailability as Availability
import Shared.Storage as Storage
import Shared.Types.Storage (FilterConfig, SessionType(..), defaultFilterConfig, normalizePrompt, outputLanguageToString, sessionTypeToString)
import Shared.Types.Storage as StorageTypes

-- | DOM element references
type Elements =
  { enabled :: Element
  , prompt :: Element
  , showStats :: Element
  , outputLanguage :: Element
  , saveBtn :: Element
  , resetBtn :: Element
  , initGeminiBtn :: Element
  , saveStatus :: Element
  , textAvailability :: Element
  , multimodalAvailability :: Element
  , createSessionStatus :: Element
  }

type RuntimeRefs =
  { pollingRef :: Ref (Maybe Int)
  , statusTimerRef :: Ref (Maybe Int)
  , listenersCleanupRef :: Ref (Effect Unit)
  , beforeUnloadCleanupRef :: Ref (Effect Unit)
  }

data InitButtonState
  = ButtonModelReady
  | ButtonDownloadModel
  | ButtonDownloading
  | ButtonNotAvailable
  | ButtonUnknown

type InitButtonView =
  { disabled :: Boolean
  , label :: String
  }

data StatusType
  = StatusSuccess
  | StatusError

data StatusLifetime
  = AutoClear
  | Persistent

type ModelAvailability =
  { text :: Availability
  , multimodal :: Availability
  }

data SessionCreationPlan
  = CreateMultimodal
  | CreateTextOnly
  | CannotCreateSession

derive instance eqSessionCreationPlan :: Eq SessionCreationPlan

main :: Effect Unit
main = do
  mElements <- getElements
  case mElements of
    Nothing -> Console.error "[Options] Failed to get page elements"
    Just elements -> do
      pollingRef <- Ref.new Nothing
      statusTimerRef <- Ref.new Nothing
      listenersCleanupRef <- Ref.new (pure unit :: Effect Unit)
      beforeUnloadCleanupRef <- Ref.new (pure unit :: Effect Unit)
      let runtime = { pollingRef, statusTimerRef, listenersCleanupRef, beforeUnloadCleanupRef }
      launchAff_ $ initialize elements runtime

-- | Get all required DOM elements
getElements :: Effect (Maybe Elements)
getElements = do
  mEnabled <- getById "enabled"
  mPrompt <- getById "prompt"
  mShowStats <- getById "show-stats"
  mOutputLang <- getById "output-language"
  mSaveBtn <- getById "save-btn"
  mResetBtn <- getById "reset-btn"
  mInitBtn <- getById "init-gemini-btn"
  mStatus <- getById "save-status"
  mTextAvail <- getById "text-availability"
  mMultiAvail <- getById "multimodal-availability"
  mCreateStatus <- getById "create-session-status"
  pure do
    enabled <- mEnabled
    prompt <- mPrompt
    showStats <- mShowStats
    outputLanguage <- mOutputLang
    saveBtn <- mSaveBtn
    resetBtn <- mResetBtn
    initGeminiBtn <- mInitBtn
    saveStatus <- mStatus
    textAvailability <- mTextAvail
    multimodalAvailability <- mMultiAvail
    createSessionStatus <- mCreateStatus
    pure
      { enabled
      , prompt
      , showStats
      , outputLanguage
      , saveBtn
      , resetBtn
      , initGeminiBtn
      , saveStatus
      , textAvailability
      , multimodalAvailability
      , createSessionStatus
      }

getById :: String -> Effect (Maybe Element)
getById id = do
  el <- WebApi.documentQuerySelector ("#" <> id)
  pure (toMaybe el)

-- | Initialize the options page
initialize :: Elements -> RuntimeRefs -> Aff Unit
initialize els runtime = do
  liftEffect do
    EffectUtils.runCleanupRef runtime.listenersCleanupRef
    EffectUtils.runCleanupRef runtime.beforeUnloadCleanupRef
  loadConfig els
  checkApiStatus els
  listenersCleanup <- liftEffect $ setupEventListeners els runtime
  liftEffect $ Ref.write listenersCleanup runtime.listenersCleanupRef
  liftEffect $ startStatusPolling els runtime
  beforeUnloadCleanup <- liftEffect $ WebApi.addBeforeUnloadListener do
    stopStatusPolling runtime
    clearStatusTimeout runtime
    EffectUtils.runCleanupRef runtime.listenersCleanupRef
    EffectUtils.runCleanupRef runtime.beforeUnloadCleanupRef
  liftEffect $ Ref.write beforeUnloadCleanup runtime.beforeUnloadCleanupRef
  pure unit

-- | Load saved config into the form
loadConfig :: Elements -> Aff Unit
loadConfig els = do
  config <- Storage.getFilterConfig
  liftEffect do
    WebApi.setChecked els.enabled config.enabled
    WebApi.setValue els.prompt config.prompt
    WebApi.setChecked els.showStats config.showStatistics
    WebApi.setValue els.outputLanguage (outputLanguageToString config.outputLanguage)

-- | Check Gemini Nano API availability
checkApiStatus :: Elements -> Aff Unit
checkApiStatus els = do
  config <- Storage.getFilterConfig
  let lang = outputLanguageToString config.outputLanguage
  availability <- loadModelAvailability lang

  liftEffect do
    WebApi.setTextContent els.textAvailability
      ("LanguageModel.availability(text): " <> renderAvailability availability.text)
    WebApi.setTextContent els.multimodalAvailability
      ("LanguageModel.availability(multimodal): " <> renderAvailability availability.multimodal)

    applyInitButtonState els (decideInitButtonState availability.text availability.multimodal)
    updateCreateSessionStatus els config availability

loadModelAvailability :: String -> Aff ModelAvailability
loadModelAvailability lang = do
  apiAvailable <- liftEffect Gemini.isLanguageModelAvailable
  textAvail <- checkAvailabilityFor apiAvailable ModelOpts.modelInputsText lang
  multimodalAvail <- checkAvailabilityFor apiAvailable ModelOpts.modelInputsMultimodal lang
  pure { text: textAvail, multimodal: multimodalAvail }

-- | Check availability for given input types
checkAvailabilityFor :: Boolean -> Array ModelOpts.ModelInput -> String -> Aff Availability
checkAvailabilityFor apiAvailable inputTypes lang =
  if not apiAvailable then
    pure Unavailable
  else do
    let opts = ModelOpts.makeAvailabilityOptions inputTypes lang
    result <- try $ Gemini.checkAvailability opts
    case result of
      Right r -> pure (Availability.parseAvailability r)
      Left _ -> pure Unavailable

-- | Set up button event listeners
setupEventListeners :: Elements -> RuntimeRefs -> Effect (Effect Unit)
setupEventListeners els runtime = do
  saveCleanup <- WebApi.addClickListener els.saveBtn \_ -> runAffLogged "[Options] save failed" (save els runtime)
  resetCleanup <- WebApi.addClickListener els.resetBtn \_ -> runAffLogged "[Options] reset failed" (reset els runtime)
  initCleanup <- WebApi.addClickListener els.initGeminiBtn \_ -> runAffLogged "[Options] initializeGemini failed" (initializeGemini els runtime)

  -- Set up copy buttons
  copyBtns <- WebApi.documentQuerySelectorAll ".copy-btn"
  copyCleanups <- for copyBtns \btn ->
    WebApi.addClickListener btn \_ -> launchAff_ do
      mUrl <- liftEffect $ WebApi.getAttribute btn "data-url"
      case toMaybe mUrl of
        Nothing -> pure unit
        Just url -> do
          result <- try $ WebApi.clipboardWriteText url
          case result of
            Right _ -> liftEffect do
              WebApi.addClass btn "copied"
              void $ WebApi.setTimeout 1000 (WebApi.removeClass btn "copied")
            Left _ -> liftEffect $ Console.error "[Tweet Filter] Failed to copy to clipboard"
  pure do
    saveCleanup
    resetCleanup
    initCleanup
    for_ copyCleanups identity

-- | Start polling API status every 5 seconds
startStatusPolling :: Elements -> RuntimeRefs -> Effect Unit
startStatusPolling els runtime = do
  stopStatusPolling runtime
  intervalId <- WebApi.setInterval 5000 do
    launchAff_ (checkApiStatus els)
  Ref.write (Just intervalId) runtime.pollingRef

-- | Stop status polling
stopStatusPolling :: RuntimeRefs -> Effect Unit
stopStatusPolling runtime =
  EffectUtils.clearMaybeRef runtime.pollingRef WebApi.clearInterval

-- | Save settings
save :: Elements -> RuntimeRefs -> Aff Unit
save els runtime = do
  result <- persistFormConfig els
  liftEffect $ case result of
    Right _ ->
      showStatus els runtime "Settings saved successfully!" StatusSuccess AutoClear
    Left err -> do
      showStatus els runtime ("Failed to save settings: " <> err) StatusError AutoClear
      Console.error ("[Tweet Filter] Failed to save settings: " <> err)

-- | Reset settings to defaults
reset :: Elements -> RuntimeRefs -> Aff Unit
reset els runtime = do
  liftEffect do
    WebApi.setChecked els.enabled defaultFilterConfig.enabled
    WebApi.setValue els.prompt defaultFilterConfig.prompt
    WebApi.setChecked els.showStats defaultFilterConfig.showStatistics
    WebApi.setValue els.outputLanguage (outputLanguageToString defaultFilterConfig.outputLanguage)
  result <- persistFormConfig els
  liftEffect $ case result of
    Right _ ->
      showStatus els runtime "Settings reset to default!" StatusSuccess AutoClear
    Left err -> do
      showStatus els runtime ("Failed to reset settings: " <> err) StatusError AutoClear
      Console.error ("[Tweet Filter] Failed to reset settings: " <> err)

-- | Initialize Gemini Nano (download model)
initializeGemini :: Elements -> RuntimeRefs -> Aff Unit
initializeGemini els runtime = do
  config <- Storage.getFilterConfig
  if normalizePrompt config.prompt == "" then
    liftEffect $ showStatus els runtime "Please enter filter criteria before creating session" StatusError AutoClear
  else do
    liftEffect do
      WebApi.setDisabled els.initGeminiBtn true
      WebApi.setTextContent els.initGeminiBtn "Creating..."
      showStatus els runtime "Creating session..." StatusSuccess Persistent

    let lang = outputLanguageToString config.outputLanguage
    result <- try $ createSessionFull els runtime lang
    case result of
      Right sessionType -> do
        liftEffect $ showStatus els runtime "Session created successfully!" StatusSuccess AutoClear
        checkApiStatus els
        liftEffect $ showCreateSessionStatus els (Just sessionType)
      Left err -> do
        liftEffect do
          showStatus els runtime (show err) StatusError AutoClear
          showCreateSessionStatus els Nothing
          Console.error ("[Tweet Filter] Failed to create session: " <> show err)
        checkApiStatus els

-- | Try to create a Gemini session (multimodal first, then text-only fallback)
createSessionFull :: Elements -> RuntimeRefs -> String -> Aff SessionType
createSessionFull els runtime lang = do
  availability <- loadModelAvailability lang
  case planSessionCreation availability.multimodal availability.text of
    CreateMultimodal -> do
      let opts = ModelOpts.makeCreateOptions ModelOpts.modelInputsMultimodal lang
      withTemporarySession opts (onProgress els runtime)
      pure Multimodal
    CreateTextOnly -> do
      let opts = ModelOpts.makeCreateOptions ModelOpts.modelInputsText lang
      withTemporarySession opts (onProgress els runtime)
      pure TextOnly
    CannotCreateSession ->
      throwError (error (sessionCreationErrorMessage availability.multimodal availability.text))

-- | Download progress callback
onProgress :: Elements -> RuntimeRefs -> Number -> Effect Unit
onProgress els runtime progress = do
  showStatus els runtime ("Downloading model: " <> formatProgress progress <> "%") StatusSuccess Persistent
  WebApi.setTextContent els.initGeminiBtn ("Downloading " <> formatProgressInt progress <> "%")

updateCreateSessionStatus :: Elements -> FilterConfig -> ModelAvailability -> Effect Unit
updateCreateSessionStatus els config availability =
  if normalizePrompt config.prompt == "" then
    showCreateSessionStatus els Nothing
  else
    showCreateSessionStatus els (sessionTypeFromAvailableApis availability.multimodal availability.text)

renderAvailability :: Availability -> String
renderAvailability Available = "available"
renderAvailability Downloadable = "downloadable"
renderAvailability AfterDownload = "after-download"
renderAvailability Downloading = "downloading"
renderAvailability Unavailable = "unavailable"
renderAvailability (Unknown s) = s

-- | Read form values into a config record
readFormConfig :: Elements -> Effect (Either String FilterConfig)
readFormConfig els = do
  enabled <- WebApi.getChecked els.enabled
  promptRaw <- WebApi.getValue els.prompt
  showStats <- WebApi.getChecked els.showStats
  langStr <- WebApi.getValue els.outputLanguage
  let prompt = normalizePrompt promptRaw
  pure $ map
    (\lang ->
      { enabled
      , prompt
      , showStatistics: showStats
      , outputLanguage: lang
      }
    )
    (StorageTypes.parseOutputLanguage langStr)

persistFormConfig :: Elements -> Aff (Either String Unit)
persistFormConfig els = do
  configResult <- liftEffect $ readFormConfig els
  case configResult of
    Left err -> pure (Left err)
    Right config ->
      map (\writeResult -> case writeResult of
        Left err -> Left (show err)
        Right _ -> Right unit
      ) (try (Storage.setFilterConfig config))

-- | Show a status message with a CSS class
showStatus :: Elements -> RuntimeRefs -> String -> StatusType -> StatusLifetime -> Effect Unit
showStatus els runtime message statusType lifetime = do
  clearStatusTimeout runtime
  WebApi.setTextContent els.saveStatus message
  WebApi.setClassName els.saveStatus ("save-status " <> statusTypeToClass statusType)
  case lifetime of
    Persistent -> pure unit
    AutoClear -> do
      timeoutId <- WebApi.setTimeout 3000 do
        WebApi.setTextContent els.saveStatus ""
        WebApi.setClassName els.saveStatus "save-status"
        Ref.write Nothing runtime.statusTimerRef
      Ref.write (Just timeoutId) runtime.statusTimerRef

-- | Show create session status
showCreateSessionStatus :: Elements -> Maybe SessionType -> Effect Unit
showCreateSessionStatus els mResult = do
  let text = case mResult of
        Just r -> "LanguageModel.create: " <> sessionTypeToString r
        Nothing -> "LanguageModel.create: null"
  WebApi.setTextContent els.createSessionStatus text

-- Format helpers
formatProgress :: Number -> String
formatProgress n =
  let scaled = Int.toNumber (Int.round (n * 10.0)) / 10.0
      s = show scaled
  in
    if CU.indexOf (Pattern ".") s == Nothing then s <> ".0" else s

formatProgressInt :: Number -> String
formatProgressInt = show <<< Int.round

decideInitButtonState :: Availability -> Availability -> InitButtonState
decideInitButtonState textAvail multiAvail
  | Availability.isAvailable textAvail || Availability.isAvailable multiAvail = ButtonModelReady
  | Availability.isDownloadPossible textAvail || Availability.isDownloadPossible multiAvail = ButtonDownloadModel
  | textAvail == Downloading || multiAvail == Downloading = ButtonDownloading
  | textAvail == Unavailable && multiAvail == Unavailable = ButtonNotAvailable
  | otherwise = ButtonUnknown

applyInitButtonState :: Elements -> InitButtonState -> Effect Unit
applyInitButtonState els state = do
  let view = initButtonView state
  WebApi.setDisabled els.initGeminiBtn view.disabled
  WebApi.setTextContent els.initGeminiBtn view.label

initButtonView :: InitButtonState -> InitButtonView
initButtonView ButtonModelReady = { disabled: true, label: "Model Ready" }
initButtonView ButtonDownloadModel = { disabled: false, label: "Download Model" }
initButtonView ButtonDownloading = { disabled: true, label: "Downloading..." }
initButtonView ButtonNotAvailable = { disabled: true, label: "Not Available" }
initButtonView ButtonUnknown = { disabled: true, label: "Unknown Status" }

clearStatusTimeout :: RuntimeRefs -> Effect Unit
clearStatusTimeout runtime =
  EffectUtils.clearMaybeRef runtime.statusTimerRef WebApi.clearTimeout

withTemporarySession
  :: Foreign
  -> (Number -> Effect Unit)
  -> Aff Unit
withTemporarySession opts progressCallback =
  bracket
    (Gemini.createSessionWithMonitor opts progressCallback)
    (\session -> void $ try (Gemini.destroySession session))
    (\_ -> pure unit)

runAffLogged :: String -> Aff Unit -> Effect Unit
runAffLogged label action = launchAff_ do
  result <- try action
  case result of
    Left err -> liftEffect $ Console.error (label <> ": " <> show err)
    Right _ -> pure unit

statusTypeToClass :: StatusType -> String
statusTypeToClass StatusSuccess = "success"
statusTypeToClass StatusError = "error"

sessionTypeFromAvailableApis :: Availability -> Availability -> Maybe SessionType
sessionTypeFromAvailableApis multiAvail textAvail
  | Availability.isAvailable multiAvail = Just Multimodal
  | Availability.isAvailable textAvail = Just TextOnly
  | otherwise = Nothing

planSessionCreation :: Availability -> Availability -> SessionCreationPlan
planSessionCreation multiAvail textAvail
  | isSessionCreatable multiAvail = CreateMultimodal
  | isSessionCreatable textAvail = CreateTextOnly
  | otherwise = CannotCreateSession

isSessionCreatable :: Availability -> Boolean
isSessionCreatable avail =
  Availability.isAvailable avail || Availability.isDownloadPossible avail

sessionCreationErrorMessage :: Availability -> Availability -> String
sessionCreationErrorMessage multiAvail textAvail =
  "No creatable model. multimodal=" <> renderAvailability multiAvail
    <> ", text=" <> renderAvailability textAvail
