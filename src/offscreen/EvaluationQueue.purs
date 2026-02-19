module Offscreen.EvaluationQueue where

import Prelude

import Effect.Aff (Aff, bracket, try)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Ref (Ref)
import Effect.Ref as Ref

-- | A serialized queue that processes one request at a time.
-- | Implemented using an AVar mutex plus generation token.
-- | clear increments generation so pending waiters are dropped deterministically.
type Queue =
  { stateRef :: Ref QueueState
  }

type QueueState =
  { lock :: AVar Unit
  , generation :: Int
  }

data EnqueueResult a
  = Enqueued a
  | DroppedByClear

-- | Create a new evaluation queue
new :: Aff Queue
new = do
  lock <- AVar.new unit
  stateRef <- liftEffect $ Ref.new { lock, generation: 0 }
  pure { stateRef }

-- | Clear pending evaluations by incrementing generation and swapping the lock.
-- | In-flight action (if any) continues, but pending waiters return DroppedByClear.
clear :: Queue -> Aff Unit
clear queue = do
  newLock <- AVar.new unit
  liftEffect $ Ref.modify_ (\s -> { lock: newLock, generation: s.generation + 1 }) queue.stateRef

-- | Enqueue a request and wait for its result.
-- | Ensures only one evaluation runs at a time.
-- | If the queue was cleared while waiting, returns DroppedByClear.
enqueue :: forall a. Queue -> Aff a -> Aff (EnqueueResult a)
enqueue queue action = do
  snapshot <- liftEffect $ Ref.read queue.stateRef
  bracket
    (AVar.take snapshot.lock)
    (\_ -> void $ try $ AVar.put unit snapshot.lock)
    (\_ -> do
      current <- liftEffect $ Ref.read queue.stateRef
      if current.generation /= snapshot.generation then
        pure DroppedByClear
      else
        Enqueued <$> action
    )
