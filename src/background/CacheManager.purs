module Background.CacheManager where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldM)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Data.Traversable (traverse)
import Effect.Aff (Aff, bracket, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import FFI.Chrome.Storage as ChromeStorage
import Foreign (Foreign, unsafeFromForeign, unsafeToForeign, readBoolean, readString, typeOf, isArray, isNull, isUndefined)
import Foreign.Object (Object)
import Foreign.Object as Object
import Shared.Logger as Logger

-- Storage keys
cacheKey :: String
cacheKey = "tweet-filter-cache"

orderKey :: String
orderKey = "tweet-filter-cache-order"

maxCacheSize :: Int
maxCacheSize = 500

-- | Cache manager state
type CacheState =
  { lock :: AVar Unit
  , logger :: Ref Logger.LoggerState
  }

data CacheError
  = DecodeError String
  | StorageError String

-- | Create a new cache manager
new :: Ref Logger.LoggerState -> Aff CacheState
new loggerRef = do
  lock <- AVar.new unit
  pure { lock, logger: loggerRef }

-- | Acquire lock, run action, release lock (exception-safe via bracket)
withLock :: CacheState -> Aff ~> Aff
withLock state action =
  bracket
    (AVar.take state.lock)
    (\_ -> AVar.put unit state.lock)
    (\_ -> action)

-- | Get a cached evaluation result, updating LRU order.
-- | Degrades to cache-miss on storage corruption.
get :: CacheState -> String -> Aff (Maybe Boolean)
get state tweetId = withLock state do
  stateResult <- loadStorageState [ cacheKey, orderKey ]
  case stateResult of
    Left err -> do
      handleCacheError state ("read(" <> tweetId <> ")") err
      pure Nothing
    Right { cache, order } ->
      case Object.lookup tweetId cache of
        Nothing -> pure Nothing
        Just val -> do
          let newOrder = Array.snoc (Array.filter (_ /= tweetId) order) tweetId
          writeResult <- try $ ChromeStorage.sessionSet (unsafeToForeign $ Object.singleton orderKey (unsafeToForeign newOrder))
          case writeResult of
            Left err -> do
              handleCacheError state ("promote(" <> tweetId <> ")") (StorageError (show err))
              pure (Just val)
            Right _ -> pure (Just val)

-- | Set a cached evaluation result.
-- | Warns on storage corruption instead of crashing.
set :: CacheState -> String -> Boolean -> Aff Unit
set state tweetId shouldShow = withLock state do
  stateResult <- loadStorageState [ cacheKey, orderKey ]
  case stateResult of
    Left err ->
      handleCacheError state ("write(" <> tweetId <> ")") err
    Right { cache, order } -> do
      let
        isNew = not (Object.member tweetId cache)
        evicted = if Object.size cache >= maxCacheSize && isNew
          then evictLRU cache order
          else { cache, order }
        newCache = Object.insert tweetId shouldShow evicted.cache
        newOrder = Array.snoc (Array.filter (_ /= tweetId) evicted.order) tweetId
      let payload = Object.fromFoldable
            [ Tuple cacheKey (unsafeToForeign newCache)
            , Tuple orderKey (unsafeToForeign newOrder)
            ]
      writeResult <- try $ ChromeStorage.sessionSet (unsafeToForeign payload)
      case writeResult of
        Left err ->
          handleCacheError state ("write(" <> tweetId <> ")") (StorageError (show err))
        Right _ ->
          liftEffect $ Logger.log state.logger ("[CacheManager] Cached tweet " <> tweetId <> ": " <> show shouldShow)

-- | Check if a tweet is cached (locked for consistency).
-- | Returns false on storage corruption.
has :: CacheState -> String -> Aff Boolean
has state tweetId = withLock state do
  stateResult <- loadStorageState [ cacheKey ]
  case stateResult of
    Left err -> do
      handleCacheError state ("has(" <> tweetId <> ")") err
      pure false
    Right { cache } ->
      pure (Object.member tweetId cache)

-- | Get batch of cached results (locked for consistency).
-- | Returns empty results on storage corruption.
getBatch :: CacheState -> Array String -> Aff (Object Boolean)
getBatch state tweetIds = withLock state do
  stateResult <- loadStorageState [ cacheKey ]
  case stateResult of
    Left err -> do
      handleCacheError state "getBatch" err
      pure Object.empty
    Right { cache } ->
      pure $ Object.fromFoldable $ Array.mapMaybe
        (\id -> case Object.lookup id cache of
          Just val -> Just (Tuple id val)
          Nothing -> Nothing
        )
        tweetIds

-- | Clear the cache
clear :: CacheState -> Aff Unit
clear state = withLock state do
  ChromeStorage.sessionRemove [ cacheKey, orderKey ]
  liftEffect $ Logger.log state.logger "[CacheManager] Cache cleared"

-- Helpers

loadStorageState :: Array String -> Aff (Either CacheError { cache :: Object Boolean, order :: Array String })
loadStorageState keys = do
  readResult <- try $ ChromeStorage.sessionGet keys
  pure $ case readResult of
    Left err -> Left (StorageError (show err))
    Right raw -> case decodeStorageStateE raw of
      Left decodeErr -> Left (DecodeError decodeErr)
      Right state -> Right state

decodeStorageStateE :: Foreign -> Either String { cache :: Object Boolean, order :: Array String }
decodeStorageStateE raw = do
  obj <- asObject "session storage payload" raw
  cache <- decodeCache obj
  order <- decodeOrder obj
  pure { cache, order }

decodeCache :: Object Foreign -> Either String (Object Boolean)
decodeCache obj = case Object.lookup cacheKey obj of
  Nothing -> Right Object.empty
  Just value -> do
    rawCache <- asObject cacheKey value
    foldM insertBool Object.empty (Object.toUnfoldable rawCache :: Array (Tuple String Foreign))
  where
  insertBool acc (Tuple key value) = do
    boolValue <- decodeBoolean (cacheKey <> "." <> key) value
    Right (Object.insert key boolValue acc)

decodeOrder :: Object Foreign -> Either String (Array String)
decodeOrder obj = case Object.lookup orderKey obj of
  Nothing -> Right []
  Just value ->
    if not (isArray value) then
      Left (orderKey <> " expected array, found " <> typeOf value)
    else
      traverse (decodeString orderKey) ((unsafeFromForeign value) :: Array Foreign)

asObject :: String -> Foreign -> Either String (Object Foreign)
asObject label value
  | typeOf value /= "object" || isArray value || isNull value || isUndefined value =
      Left (label <> " expected object, found " <> typeOf value)
  | otherwise =
      Right ((unsafeFromForeign value) :: Object Foreign)

decodeBoolean :: String -> Foreign -> Either String Boolean
decodeBoolean label value = case runExcept (readBoolean value) of
  Left _ -> Left (label <> " expected Boolean, found " <> typeOf value)
  Right b -> Right b

decodeString :: String -> Foreign -> Either String String
decodeString label value = case runExcept (readString value) of
  Left _ -> Left (label <> " expected String, found " <> typeOf value)
  Right s -> Right s

evictLRU :: Object Boolean -> Array String -> { cache :: Object Boolean, order :: Array String }
evictLRU cache order = case Array.uncons order of
  Nothing ->
    -- Fallback: remove lexicographically first key for deterministic behavior.
    case Array.head (Array.sort (Object.keys cache)) of
      Nothing -> { cache, order }
      Just k -> { cache: Object.delete k cache, order }
  Just { head: lruKey, tail: rest } ->
    { cache: Object.delete lruKey cache, order: rest }

resetCorruptCache :: CacheState -> String -> Aff Unit
resetCorruptCache state op = do
  _ <- try $ ChromeStorage.sessionRemove [ cacheKey, orderKey ]
  liftEffect $ Logger.warn state.logger ("[CacheManager] Reset corrupted cache state during " <> op)

handleCacheError :: CacheState -> String -> CacheError -> Aff Unit
handleCacheError state op err = case err of
  DecodeError message -> do
    resetCorruptCache state op
    liftEffect $ Logger.warn state.logger ("[CacheManager] Decode error during " <> op <> ": " <> message)
  StorageError message ->
    liftEffect $ Logger.warn state.logger ("[CacheManager] Storage error during " <> op <> ": " <> message)
