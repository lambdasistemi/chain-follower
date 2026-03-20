module Composed
    ( -- * Unified columns
      UnifiedCols (..)

      -- * Composed backend
    , composedRestoring
    , composedFollowing

      -- * Initialization
    , composedInit

      -- * Combined inverse
    , ComposedInv (..)
    ) where

-- \|
-- Module      : Composed
-- Description : Fan-out composition of Balances and Audit
-- Copyright   : (c) Paolo Veronelli, 2026
-- License     : Apache-2.0
--
-- Demonstrates composing two backends (Balances and Audit)
-- into a single chain follower, mimicking the MPFS pattern
-- where the cage follower and UTxO CSMT share one
-- transaction via @UnifiedColumns@.
--
-- The key insight: individual backends define their column
-- GADTs and operations, but the __composed__ backend
-- constructs @Restoring@\/@Following@ directly over the
-- @UnifiedCols@ GADT, using @mapColumns@ to route each
-- operation to the right column family.
--
-- This matches the real MPFS pattern where @CageFollower@
-- calls @mapColumns InUtxo@ and @mapColumns InCage@ at
-- each operation site, not at the continuation level.

import Audit
    ( AuditCols (..)
    )
import Audit qualified
import Balances
    ( BalanceCols (..)
    , extractOps
    )
import ChainFollower.Backend
    ( Following (..)
    , Init (..)
    , Restoring (..)
    )
import Database.KV.Transaction
    ( GCompare (..)
    , GEq (..)
    , GOrdering (..)
    , Transaction
    , delete
    , insert
    , mapColumns
    , query
    )
import Types
    ( AuditEvent (..)
    , AuditInv (..)
    , BalanceInv (..)
    , BalanceOp (..)
    , Block (..)
    , Transfer (..)
    )

-- | Unified column GADT combining both backends.
data UnifiedCols c where
    InBalance :: BalanceCols c -> UnifiedCols c
    InAudit :: AuditCols c -> UnifiedCols c

instance GEq UnifiedCols where
    geq (InBalance a) (InBalance b) = geq a b
    geq (InAudit a) (InAudit b) = geq a b
    geq _ _ = Nothing

instance GCompare UnifiedCols where
    gcompare (InBalance a) (InBalance b) =
        gcompare a b
    gcompare (InBalance _) (InAudit _) = GLT
    gcompare (InAudit _) (InBalance _) = GGT
    gcompare (InAudit a) (InAudit b) =
        gcompare a b

-- | Combined inverse from both backends.
data ComposedInv = ComposedInv
    { balanceInvs :: [BalanceInv]
    , auditInvs :: [AuditInv]
    }
    deriving stock (Show, Eq, Read)

-- | Shorthand for unified transaction.
type T cf op =
    Transaction IO cf UnifiedCols op

-- * Balance operations lifted to unified columns

balanceQuery
    :: String -> T cf op (Maybe Int)
balanceQuery =
    mapColumns InBalance . query BalanceKV

balanceInsert
    :: String -> Int -> T cf op ()
balanceInsert k v =
    mapColumns InBalance $ insert BalanceKV k v

balanceDelete :: String -> T cf op ()
balanceDelete =
    mapColumns InBalance . delete BalanceKV

applyBalanceOp
    :: BalanceOp -> T cf op BalanceInv
applyBalanceOp (Credit account amount) = do
    oldBal <- balanceQuery account
    let newBal = maybe amount (+ amount) oldBal
    balanceInsert account newBal
    pure
        BalanceInv
            { invAccount = account
            , invOldBalance = oldBal
            }
applyBalanceOp (Debit account amount) = do
    oldBal <- balanceQuery account
    let newBal =
            maybe (negate amount) (subtract amount) oldBal
    balanceInsert account newBal
    pure
        BalanceInv
            { invAccount = account
            , invOldBalance = oldBal
            }

applyBalanceOpFast :: BalanceOp -> T cf op ()
applyBalanceOpFast (Credit account amount) = do
    oldBal <- balanceQuery account
    let newBal = maybe amount (+ amount) oldBal
    balanceInsert account newBal
applyBalanceOpFast (Debit account amount) = do
    oldBal <- balanceQuery account
    let newBal =
            maybe (negate amount) (subtract amount) oldBal
    balanceInsert account newBal

undoBalanceInv :: BalanceInv -> T cf op ()
undoBalanceInv BalanceInv{invAccount, invOldBalance} =
    case invOldBalance of
        Nothing -> balanceDelete invAccount
        Just bal -> balanceInsert invAccount bal

-- * Audit operations lifted to unified columns

