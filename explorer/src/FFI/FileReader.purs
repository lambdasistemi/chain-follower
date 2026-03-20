-- | FFI for reading uploaded files as text.
module FFI.FileReader
  ( readFile
  , getFilesFromEvent
  , fileName
  ) where

import Control.Promise (Promise, toAffE)
import Effect (Effect)
import Effect.Aff (Aff)
import Web.Event.Event (Event)
import Web.File.File (File)

foreign import readFileAsText
  :: File -> Effect (Promise String)

foreign import getFilesFromEvent
  :: Event -> Effect (Array File)

foreign import fileName :: File -> String

-- | Read a File as text, as an Aff.
readFile :: File -> Aff String
readFile f = toAffE (readFileAsText f)
