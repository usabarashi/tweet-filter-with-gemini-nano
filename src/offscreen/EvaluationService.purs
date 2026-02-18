module Offscreen.EvaluationService where

import Prelude

import Control.Alt ((<|>))
import Control.Parallel (sequential, parallel)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toNullable)
import Data.String as String
import Data.String.CodeUnits as CU
import Data.String.Pattern (Pattern(..))
import Effect.Aff (Aff, bracket, delay, error, throwError, try)
import Effect.Aff as Aff
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import FFI.GeminiNano as GeminiNano
import FFI.WebApi as WebApi
import Foreign (unsafeToForeign)
import Offscreen.SessionManager as SessionManager
import Shared.Logger as Logger
import Shared.Types.Tweet (MediaData, MediaType(..), QuotedTweet)

type EvaluationResult =
  { shouldShow :: Boolean
  , evaluationTime :: Number
  , error :: Maybe String
  }

type EvalRequest =
  { tweetId :: String
  , textContent :: String
  , media :: Maybe (Array MediaData)
  , quotedTweet :: Maybe QuotedTweet
  }

data EvaluationInput
  = MainTextInput String
  | QuotedTextInput String
  | QuotedImagesInput (Array MediaData)
  | MainImagesInput (Array MediaData)

-- | Evaluate a tweet through the 4-stage pipeline
evaluateTweet
  :: Ref SessionManager.SessionState
  -> EvalRequest
  -> Aff EvaluationResult
evaluateTweet sessionRef req = do
  startTime <- liftEffect WebApi.dateNow
  -- createClonedSession atomically checks initialization under initLock
  result <- try do
    bracket
      (SessionManager.createClonedSession sessionRef)
      (\session -> void $ try $ GeminiNano.destroySession session)
      (\session -> evaluateWithSession sessionRef session req)
  endTime <- liftEffect WebApi.dateNow
  case result of
    Right shouldShow -> pure { shouldShow, evaluationTime: endTime - startTime, error: Nothing }
    Left err -> pure { shouldShow: true, evaluationTime: endTime - startTime, error: Just (show err) }

-- | A pipeline stage: produces Nothing (skip), Just true (show, short-circuit),
-- | or Just false (hide, continue to next stage).
type Stage = Aff (Maybe Boolean)

-- | Run stages left-to-right. Short-circuit on Just true (show).
-- | Returns Just result if at least one stage evaluated, Nothing if all skipped.
runPipeline :: Array Stage -> Aff (Maybe Boolean)
runPipeline = go Nothing
  where
  go lastResult stages = case Array.uncons stages of
    Nothing -> pure lastResult
    Just { head: stage, tail: rest } -> do
      result <- stage
      case result of
        Just true -> pure (Just true)         -- short-circuit: show
        Just false -> go (Just false) rest    -- evaluated: hide, but try remaining stages
        Nothing -> go lastResult rest         -- skipped: carry forward previous result

-- | Run the 4-stage evaluation pipeline with a cloned session
evaluateWithSession
  :: Ref SessionManager.SessionState
  -> GeminiNano.LanguageModelSession
  -> EvalRequest
  -> Aff Boolean
evaluateWithSession sessionRef session req = do
  state <- liftEffect $ Ref.read sessionRef
  let stages = map (evaluateInput sessionRef session) (collectEvaluationInputs req)
  mResult <- runPipeline stages
  let result = case mResult of
        Just r -> r
        Nothing -> true  -- fallback: no stage could evaluate, show by default

  -- Warning fires only when fallback was actually used (all stages returned Nothing)
  when (mResult == Nothing) $
    liftEffect $ Logger.warn state.logger "[EvaluationService] No evaluable content, showing by default"

  pure result

collectEvaluationInputs :: EvalRequest -> Array EvaluationInput
collectEvaluationInputs req =
  Array.catMaybes
    [ toMainTextInput req.textContent
    , toQuotedTextInput req.quotedTweet
    , toQuotedImagesInput req.quotedTweet
    , toMainImagesInput req.media
    ]

