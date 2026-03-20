module Types
    ( -- * Block
      Block (..)
    , Transfer (..)

      -- * Backend A: Balances (CSMT-like)
    , BalanceOp (..)
    , BalanceInv (..)

      -- * Backend B: Audit (Cage-like)
    , AuditEvent (..)
    , AuditInv (..)
    ) where

{- |
Module      : Types
Description : Tutorial types mimicking CSMT and Cage patterns
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Simplified types that capture the structural differences
between the CSMT UTxO follower and the Cage follower.

__Backend A (Balances)__ — like CSMT:

* Pure extraction: @block → [BalanceOp]@
* Simple KV inverse: old balance value
* Forward: credit\/debit accounts

__Backend B (Audit)__ — like Cage:

* Impure detection: needs DB read to check
  if an account is flagged
* Domain-specific inverse: semantic undo operations
* Forward: flag suspicious accounts, add notes
-}

-- | A block is a list of transfers at a given slot.
data Block = Block
    { blockSlot :: Int
    , blockTransfers :: [Transfer]
    }
    deriving stock (Show)

-- | A transfer moves funds between accounts.
data Transfer = Transfer
    { transferFrom :: String
    , transferTo :: String
    , transferAmount :: Int
    }
    deriving stock (Show)

-- * Backend A: Balances (pure extraction, simple inverse)

-- | Balance operation extracted purely from a block.
data BalanceOp
    = -- | Credit an account.
      Credit String Int
    | -- | Debit an account.
      Debit String Int
    deriving stock (Show, Eq, Read)

-- | Balance inverse — stores the old balance to restore.
data BalanceInv = BalanceInv
    { invAccount :: String
    , invOldBalance :: Maybe Int
    -- ^ 'Nothing' if the account didn't exist before.
    }
    deriving stock (Show, Eq, Read)

-- * Backend B: Audit (impure detection, semantic inverse)

{- | Audit event detected by reading current state.

Detection is impure because we need to check
if the sender is already flagged (like the cage
follower needs to resolve spent UTxOs).
-}
data AuditEvent
    = -- | Flag an account as suspicious (large transfer).
      FlagAccount
        String
        String
        -- ^ account, reason
    | -- | Add a note to a flagged account's history.
      AddNote
        String
        String
        -- ^ account, note
    deriving stock (Show, Eq, Read)

-- | Audit inverse — semantic undo, not syntactic.
data AuditInv
    = -- | Restore a flag that was removed.
      RestoreFlag
        String
        String
        -- ^ account, old reason
    | -- | Remove a flag that was added.
      RemoveFlag String
    | -- | Remove a note that was added (no prior note).
      RemoveNote String
    | -- | Restore a note that was overwritten.
      RestoreNote
        String
        String
        -- ^ account, old note
    deriving stock (Show, Eq, Read)
