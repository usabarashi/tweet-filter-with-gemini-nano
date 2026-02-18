module Content.TweetObserver where

import Prelude

import Data.Array (last, null, uncons)
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Data.String (joinWith)
import Data.String.Common (trim)
import Data.Traversable (for_, traverse)
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.WebApi (Element, MutationObserverHandle)
import FFI.WebApi as WebApi
import Shared.Constants (tweetSelectors)
import Shared.Logger as Logger
import Shared.Types.Tweet (MediaData, QuotedTweet, RepostInfo(..), TweetData, MediaType(..))

type TweetCallback = TweetData -> Effect Unit

type ObserverState =
  { observer :: Maybe MutationObserverHandle
  , callback :: Maybe TweetCallback
  , logger :: Ref Logger.LoggerState
  }

-- | Create a new TweetObserver
new :: Ref Logger.LoggerState -> Effect (Ref ObserverState)
new loggerRef =
  Ref.new { observer: Nothing, callback: Nothing, logger: loggerRef }

-- | Start observing for tweets
start :: Ref ObserverState -> TweetCallback -> Effect Unit
start ref cb = do
  stop ref
  Ref.modify_ (_ { callback = Just cb }) ref
  state <- Ref.read ref
  -- Process existing tweets
  body <- WebApi.getDocumentBody
  processExistingTweets state body
  -- Set up MutationObserver
  observer <- WebApi.newMutationObserver \addedNodes ->
    for_ addedNodes \node -> do
      mElement <- WebApi.asElement node
      case mElement of
        Nothing -> pure unit
        Just el -> do
          st <- Ref.read ref
          findAndProcessTweets st el
  -- Observe main or body
  mMain <- WebApi.documentQuerySelector "main"
  let target = case toMaybe mMain of
        Just m -> m
        Nothing -> body
  WebApi.observeMutations observer target { childList: true, subtree: true }
  Ref.modify_ (_ { observer = Just observer }) ref

-- | Stop observing
stop :: Ref ObserverState -> Effect Unit
stop ref = do
  state <- Ref.read ref
  case state.observer of
    Nothing -> pure unit
    Just obs -> do
      WebApi.disconnectObserver obs
      Ref.modify_ (_ { observer = Nothing }) ref

-- | Process existing tweets on the page
processExistingTweets :: ObserverState -> Element -> Effect Unit
processExistingTweets state root = do
  tweets <- findTweetElements root
  for_ tweets \el -> processTweetElement state el

-- | Find and process tweets from an added node
findAndProcessTweets :: ObserverState -> Element -> Effect Unit
findAndProcessTweets state root = do
  -- Check if root itself is a tweet
  isTweet <- isTweetElement root
  if isTweet then
    processTweetElement state root
  else do
    tweets <- findTweetElements root
    for_ tweets \el -> processTweetElement state el

-- | Find tweet elements using selectors
findTweetElements :: Element -> Effect (Array Element)
findTweetElements root = do
  let selector = joinWith ", " tweetSelectors
  els <- WebApi.querySelectorAll root selector
  if null els then WebApi.querySelectorAll root "article" else pure els

-- | Check if an element matches tweet selectors
isTweetElement :: Element -> Effect Boolean
isTweetElement el = anyM (\sel -> WebApi.matches el sel) tweetSelectors

-- | Process a single tweet element
processTweetElement :: ObserverState -> Element -> Effect Unit
processTweetElement state element = do
  connected <- WebApi.isConnected element
  when connected do
    tweetId <- extractTweetId element
    text <- extractTweetText element
    author <- extractAuthor element
    media <- extractMainMedia element
    quotedTweet <- extractQuotedTweet element
    repost <- extractRepostInfo element

    let tweetData = buildTweetData element tweetId text author media quotedTweet repost

    Logger.log state.logger ("[Tweet Filter] Detected tweet: " <> tweetId)

    case state.callback of
      Nothing -> pure unit
      Just cb ->
        -- Delay for tweets with media (lazy loading)
        if shouldDelayCallback tweetData then
          void $ WebApi.setTimeout 100 (cb tweetData)
        else
          cb tweetData

