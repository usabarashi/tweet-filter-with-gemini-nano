module FFI.Chrome.Runtime where

import Prelude

import Promise (Promise)
import Promise.Aff (toAffE)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign (Foreign)

-- | Check if extension context is valid (chrome.runtime.id exists)
foreign import isContextValid :: Effect Boolean

-- | Send a message via chrome.runtime.sendMessage
foreign import sendMessageImpl :: Foreign -> Effect (Promise Foreign)

sendMessage :: Foreign -> Aff Foreign
sendMessage msg = toAffE (sendMessageImpl msg)

-- | Register a message listener on chrome.runtime.onMessage.
-- | Handler returns true to indicate async sendResponse, false to ignore.
-- | handler args: message -> sender -> sendResponse -> Effect Boolean
foreign import addMessageListener
  :: (Foreign -> Foreign -> (Foreign -> Effect Unit) -> Effect Boolean)
  -> Effect Unit

-- | chrome.runtime.getContexts for checking offscreen documents
foreign import getContextsImpl :: Foreign -> Effect (Promise Foreign)

getContexts :: Foreign -> Aff Foreign
getContexts filter = toAffE (getContextsImpl filter)
