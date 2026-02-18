module Shared.GeminiModelOptions where

import Prelude

import Foreign (Foreign, unsafeToForeign)
import Foreign.Object as Object

data ModelInput
  = TextInput
  | ImageInput

modelInputsText :: Array ModelInput
modelInputsText = [ TextInput ]

modelInputsMultimodal :: Array ModelInput
modelInputsMultimodal = [ TextInput, ImageInput ]

makeCreateOptions :: Array ModelInput -> String -> Foreign
makeCreateOptions inputTypes lang =
  unsafeToForeign $ Object.fromHomogeneous
    { temperature: unsafeToForeign (0.1 :: Number)
    , topK: unsafeToForeign (1 :: Int)
    , expectedInputs: unsafeToForeign (map (unsafeToForeign <<< modelInputToPayload) inputTypes)
    , expectedOutputs: makeExpectedOutputs lang
    }

makeAvailabilityOptions :: Array ModelInput -> String -> Foreign
makeAvailabilityOptions inputTypes lang =
  unsafeToForeign $ Object.fromHomogeneous
    { expectedInputs: unsafeToForeign (map (unsafeToForeign <<< modelInputToPayload) inputTypes)
    , expectedOutputs: makeExpectedOutputs lang
    }

makeExpectedOutputs :: String -> Foreign
makeExpectedOutputs lang =
  unsafeToForeign [ unsafeToForeign { "type": "text", languages: [ lang ] } ]

modelInputToPayload :: ModelInput -> { "type" :: String }
modelInputToPayload TextInput = { "type": "text" }
modelInputToPayload ImageInput = { "type": "image" }
