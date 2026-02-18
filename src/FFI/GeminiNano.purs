module FFI.GeminiNano where

import Prelude

import Promise (Promise)
import Promise.Aff (toAffE)
import Data.Nullable (Nullable)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign (Foreign)

-- | Opaque type representing a LanguageModel session
foreign import data LanguageModelSession :: Type

-- | Opaque type for AbortSignal (passed through to JS)
foreign import data AbortSignal :: Type

-- Availability check

foreign import checkAvailabilityImpl :: Foreign -> Effect (Promise String)

checkAvailability :: Foreign -> Aff String
checkAvailability opts = toAffE (checkAvailabilityImpl opts)

-- Session creation

foreign import createSessionImpl :: Foreign -> Effect (Promise LanguageModelSession)

createSession :: Foreign -> Aff LanguageModelSession
createSession opts = toAffE (createSessionImpl opts)

-- Model params

foreign import getParamsImpl :: Effect (Promise Foreign)

getParams :: Aff Foreign
getParams = toAffE getParamsImpl

-- Prompting

foreign import promptTextImpl
  :: LanguageModelSession -> String -> Nullable AbortSignal -> Effect (Promise String)

promptText :: LanguageModelSession -> String -> Nullable AbortSignal -> Aff String
promptText session text signal = toAffE (promptTextImpl session text signal)

foreign import promptMultimodalImpl
  :: LanguageModelSession -> Foreign -> Nullable AbortSignal -> Effect (Promise String)

promptMultimodal :: LanguageModelSession -> Foreign -> Nullable AbortSignal -> Aff String
promptMultimodal session messages signal = toAffE (promptMultimodalImpl session messages signal)

-- Session management

foreign import cloneSessionImpl
  :: LanguageModelSession -> Nullable AbortSignal -> Effect (Promise LanguageModelSession)

cloneSession :: LanguageModelSession -> Nullable AbortSignal -> Aff LanguageModelSession
cloneSession session signal = toAffE (cloneSessionImpl session signal)

foreign import destroySessionImpl :: LanguageModelSession -> Effect (Promise Unit)

destroySession :: LanguageModelSession -> Aff Unit
destroySession session = toAffE (destroySessionImpl session)

-- Session properties

foreign import getInputUsage :: LanguageModelSession -> Effect Int
foreign import getInputQuota :: LanguageModelSession -> Effect Int

-- Session creation with download progress monitor

foreign import createSessionWithMonitorImpl
  :: Foreign -> (Number -> Effect Unit) -> Effect (Promise LanguageModelSession)

createSessionWithMonitor :: Foreign -> (Number -> Effect Unit) -> Aff LanguageModelSession
createSessionWithMonitor opts onProgress = toAffE (createSessionWithMonitorImpl opts onProgress)

-- API availability guard

foreign import isLanguageModelAvailable :: Effect Boolean
