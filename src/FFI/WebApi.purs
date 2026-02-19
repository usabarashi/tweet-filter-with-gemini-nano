module FFI.WebApi where

import Prelude

import Promise (Promise)
import Promise.Aff (toAffE)
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign (Foreign)

-- | Opaque types for DOM and Web API objects

foreign import data Element :: Type
foreign import data Blob :: Type
foreign import data Event :: Type
foreign import data MutationObserverHandle :: Type

-- | Safely coerce a raw DOM Node to Element if it is an HTMLElement.
-- | Use this to filter MutationObserver addedNodes.
asElement :: Foreign -> Effect (Maybe Element)
asElement node = map toMaybe (asElementImpl node)

foreign import asElementImpl :: Foreign -> Effect (Nullable Element)

-- Dataset operations

foreign import getDataset :: Element -> String -> Effect (Nullable String)
foreign import setDataset :: Element -> String -> String -> Effect Unit
foreign import removeDataset :: Element -> String -> Effect Unit

-- Element queries

foreign import matches :: Element -> String -> Effect Boolean
foreign import isConnected :: Element -> Effect Boolean

-- Crypto

foreign import randomUUID :: Effect String

-- Time

foreign import dateNow :: Effect Number

foreign import setTimeoutImpl :: Effect Unit -> Int -> Effect Int

setTimeout :: Int -> Effect Unit -> Effect Int
setTimeout ms cb = setTimeoutImpl cb ms

foreign import clearTimeoutImpl :: Int -> Effect Unit

clearTimeout :: Int -> Effect Unit
clearTimeout = clearTimeoutImpl

foreign import setIntervalImpl :: Effect Unit -> Int -> Effect Int

setInterval :: Int -> Effect Unit -> Effect Int
setInterval ms cb = setIntervalImpl cb ms

foreign import clearIntervalImpl :: Int -> Effect Unit

clearInterval :: Int -> Effect Unit
clearInterval = clearIntervalImpl

-- Fetch

foreign import fetchBlobImpl :: String -> Effect (Promise Blob)

fetchBlob :: String -> Aff Blob
fetchBlob url = toAffE (fetchBlobImpl url)

-- Location

foreign import getLocationHref :: Effect String
foreign import addPopstateListener :: Effect Unit -> Effect (Effect Unit)

-- DOM queries

foreign import querySelectorImpl :: Element -> String -> Effect (Nullable Element)

querySelector :: Element -> String -> Effect (Nullable Element)
querySelector = querySelectorImpl

foreign import querySelectorAllImpl :: Element -> String -> Effect (Array Element)

querySelectorAll :: Element -> String -> Effect (Array Element)
querySelectorAll = querySelectorAllImpl

-- DOM content

foreign import getTextContent :: Element -> Effect String
foreign import getInnerText :: Element -> Effect String
foreign import setTextContent :: Element -> String -> Effect Unit
foreign import setInnerHTML :: Element -> String -> Effect Unit

-- DOM creation

foreign import createElementImpl :: String -> Effect Element

createElement :: String -> Effect Element
createElement = createElementImpl

-- DOM manipulation

foreign import prependChild :: Element -> Element -> Effect Unit
foreign import setClassName :: Element -> String -> Effect Unit
foreign import addClickListener :: Element -> (Event -> Effect Unit) -> Effect (Effect Unit)
foreign import removeElement :: Element -> Effect Unit
foreign import stopPropagation :: Event -> Effect Unit
foreign import preventDefault :: Event -> Effect Unit

-- DOM attributes

foreign import getAttributeImpl :: Element -> String -> Effect (Nullable String)

getAttribute :: Element -> String -> Effect (Nullable String)
getAttribute = getAttributeImpl

foreign import setAttributeImpl :: Element -> String -> String -> Effect Unit

setAttribute :: Element -> String -> String -> Effect Unit
setAttribute = setAttributeImpl

foreign import removeAttributeImpl :: Element -> String -> Effect Unit

removeAttribute :: Element -> String -> Effect Unit
removeAttribute = removeAttributeImpl

foreign import hasAttributeImpl :: Element -> String -> Effect Boolean

hasAttribute :: Element -> String -> Effect Boolean
hasAttribute = hasAttributeImpl

-- DOM traversal

foreign import getSrcImpl :: Element -> Effect String

getSrc :: Element -> Effect String
getSrc = getSrcImpl

foreign import getChildrenImpl :: Element -> Effect (Array Element)