toMainTextInput :: String -> Maybe EvaluationInput
toMainTextInput text =
  let trimmed = String.trim text
  in if trimmed == "" then Nothing else Just (MainTextInput trimmed)

toQuotedTextInput :: Maybe QuotedTweet -> Maybe EvaluationInput
toQuotedTextInput maybeQuoted = do
  qt <- maybeQuoted
  let trimmedText = String.trim qt.textContent
  if trimmedText == "" then
    Nothing
  else
    Just (QuotedTextInput (formatQuotedText qt.author trimmedText))

toQuotedImagesInput :: Maybe QuotedTweet -> Maybe EvaluationInput
toQuotedImagesInput maybeQuoted = do
  qt <- maybeQuoted
  media <- qt.media
  if Array.null media then Nothing else Just (QuotedImagesInput media)

toMainImagesInput :: Maybe (Array MediaData) -> Maybe EvaluationInput
toMainImagesInput maybeMedia = do
  media <- maybeMedia
  if Array.null media then Nothing else Just (MainImagesInput media)

formatQuotedText :: Maybe String -> String -> String
formatQuotedText author text =
  "[Quoting " <> normalizeAuthor author <> ": " <> text <> "]"

normalizeAuthor :: Maybe String -> String
normalizeAuthor maybeAuthor = case maybeAuthor of
  Just author ->
    let trimmed = String.trim author
    in if trimmed == "" then
      "someone"
    else if String.take 1 trimmed == "@" then
      trimmed
    else
      "@" <> trimmed
  Nothing -> "someone"

evaluateInput
  :: Ref SessionManager.SessionState
  -> GeminiNano.LanguageModelSession
  -> EvaluationInput
  -> Stage
evaluateInput sessionRef session input = case input of
  MainTextInput text ->
    Just <$> evaluateText sessionRef session text
  QuotedTextInput text ->
    Just <$> evaluateText sessionRef session text
  QuotedImagesInput media ->
    evaluateImages sessionRef session media "Images in quoted tweet"
  MainImagesInput media ->
    evaluateImages sessionRef session media "Images in this tweet"

evaluateImages
  :: Ref SessionManager.SessionState
  -> GeminiNano.LanguageModelSession
  -> Array MediaData
  -> String
  -> Stage
evaluateImages sessionRef session media label = do
  descs <- describeImages sessionRef session media
  if Array.null descs then
    pure Nothing
  else
    Just <$> evaluateText sessionRef session ("[" <> label <> ": " <> String.joinWith "; " descs <> "]")

-- | Evaluate text against filter criteria using Gemini Nano
evaluateText
  :: Ref SessionManager.SessionState
  -> GeminiNano.LanguageModelSession
  -> String
  -> Aff Boolean
evaluateText sessionRef session tweetText = do
  state <- liftEffect $ Ref.read sessionRef
  mCriteria <- liftEffect $ SessionManager.getFilterCriteria sessionRef
  case mCriteria of
    Nothing -> do
      liftEffect $ Logger.warn state.logger "[EvaluationService] Missing filter criteria, showing by default"
      pure true
    Just criteria -> do
      result <- try do
        let promptStr = buildEvaluationPrompt criteria tweetText
        withTimeout 10000.0 $ GeminiNano.promptText session promptStr (toNullable Nothing)
      case result of
        Left _ -> do
          liftEffect $ Logger.logError state.logger "[EvaluationService] Failed to evaluate text"
          pure true
        Right response -> pure (parseShowResponse response)

buildEvaluationPrompt :: String -> String -> String
buildEvaluationPrompt criteria tweetText =
  "Evaluate if this tweet matches the following criteria:\n"
    <> "\"" <> criteria <> "\"\n\n"
    <> "Tweet text: \"" <> tweetText <> "\"\n\n"
    <> "Return JSON only with one boolean field named show.\n"
    <> "Do not include any other keys or explanation."

