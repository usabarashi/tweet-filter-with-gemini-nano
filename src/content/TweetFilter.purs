module Content.TweetFilter where

import Prelude

import Content.DomManipulator as Dom
import Data.Array (null, uncons)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Data.Maybe as Maybe
import Data.String.Common (trim)
import Effect (Effect)
import Effect.AVar as EAVar
import Effect.Aff (Aff, bracket, launchAff_, try)
import Effect.Aff as Aff
import Effect.Aff.AVar (AVar)
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.Chrome.Runtime as Runtime
import Shared.Constants (delayBetweenBatches)
import Shared.Logger as Logger
import Shared.Messaging.Client as Client
import Shared.Messaging.Types as Types
import Shared.Types.Tweet (MediaData, QuotedTweet, TweetData)

type FilterState =
  { queue :: TweetQueue
  , processingLock :: AVar Unit  -- full = idle, empty = processing
  , generation :: Int
  , logger :: Ref Logger.LoggerState
  }

type TweetQueue =
  { front :: Array TweetData
  , back :: Array TweetData
  }

data EvaluateOutcome
  = Evaluated { shouldShow :: Boolean, cacheHit :: Boolean, evaluationTime :: Number }
  | ServiceError String
  | DecodeError String
  | UnexpectedResponse String

emptyQueue :: TweetQueue
emptyQueue = { front: [], back: [] }

enqueueQueue :: TweetData -> TweetQueue -> TweetQueue
enqueueQueue tweet q = q { back = Array.cons tweet q.back }

dequeueQueue :: TweetQueue -> Maybe { item :: TweetData, next :: TweetQueue }
dequeueQueue q = case uncons q.front of
  Just { head: item, tail: rest } ->
    Just { item, next: q { front = rest } }
  Nothing ->
    let
      replenished = Array.reverse q.back
      rebuilt = { front: replenished, back: [] }
    in case uncons rebuilt.front of
      Nothing -> Nothing
      Just { head: item, tail: rest } ->
        Just { item, next: rebuilt { front = rest } }

-- | Create a new TweetFilter
new :: Ref Logger.LoggerState -> Effect (Ref FilterState)
new loggerRef = do
  Logger.log loggerRef "[TweetFilter] Initialized (delegating to service worker)"
  lock <- EAVar.new unit
  Ref.new { queue: emptyQueue, processingLock: lock, generation: 0, logger: loggerRef }

-- | Queue a tweet for processing
processTweet :: Ref FilterState -> TweetData -> Effect Unit
processTweet ref tweet = do
  currentGeneration <- getGeneration ref
  if not (hasTweetContent tweet) then do
    state <- Ref.read ref
    Logger.log state.logger "[Tweet Filter] Skipping completely empty tweet"
    Dom.markAsProcessed tweet.element
  else do
    -- Skip already processed
    processed <- Dom.isProcessed tweet.element
    unless processed do
      enqueued <- Ref.modify' (\s ->
        if s.generation == currentGeneration then
          { state: s { queue = enqueueQueue tweet s.queue }, value: true }
        else
          { state: s, value: false }
      ) ref
      when enqueued $
        processQueue ref currentGeneration

-- | Process the queue serially.
-- | Uses AVar.tryTake for non-blocking mutex acquisition: if the lock is
-- | already taken (processing in progress), this is a no-op.
processQueue :: Ref FilterState -> Int -> Effect Unit
processQueue ref generation = do
  state <- Ref.read ref
  launchWithTryLock state.processingLock do
    result <- try $ processLoop ref generation
    case result of
      Left err -> do
        liftEffect $ withLogger ref \logger ->
          Logger.logError logger ("[Tweet Filter] Queue loop crashed: " <> show err)
      Right _ -> pure unit

processLoop :: Ref FilterState -> Int -> Aff Unit
processLoop ref generation = do
  stale <- liftEffect $ isStaleGeneration ref generation
  unless stale do
    mTweet <- liftEffect $ dequeue ref
    case mTweet of
      Nothing -> pure unit  -- queue empty, lock released by caller
      Just tweet -> do
        if not (hasTweetContent tweet) then do
          liftEffect $ withLogger ref \logger ->
            Logger.log logger "[Tweet Filter] No content to evaluate, showing tweet by default"
          liftEffect $ Dom.markAsProcessed tweet.element
        else do
          result <- try $ evaluateTweet ref tweet
          case result of
            Right _ -> pure unit
            Left err -> do
              -- Check if extension context is invalidated
              valid <- liftEffect Runtime.isContextValid
              unless valid do
                liftEffect $ withLogger ref \logger ->
                  Logger.logError logger "[Tweet Filter] Extension context invalidated, stopping queue"
                liftEffect $ Ref.modify_ (_ { queue = emptyQueue }) ref
              liftEffect $ withLogger ref \logger ->
                Logger.logError logger ("[Tweet Filter] Failed to evaluate tweet: " <> show err)
          liftEffect $ Dom.markAsProcessed tweet.element

        -- Check generation again before continuing
        stale' <- liftEffect $ isStaleGeneration ref generation
        unless stale' do
          Aff.delay (Aff.Milliseconds (toNumber delayBetweenBatches))
          processLoop ref generation

