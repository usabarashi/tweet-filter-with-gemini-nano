module FFI.Chrome.Storage where

import Prelude

import Promise (Promise)
import Promise.Aff (toAffE)
import Effect (Effect)
import Effect.Aff (Aff)
import Foreign (Foreign)

-- Sync storage

foreign import syncGetImpl :: Array String -> Effect (Promise Foreign)

syncGet :: Array String -> Aff Foreign
syncGet keys = toAffE (syncGetImpl keys)

foreign import syncSetImpl :: Foreign -> Effect (Promise Unit)

syncSet :: Foreign -> Aff Unit
syncSet data_ = toAffE (syncSetImpl data_)

-- Session storage

foreign import sessionGetImpl :: Array String -> Effect (Promise Foreign)

sessionGet :: Array String -> Aff Foreign
sessionGet keys = toAffE (sessionGetImpl keys)

foreign import sessionSetImpl :: Foreign -> Effect (Promise Unit)

sessionSet :: Foreign -> Aff Unit
sessionSet data_ = toAffE (sessionSetImpl data_)

foreign import sessionRemoveImpl :: Array String -> Effect (Promise Unit)

sessionRemove :: Array String -> Aff Unit
sessionRemove keys = toAffE (sessionRemoveImpl keys)

-- Storage change listener

foreign import onChanged
  :: (Foreign -> String -> Effect Unit) -> Effect (Effect Unit)
