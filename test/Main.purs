module Test.Main where

import Prelude

import Background.CacheManager as CacheManager
import Content.Main as ContentMain
import Content.TweetFilter as TweetFilter
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), isJust, isNothing)
import Data.Nullable (toNullable)
import Data.String.CodeUnits (indexOf)
import Data.String.Pattern (Pattern(..))
import Effect (Effect)
import Effect.Console as Console
import Effect.Exception as Exception
import Foreign (unsafeToForeign)
import Foreign.Object as Object
import Offscreen.EvaluationService as EvalService
import Offscreen.Main as OffscreenMain
import Offscreen.SessionManager as SessionManager
import Options.Main as OptionsMain
import Shared.Constants as Constants
import Shared.GeminiAvailability (Availability(..), parseAvailability)
import Shared.Messaging.Constants as C
import Shared.Messaging.Types as Types
import Shared.Storage as Storage
import Shared.Types.Storage (OutputLanguage(..), SessionType(..), outputLanguageFromString, outputLanguageToString, parseOutputLanguage, sessionTypeFromString)
import Shared.Types.Tweet (MediaType(..), RepostInfo(..), mediaTypeToString, parseMediaType, isRepost, repostedBy)

main :: Effect Unit
main = do
  Console.log "Running tests..."

  testOutputLanguage
  testMediaType
  testConstants
  testProtocolRoundtrip
  testMalformedInput
  testRequiredFieldRegression
  testNestedDecodeValidation
  testStrictTypeValidation
  testObjectBoundaryValidation
  testCacheDecodeValidation
  testOutputLanguageStrictValidation
  testStorageStrictOutputLanguage
  testSessionTypeParsing
  testInitResponseSessionTypeStrict
  testAvailabilityParsing
  testSenderTabDetection
  testFilteringTransition
  testParseShowResponse
  testSessionCreationPlanning
  testSessionInitializeResultModel
  testEvaluateOutcomeDecode
  testRepostInfoModel

  Console.log "All tests passed!"

-- | OutputLanguage round-trip
testOutputLanguage :: Effect Unit
testOutputLanguage = do
  Console.log "  [OutputLanguage]"
  assert "En round-trip" $ outputLanguageFromString (outputLanguageToString En) == En
  assert "Es round-trip" $ outputLanguageFromString (outputLanguageToString Es) == Es
  assert "Ja round-trip" $ outputLanguageFromString (outputLanguageToString Ja) == Ja
  assert "Unknown -> En" $ outputLanguageFromString "unknown" == En
  assert "Strict parse en" $ parseOutputLanguage "en" == Right En
  assert "Trimmed parse EN" $ parseOutputLanguage " EN " == Right En
  assert "Case-insensitive parse es" $ parseOutputLanguage "Es" == Right Es
  assert "Strict parse invalid" $ case parseOutputLanguage "fr" of
    Left _ -> true
    Right _ -> false
  assert "Loose decode trimmed ja" $ outputLanguageFromString " ja " == Ja

testMediaType :: Effect Unit
testMediaType = do
  Console.log "  [MediaType]"
  assert "Image round-trip" $ parseMediaType (mediaTypeToString Image) == Just Image
  assert "Case-insensitive parse IMAGE" $ parseMediaType " IMAGE " == Just Image
  assert "Invalid media type" $ parseMediaType "video" == Nothing

-- | Constants are defined
testConstants :: Effect Unit
testConstants = do
  Console.log "  [Constants]"
  assert "tweetSelectors non-empty" $ Constants.tweetSelectors /= []
  assert "initRequest defined" $ C.initRequest /= ""
  assert "evaluateRequest defined" $ C.evaluateRequest /= ""

