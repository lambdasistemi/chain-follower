module Audit
    ( -- * Backend
      mkAuditRestoring
    , mkAuditFollowing

      -- * Columns
    , AuditCols (..)

      -- * Constants
    , threshold
    ) where

-- \|
-- Module      : Audit
-- Description : Audit backend — Cage-like pattern
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : Apache-2.0
--
-- A simplified audit trail that mimics the Cage follower
-- pattern:
--
-- \* __Impure detection__: needs to read the database to
--   determine if a transfer involves a flagged account
--   (like the cage follower resolves spent UTxOs)
-- \* __Domain-specific inverse__: semantic undo operations
--   ('RestoreFlag', 'RemoveFlag', 'RemoveNote'),
--   not generic Insert\/Delete
-- \* __Threshold-based__: flags accounts with transfers
--   above a threshold

import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
import Data.Type.Equality ((:~:) (..))
import Database.KV.Transaction
    ( GCompare (..)
    , GEq (..)
    , GOrdering (..)
    , KV
    , Transaction
    , delete
    , insert
    , query
    )
import Types
    ( AuditEvent (..)
    , AuditInv (..)
    , Block (..)
    , Transfer (..)
    )

-- | Threshold above which a transfer is suspicious.
threshold :: Int
threshold = 1000

-- | Column GADT for the audit store.
data AuditCols c where
    -- | Flagged accounts: account → reason.
    FlagKV :: AuditCols (KV String String)
    -- | Notes: account → latest note.
    NoteKV :: AuditCols (KV String String)

instance GEq AuditCols where
    geq FlagKV FlagKV = Just Refl
    geq NoteKV NoteKV = Just Refl
    geq _ _ = Nothing

instance GCompare AuditCols where
    gcompare FlagKV FlagKV = GEQ
    gcompare FlagKV NoteKV = GLT
    gcompare NoteKV FlagKV = GGT
    gcompare NoteKV NoteKV = GEQ

{- | Detect audit events from a block.

This is __impure__ — like @detectCageBlockEvents@, it
needs to read the database to check if the sender is
already flagged. A flagged sender's transfers generate
'AddNote' events; unflagged large transfers generate
'FlagAccount' events.
-}
detectEvents
    :: Block
    -> Transaction IO cf AuditCols op [AuditEvent]
detectEvents Block{blockTransfers} =
    concat <$> mapM detectFromTransfer blockTransfers
  where
    detectFromTransfer
        Transfer{transferFrom, transferAmount} = do
            mFlag <- query FlagKV transferFrom
            pure $ case mFlag of
                Just _ ->
                    -- Already flagged: add a note
                    [ AddNote
                        transferFrom
                        ( "transfer of "
                            ++ show transferAmount
                        )
                    ]
                Nothing
                    | transferAmount > threshold ->
                        -- Large transfer: flag it
                        [ FlagAccount
                            transferFrom
                            ( "large transfer: "
                                ++ show transferAmount
                            )
                        ]
                    | otherwise -> []

{- | Compute inverse before applying an event.

Like the cage follower's @computeInverse@: read
current state to build the semantic inverse, then
apply the mutation.
-}
applyWithInverse
    :: AuditEvent
    -> Transaction IO cf AuditCols op AuditInv
applyWithInverse (FlagAccount account reason) = do
    oldFlag <- query FlagKV account
    insert FlagKV account reason
    pure $ case oldFlag of
        Nothing -> RemoveFlag account
        Just oldReason ->
            RestoreFlag account oldReason
applyWithInverse (AddNote account note) = do
    oldNote <- query NoteKV account
    insert NoteKV account note
    pure $ case oldNote of
        Nothing -> RemoveNote account
        Just old -> RestoreNote account old

-- | Apply fast without inverse (restoration mode).
applyFast
    :: AuditEvent
    -> Transaction IO cf AuditCols op ()
applyFast (FlagAccount account reason) =
    insert FlagKV account reason
applyFast (AddNote account note) =
    insert NoteKV account note

-- | Apply an inverse operation.
undoInverse
    :: AuditInv
    -> Transaction IO cf AuditCols op ()
undoInverse (RemoveFlag account) =
    delete FlagKV account
undoInverse (RestoreFlag account oldReason) =
    insert FlagKV account oldReason
undoInverse (RemoveNote account) =
    delete NoteKV account
undoInverse (RestoreNote account old) =
    insert NoteKV account old

-- | Create a restoring continuation for audit.
mkAuditRestoring
    :: Restoring
        IO
        (Transaction IO cf AuditCols op)
        Block
        [AuditInv]
        ()
mkAuditRestoring =
    Restoring
        { restore = \block -> do
            events <- detectEvents block
            mapM_ applyFast events
            pure mkAuditRestoring
        , toFollowing =
            pure mkAuditFollowing
        }

-- | Create a following continuation for audit.
mkAuditFollowing
    :: Following
        IO
        (Transaction IO cf AuditCols op)
        Block
        [AuditInv]
        ()
mkAuditFollowing =
    Following
        { follow = \block -> do
            events <- detectEvents block
            invs <- mapM applyWithInverse events
            pure (invs, Nothing, mkAuditFollowing)
        , toRestoring =
            pure mkAuditRestoring
        , applyInverse =
            mapM_ undoInverse . reverse
        }
