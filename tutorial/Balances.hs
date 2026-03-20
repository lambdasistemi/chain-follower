module Balances
    ( -- * Backend
      mkBalancesRestoring
    , mkBalancesFollowing

      -- * Columns
    , BalanceCols (..)

      -- * Extraction (pure)
    , extractOps
    ) where

{- |
Module      : Balances
Description : Balance backend — CSMT-like pattern
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

A simplified balance tracker that mimics the CSMT UTxO
follower pattern:

* __Pure extraction__: @block → [BalanceOp]@ without
  reading the database
* __Simple KV inverse__: stores the old balance value
  before mutation
* __Restoration__: applies ops without computing inverses
* __Following__: applies ops and computes inverses for
  each mutation
-}

import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
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
import Data.Type.Equality ((:~:) (..))
import Types
    ( BalanceInv (..)
    , BalanceOp (..)
    , Block (..)
    , Transfer (..)
    )

-- | Column GADT for the balance store.
data BalanceCols c where
    -- | Account balances: account name → balance.
    BalanceKV :: BalanceCols (KV String Int)

instance GEq BalanceCols where
    geq BalanceKV BalanceKV = Just Refl

instance GCompare BalanceCols where
    gcompare BalanceKV BalanceKV = GEQ

-- | Purely extract balance operations from a block.
--
-- Like CSMT's @uTxOsWithTxCount@: no database access
-- needed, the block contains all information.
extractOps :: Block -> [BalanceOp]
extractOps Block{blockTransfers} =
    concatMap transferToOps blockTransfers
  where
    transferToOps Transfer{transferFrom, transferTo, transferAmount} =
        [ Debit transferFrom transferAmount
        , Credit transferTo transferAmount
        ]

-- | Apply a single balance op in a transaction,
-- returning the inverse.
applyWithInverse
    :: BalanceOp
    -> Transaction IO cf BalanceCols op BalanceInv
applyWithInverse (Credit account amount) = do
    oldBal <- query BalanceKV account
    let newBal = maybe amount (+ amount) oldBal
    insert BalanceKV account newBal
    pure
        BalanceInv
            { invAccount = account
            , invOldBalance = oldBal
            }
applyWithInverse (Debit account amount) = do
    oldBal <- query BalanceKV account
    let newBal = maybe (negate amount) (subtract amount) oldBal
    insert BalanceKV account newBal
    pure
        BalanceInv
            { invAccount = account
            , invOldBalance = oldBal
            }

-- | Apply a single balance op without computing inverse.
applyFast
    :: BalanceOp
    -> Transaction IO cf BalanceCols op ()
applyFast (Credit account amount) = do
    oldBal <- query BalanceKV account
    let newBal = maybe amount (+ amount) oldBal
    insert BalanceKV account newBal
applyFast (Debit account amount) = do
    oldBal <- query BalanceKV account
    let newBal = maybe (negate amount) (subtract amount) oldBal
    insert BalanceKV account newBal

-- | Apply an inverse to restore old state.
undoInverse
    :: BalanceInv
    -> Transaction IO cf BalanceCols op ()
undoInverse BalanceInv{invAccount, invOldBalance} =
    case invOldBalance of
        Nothing -> delete BalanceKV invAccount
        Just bal -> insert BalanceKV invAccount bal

-- | Create a restoring continuation for balances.
mkBalancesRestoring
    :: Restoring
        IO
        (Transaction IO cf BalanceCols op)
        Block
        [BalanceInv]
mkBalancesRestoring =
    Restoring
        { restore = \block -> do
            mapM_ applyFast (extractOps block)
            pure mkBalancesRestoring
        , toFollowing =
            pure mkBalancesFollowing
        }

-- | Create a following continuation for balances.
mkBalancesFollowing
    :: Following
        IO
        (Transaction IO cf BalanceCols op)
        Block
        [BalanceInv]
mkBalancesFollowing =
    Following
        { follow = \block -> do
            invs <- mapM applyWithInverse (extractOps block)
            pure (invs, mkBalancesFollowing)
        , toRestoring =
            pure mkBalancesRestoring
        , applyInverse =
            mapM_ undoInverse
        }