-- | Encode/decode roundtrip tests
testProtocolRoundtrip :: Effect Unit
testProtocolRoundtrip = do
  Console.log "  [Protocol Roundtrip]"

  -- InitRequest roundtrip
  let msg1 = Types.InitRequest
        { requestId: "req-1", timestamp: 1000.0
        , config: { prompt: "filter prompt", outputLanguage: En } }
  let r1 = Types.decodeMessage (Types.encodeMessage msg1)
  case r1 of
    Right (Types.InitRequest r) -> do
      assert "InitRequest.requestId" $ r.requestId == "req-1"
      assert "InitRequest.config.prompt" $ r.config.prompt == "filter prompt"
    _ -> failWith "InitRequest roundtrip"

  -- EvaluateResponse roundtrip
  let msg2 = Types.EvaluateResponse
        { requestId: "req-2", timestamp: 2000.0, tweetId: "tw-1"
        , shouldShow: false, cacheHit: true, evaluationTime: 42.5
        , error: Nothing }
  let r2 = Types.decodeMessage (Types.encodeMessage msg2)
  case r2 of
    Right (Types.EvaluateResponse r) -> do
      assert "EvalResp.tweetId" $ r.tweetId == "tw-1"
      assert "EvalResp.shouldShow" $ r.shouldShow == false
      assert "EvalResp.cacheHit" $ r.cacheHit == true
      assert "EvalResp.evaluationTime" $ r.evaluationTime == 42.5
      assert "EvalResp.error" $ isNothing r.error
    _ -> failWith "EvaluateResponse roundtrip"

  -- EvaluateRequest roundtrip (media + quotedTweet)
  let msgMedia = Types.EvaluateRequest
        { requestId: "req-media", timestamp: 2100.0, tweetId: "tw-media"
        , textContent: "hello"
        , media: Just [{ mediaType: Image, url: "https://example.com/a.jpg" }]
        , quotedTweet: Just
            { textContent: "quoted"
            , author: Just "@user"
            , media: Just [{ mediaType: Image, url: "https://example.com/q.jpg" }]
            }
        }
  let rMedia = Types.decodeMessage (Types.encodeMessage msgMedia)
  case rMedia of
    Right (Types.EvaluateRequest r) -> do
      assert "EvaluateRequest media decode" $ r.media == Just [{ mediaType: Image, url: "https://example.com/a.jpg" }]
      assert "EvaluateRequest quoted media decode" $
        map _.media r.quotedTweet == Just (Just [{ mediaType: Image, url: "https://example.com/q.jpg" }])
    _ -> failWith "EvaluateRequest roundtrip with media"

  -- CacheCheckRequest roundtrip (regression target)
  let msg3 = Types.CacheCheckRequest
        { requestId: "req-3", timestamp: 3000.0
        , tweetIds: ["a", "b", "c"] }
  let r3 = Types.decodeMessage (Types.encodeMessage msg3)
  case r3 of
    Right (Types.CacheCheckRequest r) -> do
      assert "CacheCheckReq.tweetIds" $ r.tweetIds == ["a", "b", "c"]
    _ -> failWith "CacheCheckRequest roundtrip"

  -- CacheCheckResponse roundtrip (regression target)
  let results = Object.fromHomogeneous { a: true, b: false }
  let msg4 = Types.CacheCheckResponse
        { requestId: "req-4", timestamp: 4000.0, results }
  let r4 = Types.decodeMessage (Types.encodeMessage msg4)
  case r4 of
    Right (Types.CacheCheckResponse r) -> do
      assert "CacheCheckResp.results.a" $ Object.lookup "a" r.results == Just true
      assert "CacheCheckResp.results.b" $ Object.lookup "b" r.results == Just false
    _ -> failWith "CacheCheckResponse roundtrip"

  -- ErrorMessage roundtrip (nullable originalRequestId)
  let msg5 = Types.ErrorMessage
        { requestId: "req-5", timestamp: 5000.0
        , error: "something failed", originalRequestId: Just "orig-1" }
  let r5 = Types.decodeMessage (Types.encodeMessage msg5)
  case r5 of
    Right (Types.ErrorMessage r) -> do
      assert "ErrorMsg.error" $ r.error == "something failed"
      assert "ErrorMsg.originalRequestId" $ r.originalRequestId == Just "orig-1"
    _ -> failWith "ErrorMessage roundtrip"

  -- ErrorMessage with Nothing originalRequestId
  let msg6 = Types.ErrorMessage
        { requestId: "req-6", timestamp: 6000.0
        , error: "another error", originalRequestId: Nothing }
  let r6 = Types.decodeMessage (Types.encodeMessage msg6)
  case r6 of
    Right (Types.ErrorMessage r) -> do
      assert "ErrorMsg.origReqId Nothing" $ isNothing r.originalRequestId
    _ -> failWith "ErrorMessage roundtrip (Nothing)"

  -- SessionStatusResponse roundtrip
  let msg7 = Types.SessionStatusResponse
        { requestId: "req-7", timestamp: 7000.0
        , initialized: true, isMultimodal: false
        , currentConfig: Just { prompt: "test", outputLanguage: Ja } }
  let r7 = Types.decodeMessage (Types.encodeMessage msg7)
  case r7 of
    Right (Types.SessionStatusResponse r) -> do
      assert "SessionStatus.initialized" $ r.initialized == true
      assert "SessionStatus.isMultimodal" $ r.isMultimodal == false
      case r.currentConfig of
        Just c -> do
          assert "SessionStatus.config.prompt" $ c.prompt == "test"
          assert "SessionStatus.config.lang" $ c.outputLanguage == Ja
        Nothing -> failWith "SessionStatus.currentConfig should be Just"
    _ -> failWith "SessionStatusResponse roundtrip"

