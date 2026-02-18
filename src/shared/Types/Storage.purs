module Shared.Types.Storage where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String.Common (trim, toLower)

data OutputLanguage = En | Es | Ja

derive instance eqOutputLanguage :: Eq OutputLanguage

instance showOutputLanguage :: Show OutputLanguage where
  show = outputLanguageToString

outputLanguageToString :: OutputLanguage -> String
outputLanguageToString En = "en"
outputLanguageToString Es = "es"
outputLanguageToString Ja = "ja"

outputLanguageFromString :: String -> OutputLanguage
outputLanguageFromString str = case parseOutputLanguage str of
  Right lang -> lang
  Left _ -> En

parseOutputLanguage :: String -> Either String OutputLanguage
parseOutputLanguage str = case normalizeToken str of
  "en" -> Right En
  "es" -> Right Es
  "ja" -> Right Ja
  other -> Left ("invalid outputLanguage: " <> other)

-- | Session type ADT instead of stringly-typed Maybe String
data SessionType = Multimodal | TextOnly

derive instance eqSessionType :: Eq SessionType

sessionTypeToString :: SessionType -> String
sessionTypeToString Multimodal = "multimodal"
sessionTypeToString TextOnly = "text-only"

sessionTypeFromString :: String -> Maybe SessionType
sessionTypeFromString str = case normalizeToken str of
  "multimodal" -> Just Multimodal
  "text-only" -> Just TextOnly
  "textonly" -> Just TextOnly
  "text_only" -> Just TextOnly
  "text only" -> Just TextOnly
  "text" -> Just TextOnly
  _ -> Nothing

type FilterConfig =
  { enabled :: Boolean
  , prompt :: String
  , showStatistics :: Boolean
  , outputLanguage :: OutputLanguage
  }

defaultFilterConfig :: FilterConfig
defaultFilterConfig =
  { enabled: true
  , prompt: "technical content, programming and development, AI/ML research"
  , showStatistics: false
  , outputLanguage: En
  }

normalizePrompt :: String -> String
normalizePrompt = trim

normalizeToken :: String -> String
normalizeToken = toLower <<< trim

normalizeFilterConfig :: FilterConfig -> FilterConfig
normalizeFilterConfig config = config { prompt = normalizePrompt config.prompt }

isFilteringActive :: FilterConfig -> Boolean
isFilteringActive config =
  let normalized = normalizeFilterConfig config
  in normalized.enabled && normalized.prompt /= ""
