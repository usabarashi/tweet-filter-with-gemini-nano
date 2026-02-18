module Shared.GeminiAvailability where

import Prelude

import Data.String.Common (toLower, trim)

data Availability
  = Available
  | Downloadable
  | AfterDownload
  | Downloading
  | Unavailable
  | Unknown String

derive instance eqAvailability :: Eq Availability

parseAvailability :: String -> Availability
parseAvailability raw = case normalize raw of
  "available" -> Available
  "downloadable" -> Downloadable
  "after-download" -> AfterDownload
  "downloading" -> Downloading
  "unavailable" -> Unavailable
  s -> Unknown s

normalize :: String -> String
normalize = toLower <<< trim

isAvailable :: Availability -> Boolean
isAvailable Available = true
isAvailable _ = false

isDownloadPossible :: Availability -> Boolean
isDownloadPossible Downloadable = true
isDownloadPossible AfterDownload = true
isDownloadPossible _ = false

isUnavailableOrDownloading :: Availability -> Boolean
isUnavailableOrDownloading Unavailable = true
isUnavailableOrDownloading Downloading = true
isUnavailableOrDownloading _ = false