auditQueryFlag
    :: String -> T cf op (Maybe String)
auditQueryFlag =
    mapColumns InAudit . query FlagKV

auditQueryNote
    :: String -> T cf op (Maybe String)
auditQueryNote =
    mapColumns InAudit . query NoteKV

auditInsertFlag
    :: String -> String -> T cf op ()
auditInsertFlag k v =
    mapColumns InAudit $ insert FlagKV k v

auditDeleteFlag :: String -> T cf op ()
auditDeleteFlag =
    mapColumns InAudit . delete FlagKV

auditInsertNote
    :: String -> String -> T cf op ()
auditInsertNote k v =
    mapColumns InAudit $ insert NoteKV k v

auditDeleteNote :: String -> T cf op ()
auditDeleteNote =
    mapColumns InAudit . delete NoteKV

{- | Detect audit events — impure, reads balance
and audit columns.
-}
detectAuditEvents :: Block -> T cf op [AuditEvent]
detectAuditEvents Block{blockTransfers} =
    concat <$> mapM detect blockTransfers
  where
    detect Transfer{transferFrom, transferAmount} = do
        mFlag <- auditQueryFlag transferFrom
        pure $ case mFlag of
            Just _ ->
                [ AddNote
                    transferFrom
                    ( "transfer of "
                        ++ show transferAmount
                    )
                ]
            Nothing
                | transferAmount > Audit.threshold ->
                    [ FlagAccount
                        transferFrom
                        ( "large transfer: "
                            ++ show transferAmount
                        )
                    ]
                | otherwise -> []

applyAuditEvent
    :: AuditEvent -> T cf op AuditInv
applyAuditEvent (FlagAccount account reason) = do
    oldFlag <- auditQueryFlag account
    auditInsertFlag account reason
    pure $ case oldFlag of
        Nothing -> RemoveFlag account
        Just old -> RestoreFlag account old
applyAuditEvent (AddNote account note) = do
    oldNote <- auditQueryNote account
    auditInsertNote account note
    pure $ case oldNote of
        Nothing -> RemoveNote account
        Just old -> RestoreNote account old

applyAuditEventFast
    :: AuditEvent -> T cf op ()
applyAuditEventFast (FlagAccount account reason) =
    auditInsertFlag account reason
applyAuditEventFast (AddNote account note) =
    auditInsertNote account note

undoAuditInv :: AuditInv -> T cf op ()
undoAuditInv (RemoveFlag account) =
    auditDeleteFlag account
undoAuditInv (RestoreFlag account old) =
    auditInsertFlag account old
undoAuditInv (RemoveNote account) =
    auditDeleteNote account
undoAuditInv (RestoreNote account old) =
    auditInsertNote account old

-- * Composed continuations

{- | Composed restoring continuation.

Same block feeds both backends in one transaction.
Balances: pure extraction, fast apply.
Audit: impure detection (reads DB), fast apply.
-}
composedRestoring
    :: Restoring IO (T cf op) Block ComposedInv
composedRestoring =
    Restoring
        { restore = \block -> do
            -- Balance: pure extraction, fast apply
            mapM_ applyBalanceOpFast (extractOps block)
            -- Audit: impure detection, fast apply
            events <- detectAuditEvents block
            mapM_ applyAuditEventFast events
            pure composedRestoring
        , toFollowing = pure composedFollowing
        }

{- | Composed following continuation.

Both backends in one transaction, inverses paired.
-}
composedFollowing
    :: Following IO (T cf op) Block ComposedInv
composedFollowing =
    Following
        { follow = \block -> do
            -- Balance: pure extraction, full apply
            bInvs <-
                mapM applyBalanceOp (extractOps block)
            -- Audit: impure detection, full apply
            events <- detectAuditEvents block
            aInvs <- mapM applyAuditEvent events
            let inv =
                    ComposedInv
                        { balanceInvs = bInvs
                        , auditInvs = aInvs
                        }
            pure (inv, composedFollowing)
        , toRestoring = pure composedRestoring
        , applyInverse =
            \ComposedInv{balanceInvs, auditInvs} ->
                do
                    -- Undo in reverse: audit was applied after
                    -- balances, so undo audit first. Within each
                    -- list, reverse to undo last-applied first.
                    mapM_ undoAuditInv (reverse auditInvs)
                    mapM_ undoBalanceInv (reverse balanceInvs)
        }

-- | Backend initialization for the composed backend.
composedInit
    :: Init IO (T cf op) Block ComposedInv
composedInit =
    Init
        { startRestoring = pure composedRestoring
        , resumeFollowing = pure composedFollowing
        }