-- | Send evaluation request and act on the result.
-- | Decodes the response with the typed decoder for type-safe field access.
evaluateTweet :: Ref FilterState -> TweetData -> Aff Unit
evaluateTweet ref tweet = do
  logger <- liftEffect $ getLogger ref
  resp <- Client.evaluateTweet
    { tweetId: tweet.id
    , textContent: tweet.textContent
    , media: tweet.media
    , quotedTweet: tweet.quotedTweet
    }
  case evaluateOutcomeFromDecode (Types.decodeMessage resp) of
    Evaluated r -> do
      liftEffect $ Logger.log logger
        ("[Tweet Filter] " <> (if r.cacheHit then "Cache hit" else "Evaluated")
         <> " for tweet " <> tweet.id
         <> ": shouldShow=" <> show r.shouldShow
         <> ", time=" <> show r.evaluationTime <> "ms")
      unless r.shouldShow do
        liftEffect $ Logger.log logger "[Tweet Filter] Collapsing tweet"
        liftEffect $ Dom.collapseTweet tweet.element
    ServiceError err ->
      liftEffect $ Logger.logError logger ("[Tweet Filter] Error from service worker: " <> err)
    DecodeError err ->
      liftEffect $ Logger.logError logger ("[Tweet Filter] Failed to decode response: " <> err)
    UnexpectedResponse msgType ->
      liftEffect $ Logger.logError logger ("[Tweet Filter] Unexpected response type: " <> msgType)

-- | Remove and return the first item from the queue
dequeue :: Ref FilterState -> Effect (Maybe TweetData)
dequeue ref =
  Ref.modify' update ref
  where
  update state = case dequeueQueue state.queue of
    Nothing -> { state, value: Nothing }
    Just { item, next } ->
      { state: state { queue = next }
      , value: Just item
      }

-- | Destroy the filter, clearing the queue, signalling cancellation, and resetting the lock.
destroy :: Ref FilterState -> Effect Unit
destroy ref = do
  state <- Ref.read ref
  Ref.modify_ (\s -> s { queue = emptyQueue, generation = s.generation + 1 }) ref
  -- Ensure lock is in idle state (full) for potential reuse
  void $ EAVar.tryPut unit state.processingLock

isStaleGeneration :: Ref FilterState -> Int -> Effect Boolean
isStaleGeneration ref expected =
  map (\state -> state.generation /= expected) (Ref.read ref)

getGeneration :: Ref FilterState -> Effect Int
getGeneration ref = map _.generation (Ref.read ref)

getLogger :: Ref FilterState -> Effect (Ref Logger.LoggerState)
getLogger ref = map _.logger (Ref.read ref)

withLogger :: Ref FilterState -> (Ref Logger.LoggerState -> Effect Unit) -> Effect Unit
withLogger ref f = getLogger ref >>= f

evaluateOutcomeFromDecode :: Either String Types.Message -> EvaluateOutcome
evaluateOutcomeFromDecode decodeResult = case decodeResult of
  Right (Types.EvaluateResponse r) -> case r.error of
    Just err -> ServiceError err
    Nothing ->
      Evaluated
        { shouldShow: r.shouldShow
        , cacheHit: r.cacheHit
        , evaluationTime: r.evaluationTime
        }
  Right (Types.ErrorMessage r) -> ServiceError r.error
  Right other -> UnexpectedResponse (Types.messageType other)
  Left err -> DecodeError err

launchWithTryLock :: AVar Unit -> Aff Unit -> Effect Unit
launchWithTryLock lock action = do
  mLock <- EAVar.tryTake lock
  case mLock of
    Nothing -> pure unit
    Just _ ->
      launchAff_ $
        bracket
          (pure unit)
          (\_ -> liftEffect $ void $ EAVar.tryPut unit lock)
          (\_ -> action)

hasTweetContent :: TweetData -> Boolean
hasTweetContent tweet =
  trim tweet.textContent /= ""
    || hasMediaContent tweet.media
    || hasQuotedTweetContent tweet.quotedTweet

hasQuotedTweetContent :: Maybe QuotedTweet -> Boolean
hasQuotedTweetContent maybeQuoted =
  Maybe.maybe false
    (\qt ->
    trim qt.textContent /= "" || hasMediaContent qt.media
    )
    maybeQuoted

hasMediaContent :: Maybe (Array MediaData) -> Boolean
hasMediaContent =
  Maybe.maybe false (not <<< null)