getChildren :: Element -> Effect (Array Element)
getChildren = getChildrenImpl

foreign import getClosestImpl :: Element -> String -> Effect (Nullable Element)

getClosest :: Element -> String -> Effect (Nullable Element)
getClosest = getClosestImpl

-- Events

foreign import addEventListenerImpl :: Element -> String -> (Event -> Effect Unit) -> Effect (Effect Unit)

addEventListener :: Element -> String -> (Event -> Effect Unit) -> Effect (Effect Unit)
addEventListener = addEventListenerImpl

-- Service Worker

foreign import skipWaiting :: Effect Unit
foreign import addServiceWorkerEventListener :: String -> Effect Unit -> Effect Unit

-- Document-level queries

foreign import getDocumentBody :: Effect Element

foreign import documentQuerySelectorImpl :: String -> Effect (Nullable Element)

documentQuerySelector :: String -> Effect (Nullable Element)
documentQuerySelector = documentQuerySelectorImpl

-- DOM traversal (additional)

foreign import containsImpl :: Element -> Element -> Effect Boolean

contains :: Element -> Element -> Effect Boolean
contains = containsImpl

foreign import getParentElementImpl :: Element -> Effect (Nullable Element)

getParentElement :: Element -> Effect (Nullable Element)
getParentElement = getParentElementImpl

-- MutationObserver
-- | The callback receives raw Nodes (as Foreign) since not all added nodes
-- | are Elements. Use `asElement` to safely filter and coerce.

foreign import newMutationObserverImpl :: (Array Foreign -> Effect Unit) -> Effect MutationObserverHandle

newMutationObserver :: (Array Foreign -> Effect Unit) -> Effect MutationObserverHandle
newMutationObserver = newMutationObserverImpl

foreign import observeImpl :: MutationObserverHandle -> Element -> { childList :: Boolean, subtree :: Boolean } -> Effect Unit

observeMutations :: MutationObserverHandle -> Element -> { childList :: Boolean, subtree :: Boolean } -> Effect Unit
observeMutations = observeImpl

foreign import disconnectImpl :: MutationObserverHandle -> Effect Unit

disconnectObserver :: MutationObserverHandle -> Effect Unit
disconnectObserver = disconnectImpl

-- String helpers

foreign import normalizeImageUrlImpl :: String -> String

normalizeImageUrl :: String -> String
normalizeImageUrl = normalizeImageUrlImpl

foreign import matchStatusIdImpl :: String -> Nullable String

matchStatusId :: String -> Nullable String
matchStatusId = matchStatusIdImpl

foreign import generateFallbackId :: Effect String

foreign import stringIncludesImpl :: String -> String -> Boolean

stringIncludes :: String -> String -> Boolean
stringIncludes = stringIncludesImpl

-- Form element properties

foreign import getCheckedImpl :: Element -> Effect Boolean

getChecked :: Element -> Effect Boolean
getChecked = getCheckedImpl

foreign import setCheckedImpl :: Element -> Boolean -> Effect Unit

setChecked :: Element -> Boolean -> Effect Unit
setChecked = setCheckedImpl

foreign import getValueImpl :: Element -> Effect String

getValue :: Element -> Effect String
getValue = getValueImpl

foreign import setValueImpl :: Element -> String -> Effect Unit

setValue :: Element -> String -> Effect Unit
setValue = setValueImpl

foreign import setDisabledImpl :: Element -> Boolean -> Effect Unit

setDisabled :: Element -> Boolean -> Effect Unit
setDisabled = setDisabledImpl

-- Clipboard

foreign import clipboardWriteTextImpl :: String -> Effect (Promise Unit)

clipboardWriteText :: String -> Aff Unit
clipboardWriteText text = toAffE (clipboardWriteTextImpl text)

-- Document-level querySelectorAll

foreign import documentQuerySelectorAllImpl :: String -> Effect (Array Element)

documentQuerySelectorAll :: String -> Effect (Array Element)
documentQuerySelectorAll = documentQuerySelectorAllImpl

-- CSS class manipulation

foreign import addClassImpl :: Element -> String -> Effect Unit

addClass :: Element -> String -> Effect Unit
addClass = addClassImpl

foreign import removeClassImpl :: Element -> String -> Effect Unit

removeClass :: Element -> String -> Effect Unit
removeClass = removeClassImpl

-- beforeunload listener

foreign import addBeforeUnloadListener :: Effect Unit -> Effect (Effect Unit)
