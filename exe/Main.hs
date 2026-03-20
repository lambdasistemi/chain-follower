module Main (main) where

import Audit (AuditCols (..))
import Balances (BalanceCols (..))
import ChainFollower.Backend
    ( Following (..)
    , Restoring (..)
    )
import Composed
    ( ComposedInv (..)
    , UnifiedCols (..)
    , composedRestoring
    )
import Control.Lens (prism')
import Control.Monad (foldM, forM_, void, when)
import Data.ByteString.Char8 qualified as BS8
import Data.Default (Default (..))
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Database.KV.Database (mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction
    ( Codecs (..)
    , DSum (..)
    , Transaction
    , fromPairList
    , mapColumns
    , query
    , runTransactionUnguarded
    )
import Database.RocksDB
    ( BatchOp
    , ColumnFamily
    , Config (createIfMissing)
    , DB (..)
    , withDBCF
    )
import System.IO
    ( BufferMode (..)
    , hFlush
    , hReady
    , hSetBuffering
    , hSetEcho
    , stdin
    , stdout
    )
import System.IO.Temp
    ( withSystemTempDirectory
    )
import Text.Read (readMaybe)
import Types
    ( Block (..)
    , Transfer (..)
    )

-- * Block generation

-- | Accounts in the simulation.
accounts :: [String]
accounts =
    ["alice", "bob", "carol", "dave", "eve"]

{- | Generate a block for a given slot.

Rotates senders and receivers, with every 3rd
block having a large transfer (triggers audit).
-}
mkBlock :: Int -> Block
mkBlock slot =
    Block
        { blockSlot = slot
        , blockTransfers = transfers
        }
  where
    n = length accounts
    sender = accounts !! (slot `mod` n)
    receiver = accounts !! ((slot + 1) `mod` n)
    amount
        | slot `mod` 3 == 0 = 1500
        | otherwise = 100 + slot * 10
    transfers = [Transfer sender receiver amount]

describeBlock :: Block -> String
describeBlock Block{blockTransfers} =
    unlines $
        map describeTransfer blockTransfers
  where
    describeTransfer Transfer{transferFrom, transferTo, transferAmount} =
        "    "
            ++ transferFrom
            ++ " -> "
            ++ transferTo
            ++ " : "
            ++ show transferAmount
            ++ if transferAmount > 1000
                then "  (large! will trigger audit)"
                else ""

-- * Database setup

cfg :: Config
cfg = def{createIfMissing = True}

-- * Display

type RunTx =
    forall a
     . Transaction IO ColumnFamily UnifiedCols BatchOp a
    -> IO a

printState :: RunTx -> IO ()
printState runTx = do
    balances <-
        runTx $
            mapM
                ( \a -> do
                    b <- mapColumns InBalance $ query BalanceKV a
                    pure (a, b)
                )
                accounts
    flags <-
        runTx $
            mapM
                ( \a -> do
                    f <- mapColumns InAudit $ query FlagKV a
                    pure (a, f)
                )
                accounts
    notes <-
        runTx $
            mapM
                ( \a -> do
                    n <- mapColumns InAudit $ query NoteKV a
                    pure (a, n)
                )
                accounts
    putStr "  balances:"
    forM_ balances $ \(name, mBal) ->
        putStr $ " " ++ name ++ "=" ++ maybe "0" show mBal
    putStrLn ""
    let activeFlags = [(n, f) | (n, Just f) <- flags]
    when (not $ null activeFlags) $ do
        putStr "  flags:   "
        forM_ activeFlags $ \(n, f) ->
            putStr $ " " ++ n ++ "=\"" ++ f ++ "\""
        putStrLn ""
    let activeNotes = [(n, v) | (n, Just v) <- notes]
    when (not $ null activeNotes) $ do
        putStr "  notes:   "
        forM_ activeNotes $ \(n, v) ->
            putStr $ " " ++ n ++ "=\"" ++ v ++ "\""
        putStrLn ""
    hFlush stdout

-- * Terminal helpers

-- | Wait for user to press a key.
waitKey :: IO ()
waitKey = void getChar

-- | Drain any buffered input.
drainInput :: IO ()
drainInput = do
    ready <- hReady stdin
    when ready $ do
        void getChar
        drainInput

-- | Print a message and wait for keypress.
pause :: String -> IO ()
pause msg = do
    drainInput
    putStr msg
    hFlush stdout
    waitKey
    putStrLn ""

-- * Main

main :: IO ()
main = do
    hSetBuffering stdin NoBuffering
    hSetEcho stdin False
    withSystemTempDirectory "chain-follower-tutorial" $
        \dbPath -> do
            withDBCF
                dbPath
                cfg
                [ ("balances", cfg)
                , ("flags", cfg)
                , ("notes", cfg)
                ]
                $ \db -> do
                    let codecs =
                            fromPairList
                                [ InBalance BalanceKV
                                    :=> Codecs
                                        (prism' BS8.pack (Just . BS8.unpack))
                                        ( prism'
                                            (BS8.pack . show)
                                            (readMaybe . BS8.unpack)
                                        )
                                , InAudit FlagKV
                                    :=> Codecs
                                        (prism' BS8.pack (Just . BS8.unpack))
                                        (prism' BS8.pack (Just . BS8.unpack))
                                , InAudit NoteKV
                                    :=> Codecs
                                        (prism' BS8.pack (Just . BS8.unpack))
                                        (prism' BS8.pack (Just . BS8.unpack))
                                ]
                        database =
                            mkRocksDBDatabase db $
                                mkColumns
                                    (columnFamilies db)
                                    codecs
                        runTx
                            :: forall a. Transaction IO ColumnFamily UnifiedCols BatchOp a -> IO a
                        runTx = runTransactionUnguarded database

                    -- ── Introduction ──────────────────────────────
                    putStrLn ""
                    putStrLn "  Chain Follower Tutorial"
                    putStrLn "  ======================"
                    putStrLn ""
                    putStrLn "  This tutorial simulates a blockchain with 5 accounts"
                    putStrLn "  (alice, bob, carol, dave, eve) and two backends:"
                    putStrLn ""
                    putStrLn
                        "    Balances  tracks account balances (like a CSMT/UTxO follower)"
                    putStrLn "             pure extraction: block -> [Credit/Debit]"
                    putStrLn ""
                    putStrLn
                        "    Audit     flags suspicious accounts (like a Cage follower)"
                    putStrLn
                        "             impure detection: reads DB to check existing flags"
                    putStrLn "             transfers > 1000 flag the sender"
                    putStrLn ""
                    putStrLn "  Both backends share ONE transaction per block."
                    putStrLn ""
                    putStrLn "  The chain follower has two phases:"
                    putStrLn ""
                    putStrLn
                        "    Restoration  fast-forward through history, no rollback data"
                    putStrLn
                        "    Following    near the tip, computes inverse operations so"
                    putStrLn "                 blocks can be undone on rollback"
                    putStrLn ""
                    putStrLn "  Controls: press any key to advance, q to quit"
                    putStrLn ""

                    -- ── Phase 1: Restoration ─────────────────────
                    pause "[press any key to start restoration]"
                    putStrLn ""
                    putStrLn "  Phase 1: RESTORATION"
                    putStrLn "  --------------------"
                    putStrLn "  The follower is far from the chain tip. It ingests blocks"
                    putStrLn "  as fast as possible, with no inverse computation."
                    putStrLn "  This is the fast path: apply mutations, discard history."
                    putStrLn ""

                    let restorationSlots = [1 .. 10]
                    finalRestoring <-
                        foldM
                            ( \r slot -> do
                                let block = mkBlock slot
                                putStrLn $
                                    "  [restore] slot "
                                        ++ show slot
                                putStr $ describeBlock block
                                next <- runTx $ restore r block
                                pure next
                            )
                            composedRestoring
                            restorationSlots

                    putStrLn ""
                    putStrLn
                        "  Restoration complete. 10 blocks ingested with no rollback data."
                    putStrLn ""
                    putStrLn "  Current state:"
                    printState runTx
                    putStrLn ""

                    -- ── Phase 2: Transition ──────────────────────
                    pause "[press any key to transition to following mode]"
                    putStrLn ""
                    putStrLn "  Phase 2: TRANSITION"
                    putStrLn "  -------------------"
                    putStrLn "  The follower is now near the chain tip."
                    putStrLn "  Calling toFollowing on the Restoring continuation"
                    putStrLn "  switches to Following mode. From now on, every block"
                    putStrLn "  produces inverse operations that can undo it."
                    putStrLn ""
                    following <- toFollowing finalRestoring
                    putStrLn "  Transition complete. Now in Following mode."
                    putStrLn ""

                    -- ── Phase 3: Following (interactive) ─────────
                    pause "[press any key to start following blocks one by one]"
                    putStrLn ""
                    putStrLn "  Phase 3: FOLLOWING"
                    putStrLn "  ------------------"
                    putStrLn "  Each block is processed with full inverse tracking."
                    putStrLn
                        "  The inverse is what we need to UNDO this block on rollback."
                    putStrLn ""
                    putStrLn "  Press any key to produce the next block, q to stop."
                    putStrLn ""

                    inversesRef <- newIORef []
                    slotRef <- newIORef (11 :: Int)
                    followingRef <- newIORef following
                    quitRef <- newIORef False

                    let followLoop = do
                            quit <- readIORef quitRef
                            when (not quit) $ do
                                drainInput
                                putStr "  > "
                                hFlush stdout
                                c <- getChar
                                putStrLn ""
                                if c == 'q' || c == 'Q'
                                    then writeIORef quitRef True
                                    else do
                                        slot <- readIORef slotRef
                                        f <- readIORef followingRef
                                        let block = mkBlock slot
                                        putStrLn $
                                            "  [follow] slot "
                                                ++ show slot
                                        putStr $ describeBlock block
                                        (inv, f') <- runTx $ follow f block
                                        modifyIORef' inversesRef ((slot, inv) :)
                                        writeIORef followingRef f'
                                        writeIORef slotRef (slot + 1)
                                        putStrLn ""
                                        putStrLn "  Inverse operations stored (for rollback):"
                                        putStrLn $
                                            "    balance inverses: "
                                                ++ show (length $ balanceInvs inv)
                                                ++ " undo ops"
                                        putStrLn $
                                            "    audit inverses:   "
                                                ++ show (length $ auditInvs inv)
                                                ++ " undo ops"
                                        putStrLn ""
                                        putStrLn "  State:"
                                        printState runTx
                                        putStrLn ""
                                        followLoop
                    followLoop

                    -- ── Phase 4: Rollback ────────────────────────
                    inverses <- readIORef inversesRef
                    if null inverses
                        then do
                            putStrLn ""
                            putStrLn "  No blocks followed, skipping rollback demo."
                        else do
                            putStrLn ""
                            putStrLn "  Phase 4: ROLLBACK"
                            putStrLn "  -----------------"
                            putStrLn
                                "  The chain source reports a fork! We must undo recent blocks."
                            putStrLn
                                "  Each stored inverse is applied in reverse order to restore"
                            putStrLn "  the state before that block was processed."
                            putStrLn ""
                            let rollbackCount = min 3 (length inverses)
                                toUndo = take rollbackCount inverses
                            putStrLn $
                                "  Will undo "
                                    ++ show rollbackCount
                                    ++ " block(s). Press any key for each."
                            putStrLn ""

                            f <- readIORef followingRef
                            forM_ toUndo $ \(slot, inv) -> do
                                pause $
                                    "  [undo slot "
                                        ++ show slot
                                        ++ " — press any key]"
                                runTx $ applyInverse f inv
                                putStrLn $
                                    "  Rolled back slot "
                                        ++ show slot
                                putStrLn ""
                                putStrLn "  State:"
                                printState runTx
                                putStrLn ""

                            let targetSlot =
                                    fst (last toUndo) - 1
                            putStrLn $
                                "  Rollback complete. State is back to slot "
                                    ++ show targetSlot
                                    ++ "."

                    putStrLn ""
                    putStrLn "  Done. The chain follower correctly restored state"
                    putStrLn "  by applying inverse operations in reverse order."
                    putStrLn ""

