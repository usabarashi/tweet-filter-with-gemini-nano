module Shared.Storage where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console as Console
import FFI.Chrome.Storage as ChromeStorage
import Foreign (Foreign, unsafeFromForeign, unsafeToForeign, readBoolean, readString, typeOf, isArray, isNull, isUndefined)
import Foreign.Object as Object
import Shared.Constants (storageKeyFilterConfig)
import Shared.Types.Storage (FilterConfig, OutputLanguage, defaultFilterConfig, normalizeFilterConfig, outputLanguageToString, parseOutputLanguage)

-- | Read filter configuration from chrome.storage.sync
getFilterConfig :: Aff FilterConfig
getFilterConfig = do
  result <- ChromeStorage.syncGet [ storageKeyFilterConfig ]
  case asObject "syncGet result" result of
    Left err -> do
      liftEffect $ Console.warn ("[Storage] Failed to decode syncGet payload: " <> err)
      pure defaultFilterConfig
    Right obj ->
      case Object.lookup storageKeyFilterConfig obj of
        Nothing -> pure defaultFilterConfig
        Just val -> liftEffect $ mergeWithDefaults val

-- | Write filter configuration to chrome.storage.sync
setFilterConfig :: FilterConfig -> Aff Unit
setFilterConfig config = do
  let
    normalized = normalizeFilterConfig config
    encoded = unsafeToForeign $ Object.fromHomogeneous
      { enabled: unsafeToForeign normalized.enabled
      , prompt: unsafeToForeign normalized.prompt
      , showStatistics: unsafeToForeign normalized.showStatistics
      , outputLanguage: unsafeToForeign (outputLanguageToString normalized.outputLanguage)
      }
    data_ = unsafeToForeign $ Object.singleton storageKeyFilterConfig encoded
  ChromeStorage.syncSet data_

-- | Listen for filter config changes
onFilterConfigChange :: (FilterConfig -> Effect Unit) -> Effect (Effect Unit)
onFilterConfigChange callback =
  ChromeStorage.onChanged \changes area -> do
    when (area == "sync") do
      case asObject "storage.onChanged changes" changes of
        Left err ->
          Console.warn ("[Storage] Failed to decode onChanged payload: " <> err)
        Right changesObj ->
          case Object.lookup storageKeyFilterConfig changesObj of
            Nothing -> pure unit
            Just change ->
              case asObject "storage.onChanged change entry" change of
                Left err ->
                  Console.warn ("[Storage] Failed to decode change entry: " <> err)
                Right changeObj ->
                  case Object.lookup "newValue" changeObj of
                    Nothing -> pure unit
                    Just newVal -> do
                      config <- mergeWithDefaults newVal
                      callback config

-- | Merge saved values with defaults.
-- | Gracefully degrades to defaults on any decode error, logging warnings.
-- | Uses Effect.Console directly to avoid circular dependency with Logger.
mergeWithDefaults :: Foreign -> Effect FilterConfig
mergeWithDefaults val = do
  case asObject "filter config object" val of
    Left err -> do
      Console.warn ("[Storage] Failed to decode filter config object: " <> err)
      pure defaultFilterConfig
    Right obj -> do
      enabled <- readOr decodeBoolean "enabled" defaultFilterConfig.enabled obj
      prompt <- readOr decodeString "prompt" defaultFilterConfig.prompt obj
      showStatistics <- readOr decodeBoolean "showStatistics" defaultFilterConfig.showStatistics obj
      outputLanguage <- readOr decodeOutputLanguage "outputLanguage" defaultFilterConfig.outputLanguage obj
      pure $ normalizeFilterConfig { enabled, prompt, showStatistics, outputLanguage }

-- | Generic helper: look up a key, apply a decoder, or return a default.
-- | Total: catches any exception from the decoder, logs a warning, and falls back to the default.
readOr :: forall a. (Foreign -> Either String a) -> String -> a -> Object.Object Foreign -> Effect a
readOr decode key def obj = case Object.lookup key obj of
  Nothing -> pure def
  Just v -> do
    case decode v of
      Left err -> do
        Console.warn ("[Storage] Failed to decode key '" <> key <> "': " <> err)
        pure def
      Right value -> pure value

asObject :: String -> Foreign -> Either String (Object.Object Foreign)
asObject label val
  | typeOf val /= "object" || isArray val || isNull val || isUndefined val = Left (label <> " expected object, found " <> typeOf val)
  | otherwise = Right ((unsafeFromForeign val) :: Object.Object Foreign)

decodeString :: Foreign -> Either String String
decodeString val = case runExcept (readString val) of
  Left _ -> Left ("expected String, found " <> typeOf val)
  Right s -> Right s

decodeBoolean :: Foreign -> Either String Boolean
decodeBoolean val = case runExcept (readBoolean val) of
  Left _ -> Left ("expected Boolean, found " <> typeOf val)
  Right b -> Right b

decodeOutputLanguage :: Foreign -> Either String OutputLanguage
decodeOutputLanguage val = do
  code <- decodeString val
  parseOutputLanguage code