-- | Malformed input tests
testMalformedInput :: Effect Unit
testMalformedInput = do
  Console.log "  [Malformed Input]"

  -- Empty object: missing "type" field
  let r1 = Types.decodeMessage (unsafeToForeign {})
  assertLeft "empty object" r1

  -- Missing requestId
  let r2 = Types.decodeMessage (unsafeToForeign { "type": C.initRequest })
  assertLeft "missing requestId" r2

  -- Wrong type for boolean field
  let wrongType = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.evaluateResponse
        , requestId: unsafeToForeign "r1"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetId: unsafeToForeign "tw1"
        , shouldShow: unsafeToForeign "not-a-boolean"
        , cacheHit: unsafeToForeign true
        , evaluationTime: unsafeToForeign (0.0 :: Number)
        }
  let r3 = Types.decodeMessage wrongType
  assertLeft "wrong type for shouldShow" r3

-- | Required field regression tests (cacheCheckRequest.tweetIds, cacheCheckResponse.results)
testRequiredFieldRegression :: Effect Unit
testRequiredFieldRegression = do
  Console.log "  [Required Field Regression]"

  -- CacheCheckRequest without tweetIds
  let noTweetIds = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.cacheCheckRequest
        , requestId: unsafeToForeign "r1"
        , timestamp: unsafeToForeign (1.0 :: Number)
        }
  let r1 = Types.decodeMessage noTweetIds
  case r1 of
    Left err -> do
      assert "missing tweetIds mentions field" $ isJust $ indexOf (Pattern "tweetIds") err
    Right _ -> failWith "should fail on missing tweetIds"

  -- CacheCheckResponse without results
  let noResults = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.cacheCheckResponse
        , requestId: unsafeToForeign "r2"
        , timestamp: unsafeToForeign (2.0 :: Number)
        }
  let r2 = Types.decodeMessage noResults
  case r2 of
    Left err -> do
      assert "missing results mentions field" $ isJust $ indexOf (Pattern "results") err
    Right _ -> failWith "should fail on missing results"

