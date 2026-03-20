-- | Entry point for the call-graph explorer.
module Main
    ( main
    ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Foreign (Foreign)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

data Action
    = Initialize
    | LoadDot String
    | NodeTapped String Foreign
    | NodeDoubleTapped String
    | ZoomIn
    | ZoomOut
    | FitAll
    | CollapseAll
    | ExpandAll
    | ClearSelection

type State =
    { dotContent :: Maybe String
    , selectedNode :: Maybe String
    , selectedLabel :: Maybe String
    , selectedKind :: Maybe String
    }

component
    :: forall q i o m
     . H.Component q i o m
component =
    H.mkComponent
        { initialState: \_ ->
            { dotContent: Nothing
            , selectedNode: Nothing
            , selectedLabel: Nothing
            , selectedKind: Nothing
            }
        , render
        , eval:
            H.mkEval
                H.defaultEval
                    { handleAction = handleAction
                    , initialize = Just Initialize
                    }
        }

render :: forall m. State -> H.ComponentHTML Action () m
render state =
    HH.div
        [ HP.id "app" ]
        [ HH.div
            [ HP.id "toolbar" ]
            [ HH.button
                [ HE.onClick \_ -> ExpandAll ]
                [ HH.text "Expand All" ]
            , HH.button
                [ HE.onClick \_ -> CollapseAll ]
                [ HH.text "Collapse All" ]
            , HH.button
                [ HE.onClick \_ -> FitAll ]
                [ HH.text "Fit" ]
            , HH.button
                [ HE.onClick \_ -> ClearSelection ]
                [ HH.text "Clear" ]
            ]
        , HH.div [ HP.id "cy" ] []
        , HH.div
            [ HP.id "sidebar" ]
            [ case state.selectedLabel of
                Nothing ->
                    HH.p_
                        [ HH.text
                            "Click a node to inspect. \
                            \Double-click to \
                            \expand/collapse."
                        ]
                Just label ->
                    HH.div_
                        [ HH.h3_ [ HH.text label ]
                        , HH.p_
                            [ HH.text
                                ( "Kind: "
                                    <> show
                                        state.selectedKind
                                )
                            ]
                        ]
            ]
        ]

handleAction
    :: forall o m
     . Action
    -> H.HalogenM State Action () o m Unit
handleAction = case _ of
    Initialize -> pure unit
    LoadDot _dot -> pure unit
    NodeTapped nodeId _dat -> do
        H.modify_ _
            { selectedNode = Just nodeId
            , selectedLabel = Just nodeId
            }
    NodeDoubleTapped _nodeId -> pure unit
    ZoomIn -> pure unit
    ZoomOut -> pure unit
    FitAll -> pure unit
    CollapseAll -> pure unit
    ExpandAll -> pure unit
    ClearSelection ->
        H.modify_ _
            { selectedNode = Nothing
            , selectedLabel = Nothing
            , selectedKind = Nothing
            }

main :: Effect Unit
main =
    HA.runHalogenAff do
        body <- HA.awaitBody
        runUI component unit body
