module Shared.Types.Tweet where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String.Common (trim, toLower)
import FFI.WebApi (Element)

data MediaType
  = Image

derive instance eqMediaType :: Eq MediaType

mediaTypeToString :: MediaType -> String
mediaTypeToString Image = "image"

parseMediaType :: String -> Maybe MediaType
parseMediaType raw = case toLower (trim raw) of
  "image" -> Just Image
  _ -> Nothing

type MediaData =
  { mediaType :: MediaType
  , url :: String
  }

type QuotedTweet =
  { textContent :: String
  , author :: Maybe String
  , media :: Maybe (Array MediaData)
  }

data RepostInfo
  = NotRepost
  | Reposted (Maybe String)

derive instance eqRepostInfo :: Eq RepostInfo

isRepost :: RepostInfo -> Boolean
isRepost repostInfo = case repostInfo of
  NotRepost -> false
  Reposted _ -> true

repostedBy :: RepostInfo -> Maybe String
repostedBy repostInfo = case repostInfo of
  NotRepost -> Nothing
  Reposted username -> username

-- | TweetData includes a reference to the DOM element
type TweetData =
  { id :: String
  , element :: Element
  , textContent :: String
  , author :: Maybe String
  , media :: Maybe (Array MediaData)
  , quotedTweet :: Maybe QuotedTweet
  , repostInfo :: RepostInfo
  }