testNestedDecodeValidation :: Effect Unit
testNestedDecodeValidation = do
  Console.log "  [Nested Decode Validation]"
  let badMedia = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.evaluateRequest
        , requestId: unsafeToForeign "r-media"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetId: unsafeToForeign "tw1"
        , textContent: unsafeToForeign "hello"
        , media: unsafeToForeign [ unsafeToForeign (Object.fromHomogeneous { "type": unsafeToForeign (1 :: Int), url: unsafeToForeign "u" }) ]
        }
  let r1 = Types.decodeMessage badMedia
  assertLeft "bad media entry should fail" r1

  let badMediaType = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.evaluateRequest
        , requestId: unsafeToForeign "r-media-type"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetId: unsafeToForeign "tw3"
        , textContent: unsafeToForeign "hello"
        , media: unsafeToForeign [ unsafeToForeign (Object.fromHomogeneous { "type": unsafeToForeign "video", url: unsafeToForeign "u" }) ]
        }
  let rMediaType = Types.decodeMessage badMediaType
  assertLeft "unsupported media type should fail" rMediaType

  let badQuoted = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.evaluateRequest
        , requestId: unsafeToForeign "r-quoted"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetId: unsafeToForeign "tw2"
        , textContent: unsafeToForeign "hello"
        , quotedTweet: unsafeToForeign (Object.fromHomogeneous
            { textContent: unsafeToForeign "quoted"
            , author: unsafeToForeign (123 :: Int)
            })
        }
  let r2 = Types.decodeMessage badQuoted
  assertLeft "bad quotedTweet.author should fail" r2

testStrictTypeValidation :: Effect Unit
testStrictTypeValidation = do
  Console.log "  [Strict Type Validation]"

  let badTweetIds = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.cacheCheckRequest
        , requestId: unsafeToForeign "r-bad-ids"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetIds: unsafeToForeign [ unsafeToForeign "ok", unsafeToForeign (1 :: Int) ]
        }
  let r1 = Types.decodeMessage badTweetIds
  assertLeft "cacheCheckRequest.tweetIds element type" r1

  let badResults = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.cacheCheckResponse
        , requestId: unsafeToForeign "r-bad-results"
        , timestamp: unsafeToForeign (2.0 :: Number)
        , results: unsafeToForeign (Object.fromHomogeneous
            { good: unsafeToForeign true
            , bad: unsafeToForeign "false"
            })
        }
  let r2 = Types.decodeMessage badResults
  assertLeft "cacheCheckResponse.results value type" r2

testObjectBoundaryValidation :: Effect Unit
testObjectBoundaryValidation = do
  Console.log "  [Object Boundary Validation]"

  let topLevelArray = unsafeToForeign [ unsafeToForeign "not-an-object" ]
  assertLeft "top-level message must reject array" (Types.decodeMessage topLevelArray)

  let quotedTweetArray = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.evaluateRequest
        , requestId: unsafeToForeign "r-quoted-array"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , tweetId: unsafeToForeign "tw-array"
        , textContent: unsafeToForeign "hello"
        , quotedTweet: unsafeToForeign [ unsafeToForeign "bad" ]
        }
  assertLeft "quotedTweet must reject array" (Types.decodeMessage quotedTweetArray)

  let currentConfigArray = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.sessionStatusResponse
        , requestId: unsafeToForeign "r-status-array"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , initialized: unsafeToForeign true
        , isMultimodal: unsafeToForeign false
        , currentConfig: unsafeToForeign [ unsafeToForeign "bad" ]
        }
  assertLeft "currentConfig must reject array" (Types.decodeMessage currentConfigArray)

  let cacheAsArray = unsafeToForeign $ Object.fromHomogeneous
        { "tweet-filter-cache": unsafeToForeign [ unsafeToForeign "bad" ]
        , "tweet-filter-cache-order": unsafeToForeign [ unsafeToForeign "ok" ]
        }
  assertLeft "cache object must reject array" (CacheManager.decodeStorageStateE cacheAsArray)

