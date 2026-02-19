module Shared.EffectUtils where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Traversable (for_)
import Effect (Effect)
import Effect.Ref as Ref

takeMaybeRef :: forall a. Ref.Ref (Maybe a) -> Effect (Maybe a)
takeMaybeRef ref =
  Ref.modify' (\current -> { state: Nothing, value: current }) ref

clearMaybeRef :: forall a. Ref.Ref (Maybe a) -> (a -> Effect Unit) -> Effect Unit
clearMaybeRef ref clearFn = do
  current <- takeMaybeRef ref
  for_ current clearFn

runCleanupRef :: Ref.Ref (Effect Unit) -> Effect Unit
runCleanupRef ref = do
  cleanup <- Ref.modify' (\current -> { state: pure unit, value: current }) ref
  cleanup
