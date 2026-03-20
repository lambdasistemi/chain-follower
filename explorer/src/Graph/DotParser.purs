-- | Parse calligraphy DOT output into Cytoscape.js
-- | element arrays.
module Graph.DotParser
  ( parseDot
  ) where

import Foreign (Foreign)
import Effect (Effect)

-- | Parse a DOT string (from calligraphy) into a
-- | Cytoscape.js elements array. Returns a Foreign
-- | value suitable for passing to 'initCytoscape'.
foreign import parseDot :: String -> Effect Foreign