testCacheDecodeValidation :: Effect Unit
testCacheDecodeValidation = do
  Console.log "  [Cache Decode Validation]"

  let badCacheValue = unsafeToForeign $ Object.fromHomogeneous
        { "tweet-filter-cache": unsafeToForeign (Object.fromHomogeneous
            { ok: unsafeToForeign true
            , bad: unsafeToForeign "false"
            })
        , "tweet-filter-cache-order": unsafeToForeign [ unsafeToForeign "ok" ]
        }
  assertLeft "cache value must be boolean" (CacheManager.decodeStorageStateE badCacheValue)

  let badOrderValue = unsafeToForeign $ Object.fromHomogeneous
        { "tweet-filter-cache": unsafeToForeign (Object.fromHomogeneous
            { ok: unsafeToForeign true
            })
        , "tweet-filter-cache-order": unsafeToForeign [ unsafeToForeign "ok", unsafeToForeign (1 :: Int) ]
        }
  assertLeft "cache order must be string array" (CacheManager.decodeStorageStateE badOrderValue)

testOutputLanguageStrictValidation :: Effect Unit
testOutputLanguageStrictValidation = do
  Console.log "  [Output Language Strict Validation]"

  let badInitLang = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.initRequest
        , requestId: unsafeToForeign "r-lang-1"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , config: unsafeToForeign (Object.fromHomogeneous
            { prompt: unsafeToForeign "x"
            , outputLanguage: unsafeToForeign "fr"
            })
        }
  let r1 = Types.decodeMessage badInitLang
  assertLeft "initRequest invalid outputLanguage" r1

  let badReinitLang = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.reinitRequest
        , requestId: unsafeToForeign "r-lang-2"
        , timestamp: unsafeToForeign (2.0 :: Number)
        , config: unsafeToForeign (Object.fromHomogeneous
            { prompt: unsafeToForeign "x"
            , outputLanguage: unsafeToForeign "de"
            })
        }
  let r2 = Types.decodeMessage badReinitLang
  assertLeft "reinitRequest invalid outputLanguage" r2

testStorageStrictOutputLanguage :: Effect Unit
testStorageStrictOutputLanguage = do
  Console.log "  [Storage Output Language Strict Validation]"
  case Storage.decodeOutputLanguage (unsafeToForeign "en") of
    Right En -> assert "storage outputLanguage en" true
    _ -> failWith "storage outputLanguage en"
  assertLeft "storage outputLanguage invalid" (Storage.decodeOutputLanguage (unsafeToForeign "fr"))

testSessionTypeParsing :: Effect Unit
testSessionTypeParsing = do
  Console.log "  [Session Type Parsing]"
  assert "sessionType multimodal" $ sessionTypeFromString "multimodal" == Just Multimodal
  assert "sessionType text-only" $ sessionTypeFromString "text-only" == Just TextOnly
  assert "sessionType text_only alias" $ sessionTypeFromString " text_only " == Just TextOnly
  assert "sessionType text alias" $ sessionTypeFromString "TEXT" == Just TextOnly
  assert "sessionType invalid" $ sessionTypeFromString "image-only" == Nothing

testInitResponseSessionTypeStrict :: Effect Unit
testInitResponseSessionTypeStrict = do
  Console.log "  [InitResponse SessionType Strict Validation]"
  let badSessionType = unsafeToForeign $ Object.fromHomogeneous
        { "type": unsafeToForeign C.initResponse
        , requestId: unsafeToForeign "r-init-bad-session-type"
        , timestamp: unsafeToForeign (1.0 :: Number)
        , success: unsafeToForeign true
        , sessionStatus: unsafeToForeign (Object.fromHomogeneous
            { isMultimodal: unsafeToForeign true
            , sessionType: unsafeToForeign "image-only"
            })
        , error: unsafeToForeign ""
        }
  assertLeft "initResponse invalid sessionType should fail" (Types.decodeMessage badSessionType)

testAvailabilityParsing :: Effect Unit
testAvailabilityParsing = do
  Console.log "  [Availability Parsing]"
  assert "availability trim + lower available" $ parseAvailability "  Available  " == Available
  assert "availability trim + lower downloading" $ parseAvailability " DOWNLOADING " == Downloading
  assert "availability unknown normalized token" $ parseAvailability " Strange-State " == Unknown "strange-state"