-- | Parse the AI response for "show": true/false anywhere in the text.
-- | Handles variants like {"show": false, "reason": "..."} and extra whitespace.
parseShowResponse :: String -> Boolean
parseShowResponse response =
  fromMaybe true (parseShowResponseImpl normalized)
  where
  normalized = String.toLower (String.trim response)

parseShowResponseImpl :: String -> Maybe Boolean
parseShowResponseImpl response = do
  idx <- CU.lastIndexOf (Pattern "\"show\"") response
  parseShowValue (CU.drop idx response)

parseShowValue :: String -> Maybe Boolean
parseShowValue s = do
  colonIdx <- CU.indexOf (Pattern ":") s
  let value = String.trim (CU.drop (colonIdx + 1) s)
  parseBooleanPrefix value

parseBooleanPrefix :: String -> Maybe Boolean
parseBooleanPrefix value
  | hasBooleanTokenPrefix "true" value = Just true
  | hasBooleanTokenPrefix "false" value = Just false
  | otherwise = Nothing

hasBooleanTokenPrefix :: String -> String -> Boolean
hasBooleanTokenPrefix token value =
  startsWith token value
    && tokenBoundary token value

tokenBoundary :: String -> String -> Boolean
tokenBoundary token value = case CU.charAt (CU.length token) value of
  Nothing -> true
  Just ch -> not (isIdentifierContinuation ch)

isIdentifierContinuation :: Char -> Boolean
isIdentifierContinuation ch =
  isAsciiAlphaNum ch || ch == '_'

isAsciiAlphaNum :: Char -> Boolean
isAsciiAlphaNum ch =
  (ch >= 'a' && ch <= 'z')
    || (ch >= 'A' && ch <= 'Z')
    || (ch >= '0' && ch <= '9')

startsWith :: String -> String -> Boolean
startsWith prefix s =
  CU.take (CU.length prefix) s == prefix

-- | Describe images using multimodal prompt
describeImages
  :: Ref SessionManager.SessionState
  -> GeminiNano.LanguageModelSession
  -> Array MediaData
  -> Aff (Array String)
describeImages sessionRef session media = do
  state <- liftEffect $ Ref.read sessionRef
  isMultimodal <- liftEffect $ SessionManager.isMultimodalEnabled sessionRef
  let imageMedia = imageMediaOnly media
  if Array.null imageMedia then
    pure []
  else if not isMultimodal then do
    liftEffect $ Logger.warn state.logger "[EvaluationService] Multimodal not supported, skipping image description"
    pure []
  else do
    -- Fetch images and describe them sequentially.
    -- Build in reverse with cons to avoid O(n^2) snoc costs.
    reversed <- Array.foldM (\acc item -> do
      result <- try do
        blob <- withTimeout 5000.0 $ WebApi.fetchBlob item.url
        let messages = unsafeToForeign
              [ unsafeToForeign
                  { role: "user"
                  , content:
                      [ unsafeToForeign { "type": "text", value: "Describe this image in 1-2 sentences. Focus on the main subject and content." }
                      , unsafeToForeign { "type": "image", value: blob }
                      ]
                  }
              ]
        withTimeout 10000.0 $ GeminiNano.promptMultimodal session messages (toNullable Nothing)
      case result of
        Right desc ->
          let trimmed = String.trim desc
          in if trimmed == "" then pure acc else pure (Array.cons trimmed acc)
        Left _ -> do
          liftEffect $ Logger.logError state.logger "[EvaluationService] Failed to describe image"
          pure acc
    ) [] imageMedia
    pure (Array.reverse reversed)

imageMediaOnly :: Array MediaData -> Array MediaData
imageMediaOnly = Array.filter (\media -> media.mediaType == Image)

-- | Race an Aff action against a timeout. The loser is cancelled.
withTimeout :: forall a. Number -> Aff a -> Aff a
withTimeout ms action =
  sequential (parallel action <|> parallel timeoutAff)
  where
  timeoutAff = do
    delay (Aff.Milliseconds ms)
    throwError (error "Operation timed out")