-- | Extract tweet ID from status link
extractTweetId :: Element -> Effect String
extractTweetId element = do
  mLink <- WebApi.querySelector element "a[href*=\"/status/\"]"
  mTweetId <- case toMaybe mLink of
    Nothing -> pure Nothing
    Just link -> do
      mHref <- WebApi.getAttribute link "href"
      pure do
        href <- toMaybe mHref
        toMaybe (WebApi.matchStatusId href)
  case mTweetId of
    Just tweetId -> pure tweetId
    Nothing -> WebApi.generateFallbackId

-- | Extract tweet text
extractTweetText :: Element -> Effect String
extractTweetText element = do
  mEl <- WebApi.querySelector element "[data-testid=\"tweetText\"]"
  case toMaybe mEl of
    Nothing -> pure ""
    Just el -> do
      text <- WebApi.getTextContent el
      pure (trim text)

-- | Extract author (returns Nothing for absent or empty-string authors)
extractAuthor :: Element -> Effect (Maybe String)
extractAuthor element = do
  mEl <- WebApi.querySelector element "[data-testid=\"User-Name\"]"
  case toMaybe mEl of
    Nothing -> pure Nothing
    Just el -> do
      text <- WebApi.getTextContent el
      pure (nonEmptyTrimmed text)

-- | Extract media images for the main tweet (excluding quoted tweet media)
extractMainMedia :: Element -> Effect (Array MediaData)
extractMainMedia element = do
  quotedContainer <- findQuotedTweetContainer element
  allImages <- WebApi.querySelectorAll element "img"
  collectMedia allImages quotedContainer
  where
  collectMedia :: Array Element -> Maybe Element -> Effect (Array MediaData)
  collectMedia imgs mQuoted = do
    items <- Array.catMaybes <$> traverse (processImg mQuoted) imgs
    pure $ Array.nubByEq (\a b -> a.url == b.url) items
  processImg :: Maybe Element -> Element -> Effect (Maybe MediaData)
  processImg mQuoted img = do
    src <- WebApi.getSrc img
    if WebApi.stringIncludes src "pbs.twimg.com/media/" then do
      isInQuoted <- case mQuoted of
        Nothing -> pure false
        Just q -> WebApi.contains q img
      if isInQuoted then pure Nothing
      else pure (Just { mediaType: Image, url: WebApi.normalizeImageUrl src })
    else pure Nothing

-- | Extract quoted tweet content
extractQuotedTweet :: Element -> Effect (Maybe QuotedTweet)
extractQuotedTweet element = do
  mContainer <- findQuotedTweetContainer element
  case mContainer of
    Nothing -> pure Nothing
    Just container -> do
      -- Extract text from quoted tweet
      textEls <- WebApi.querySelectorAll container "[data-testid=\"tweetText\"]"
      quotedText <- if null textEls then pure ""
        else do
          -- Last tweetText element is usually the quoted tweet text
          case last textEls of
            Nothing -> pure ""
            Just el -> do
              text <- WebApi.getTextContent el
              pure (trim text)

      -- Extract media from quoted tweet
      quotedImages <- WebApi.querySelectorAll container "img[src*=\"pbs.twimg.com/media\"]"
      quotedMedia <- collectQuotedMedia quotedImages

      -- Extract author
      mAuthorEl <- WebApi.querySelector container "[data-testid=\"User-Name\"]"
      quotedAuthor <- case toMaybe mAuthorEl of
        Nothing -> pure Nothing
        Just el -> do
          text <- WebApi.getTextContent el
          pure (nonEmptyTrimmed text)

      -- Only return if we found content
      if quotedText == "" && null quotedMedia then
        pure Nothing
      else
        pure $ Just
          { textContent: quotedText
          , author: quotedAuthor
          , media: if null quotedMedia then Nothing else Just quotedMedia
          }
  where
  collectQuotedMedia :: Array Element -> Effect (Array MediaData)
  collectQuotedMedia imgs = traverse (\img -> do
    src <- WebApi.getSrc img
    pure { mediaType: Image, url: WebApi.normalizeImageUrl src }
  ) imgs