testSenderTabDetection :: Effect Unit
testSenderTabDetection = do
  Console.log "  [Sender Tab Detection]"
  let withTab = unsafeToForeign $ Object.fromHomogeneous
        { tab: unsafeToForeign (Object.fromHomogeneous { id: unsafeToForeign (1 :: Int) })
        }
  assert "sender with tab object" $ OffscreenMain.hasSenderTab withTab == Just true

  let withNullTab = unsafeToForeign $ Object.fromHomogeneous
        { tab: unsafeToForeign (toNullable (Nothing :: Maybe Int)) }
  assert "sender with null/undefined tab is not content script" $ OffscreenMain.hasSenderTab withNullTab == Just false

  let withoutTab = unsafeToForeign $ Object.fromHomogeneous
        { frameId: unsafeToForeign (0 :: Int)
        }
  assert "sender without tab" $ OffscreenMain.hasSenderTab withoutTab == Just false

  let malformedSender = unsafeToForeign [ unsafeToForeign "bad" ]
  assert "malformed sender rejected" $ OffscreenMain.hasSenderTab malformedSender == Nothing

testFilteringTransition :: Effect Unit
testFilteringTransition = do
  Console.log "  [Filtering Transition]"

  let disabled = { enabled: false, prompt: "x", showStatistics: false, outputLanguage: En }
  let enabledA = { enabled: true, prompt: "a", showStatistics: false, outputLanguage: En }
  let enabledB = { enabled: true, prompt: "b", showStatistics: false, outputLanguage: En }
  let enabledSameRuntimeDiffStats = { enabled: true, prompt: "a", showStatistics: true, outputLanguage: En }

  assert "disabled -> disabled = NoTransition" $
    ContentMain.decideTransition disabled disabled == ContentMain.NoTransition
  assert "enabled -> disabled = DisableAction" $
    ContentMain.decideTransition enabledA disabled == ContentMain.DisableAction
  assert "disabled -> enabled = EnableAction" $
    ContentMain.decideTransition disabled enabledA == ContentMain.EnableAction
  assert "enabled runtime change = ReconfigureAction" $
    ContentMain.decideTransition enabledA enabledB == ContentMain.ReconfigureAction
  assert "enabled stats-only change = NoTransition" $
    ContentMain.decideTransition enabledA enabledSameRuntimeDiffStats == ContentMain.NoTransition

testParseShowResponse :: Effect Unit
testParseShowResponse = do
  Console.log "  [Parse Show Response]"
  assert "parse last show=false" $
    EvalService.parseShowResponse "example {\"show\": true} final {\"show\": false}" == false
  assert "parse strict json show=true" $
    EvalService.parseShowResponse "{\"show\": true}" == true
  assert "reject true with identifier suffix" $
    EvalService.parseShowResponse "{\"show\": truex}" == true
  assert "reject false with identifier suffix" $
    EvalService.parseShowResponse "{\"show\": false_value}" == true

testSessionCreationPlanning :: Effect Unit
testSessionCreationPlanning = do
  Console.log "  [Session Creation Planning]"
  assert "prefer multimodal when available" $
    OptionsMain.planSessionCreation Available Available == OptionsMain.CreateMultimodal
  assert "fallback to text-only when multimodal unavailable" $
    OptionsMain.planSessionCreation Unavailable Available == OptionsMain.CreateTextOnly
  assert "no session plan when both unavailable" $
    OptionsMain.planSessionCreation Unavailable Unavailable == OptionsMain.CannotCreateSession
  assert "multimodal display status from available APIs" $
    OptionsMain.sessionTypeFromAvailableApis Available Unavailable == Just Multimodal
  assert "text-only display status from available APIs" $
    OptionsMain.sessionTypeFromAvailableApis Unavailable Available == Just TextOnly
  assert "error message includes both availability states" $
    OptionsMain.sessionCreationErrorMessage Unavailable Downloading
      == "No creatable model. multimodal=unavailable, text=downloading"

