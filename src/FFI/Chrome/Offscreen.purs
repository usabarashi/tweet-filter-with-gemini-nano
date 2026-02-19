module FFI.Chrome.Offscreen where

import Prelude

import Promise (Promise)
import Promise.Aff (toAffE)
import Effect (Effect)
import Effect.Aff (Aff)

type CreateDocumentOptions =
  { url :: String
  , reasons :: Array String
  , justification :: String
  }

foreign import createDocumentImpl :: CreateDocumentOptions -> Effect (Promise Unit)

createDocument :: CreateDocumentOptions -> Aff Unit
createDocument opts = toAffE (createDocumentImpl opts)

foreign import closeDocumentImpl :: Effect (Promise Unit)

closeDocument :: Aff Unit
closeDocument = toAffE closeDocumentImpl