-- | Find the quoted tweet container element
findQuotedTweetContainer :: Element -> Effect (Maybe Element)
findQuotedTweetContainer element =
  firstJustM (\selector -> toMaybe <$> WebApi.querySelector element selector)
    [ "[data-testid=\"card.layoutSmall.media\"]"
    , "div[role=\"link\"] article"
    , "div[role=\"link\"][href*=\"/status/\"]"
    ]

-- | Extract repost info by looking for social context indicators
extractRepostInfo :: Element -> Effect RepostInfo
extractRepostInfo element = walkParents element
  where
  walkParents :: Element -> Effect RepostInfo
  walkParents el = do
    mParent <- WebApi.getParentElement el
    case toMaybe mParent of
      Nothing -> pure NotRepost
      Just parent -> do
        -- Check for body (stop condition)
        isBody <- WebApi.matches parent "body"
        if isBody then pure NotRepost
        else do
            indicators <- WebApi.querySelectorAll parent "[data-testid=\"socialContext\"]"
            result <- checkIndicators indicators
            case result of
              Just r -> pure r
              Nothing -> walkParents parent

  checkIndicators :: Array Element -> Effect (Maybe RepostInfo)
  checkIndicators arr = case uncons arr of
    Nothing -> pure Nothing
    Just { head: indicator, tail: rest } -> do
      text <- WebApi.getTextContent indicator
      let trimmed = trim text
      if isRepostText trimmed then do
        mUserLink <- WebApi.querySelector indicator "a[href^=\"/\"]"
        username <- case toMaybe mUserLink of
          Nothing -> pure Nothing
          Just link -> do
            utext <- WebApi.getTextContent link
            pure (nonEmptyTrimmed utext)
        pure $ Just (Reposted username)
      else
        checkIndicators rest

  isRepostText :: String -> Boolean
  isRepostText t =
    WebApi.stringIncludes t "Reposted"
      || WebApi.stringIncludes t "retweeted"
      || WebApi.stringIncludes t "\x30EA\x30DD\x30B9\x30C8"

-- Utility helpers

anyM :: forall a. (a -> Effect Boolean) -> Array a -> Effect Boolean
anyM f arr = case uncons arr of
  Nothing -> pure false
  Just { head: x, tail: rest } -> do
    r <- f x
    if r then pure true else anyM f rest

firstJustM :: forall a b. (a -> Effect (Maybe b)) -> Array a -> Effect (Maybe b)
firstJustM f arr = case uncons arr of
  Nothing -> pure Nothing
  Just { head: x, tail: rest } -> do
    result <- f x
    case result of
      Just _ -> pure result
      Nothing -> firstJustM f rest

nonEmptyTrimmed :: String -> Maybe String
nonEmptyTrimmed input =
  let trimmed = trim input
  in if trimmed == "" then Nothing else Just trimmed

-- | Check if a quoted tweet has media
hasQuotedMedia :: Maybe QuotedTweet -> Boolean
hasQuotedMedia Nothing = false
hasQuotedMedia (Just qt) = case qt.media of
  Nothing -> false
  Just m -> not (null m)

buildTweetData
  :: Element
  -> String
  -> String
  -> Maybe String
  -> Array MediaData
  -> Maybe QuotedTweet
  -> RepostInfo
  -> TweetData
buildTweetData element tweetId text author media quotedTweet repost =
  { id: tweetId
  , element
  , textContent: text
  , author
  , media: if null media then Nothing else Just media
  , quotedTweet
  , repostInfo: repost
  }

shouldDelayCallback :: TweetData -> Boolean
shouldDelayCallback tweetData =
  case tweetData.media of
    Just media -> not (null media) || hasQuotedMedia tweetData.quotedTweet
    Nothing -> hasQuotedMedia tweetData.quotedTweet