testSessionInitializeResultModel :: Effect Unit
testSessionInitializeResultModel = do
  Console.log "  [Session Initialize Result Model]"
  let success = SessionManager.InitializeSucceeded TextOnly
  let unavailable = SessionManager.InitializeFailed SessionManager.TextModelUnavailable
  let createFailed = SessionManager.InitializeFailed SessionManager.TextSessionCreateFailed

  assert "success marked successful" $
    SessionManager.isInitializeSuccess success
  assert "failure marked unsuccessful" $
    not (SessionManager.isInitializeSuccess unavailable)
  assert "success has no error message" $
    SessionManager.initializeErrorMessage success == Nothing
  assert "unavailable has specific message" $
    SessionManager.initializeErrorMessage unavailable == Just "Text model is unavailable or downloading"
  assert "create failure has specific message" $
    SessionManager.initializeErrorMessage createFailed == Just "Failed to create text-only session"

testEvaluateOutcomeDecode :: Effect Unit
testEvaluateOutcomeDecode = do
  Console.log "  [Evaluate Outcome Decode]"
  case TweetFilter.evaluateOutcomeFromDecode (Right (Types.EvaluateResponse
    { requestId: "r"
    , timestamp: 1.0
    , tweetId: "tw"
    , shouldShow: false
    , cacheHit: true
    , evaluationTime: 12.0
    , error: Nothing
    })) of
    TweetFilter.Evaluated r -> do
      assert "evaluated shouldShow" $ r.shouldShow == false
      assert "evaluated cacheHit" $ r.cacheHit == true
      assert "evaluated evaluationTime" $ r.evaluationTime == 12.0
    _ -> failWith "expected Evaluated"

  case TweetFilter.evaluateOutcomeFromDecode (Right (Types.ErrorMessage
    { requestId: "r"
    , timestamp: 1.0
    , error: "boom"
    , originalRequestId: Nothing
    })) of
    TweetFilter.ServiceError err -> assert "service error payload" $ err == "boom"
    _ -> failWith "expected ServiceError"

  case TweetFilter.evaluateOutcomeFromDecode (Left "decode-fail") of
    TweetFilter.DecodeError err -> assert "decode error payload" $ err == "decode-fail"
    _ -> failWith "expected DecodeError"

  case TweetFilter.evaluateOutcomeFromDecode (Right (Types.SessionStatusRequest
    { requestId: "r"
    , timestamp: 1.0
    })) of
    TweetFilter.UnexpectedResponse msgType ->
      assert "unexpected response type payload" $ msgType == C.sessionStatusRequest
    _ -> failWith "expected UnexpectedResponse"

testRepostInfoModel :: Effect Unit
testRepostInfoModel = do
  Console.log "  [RepostInfo Model]"
  assert "not repost -> false" $ isRepost NotRepost == false
  assert "not repost -> no username" $ repostedBy NotRepost == Nothing
  let repostedWithUser = Reposted (Just "@alice")
  assert "reposted -> true" $ isRepost repostedWithUser == true
  assert "reposted -> username kept" $ repostedBy repostedWithUser == Just "@alice"
  assert "reposted without user allowed" $ repostedBy (Reposted Nothing) == Nothing

-- Helpers

assert :: String -> Boolean -> Effect Unit
assert label true = Console.log ("    PASS: " <> label)
assert label false = do
  Console.error ("    FAIL: " <> label)
  Exception.throw ("Test failed: " <> label)

assertLeft :: forall a. String -> Either String a -> Effect Unit
assertLeft label (Left _) = Console.log ("    PASS: " <> label <> " -> Left")
assertLeft label (Right _) = do
  Console.error ("    FAIL: " <> label <> " should be Left")
  Exception.throw ("Test failed: " <> label)

failWith :: String -> Effect Unit
failWith label = do
  Console.error ("    FAIL: " <> label)
  Exception.throw ("Test failed: " <> label)
