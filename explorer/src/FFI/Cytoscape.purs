-- | FFI to Cytoscape.js for interactive graph rendering.
module FFI.Cytoscape
  ( initCytoscape
  , onNodeTap
  , onNodeDoubleTap
  , highlightNeighborhood
  , clearHighlight
  , fitToNode
  , fitAll
  , collapseNode
  , expandNode
  , collapseAll
  , expandAll
  ) where

import Prelude

import Effect (Effect)
import Foreign (Foreign)

-- | Initialize a Cytoscape.js instance in the given
-- | container element with the provided elements JSON.
foreign import initCytoscape
  :: String -> Foreign -> Effect Unit

-- | Register a callback for single-tap on a node.
-- | Receives the node ID and its data object.
foreign import onNodeTap
  :: (String -> Foreign -> Effect Unit)
  -> Effect Unit

-- | Register a callback for double-tap on a node.
-- | Receives the node ID.
foreign import onNodeDoubleTap
  :: (String -> Effect Unit) -> Effect Unit

-- | Highlight a node and its immediate neighborhood,
-- | dimming everything else.
foreign import highlightNeighborhood
  :: String -> Effect Unit

-- | Clear all highlight and dim styles.
foreign import clearHighlight :: Effect Unit

-- | Animate the viewport to fit a node and its
-- | neighborhood.
foreign import fitToNode :: String -> Effect Unit

-- | Fit the entire graph in the viewport.
foreign import fitAll :: Effect Unit

-- | Collapse a compound node (hide children).
foreign import collapseNode :: String -> Effect Unit

-- | Expand a compound node (show children).
foreign import expandNode :: String -> Effect Unit

-- | Collapse all compound nodes.
foreign import collapseAll :: Effect Unit

-- | Expand all compound nodes.
foreign import expandAll :: Effect Unit
