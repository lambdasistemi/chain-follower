module Main (main) where

import Audit (AuditCols (..))
import Balances (BalanceCols (..))
import ChainFollower.Backend
    ( Init (..)
    , liftInit
    )
import ChainFollower.Rollbacks.Store qualified as Rollbacks
import ChainFollower.Rollbacks.Types
    ( RollbackPoint (..)
    )
import ChainFollower.Runner
    ( Phase (..)
    , processBlock
    , rollbackTo
    )
import Composed
    ( ComposedInv (..)
    , UnifiedCols (..)
    , composedInit
    )
import Control.Lens (prism')
import Control.Monad (forM_, void, when)
import Data.ByteString.Char8 qualified as BS8
import Data.Default (Default (..))
import Data.IORef
    ( newIORef
    , readIORef
    , writeIORef
    )
import Data.Type.Equality ((:~:) (..))
import Database.KV.Database
    ( KV
    , mkColumns
    )
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction
    ( Codecs (..)
    , DSum (..)
    , GCompare (..)
    , GEq (..)
    , GOrdering (..)
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
import Text.Read (readMaybe)
import Types
    ( Block (..)
    , Transfer (..)
    )

-- * Column GADT: backend + rollback

-- | Full column set: backend columns + rollback storage.
data AllCols c where
    InBackend :: UnifiedCols c -> AllCols c
    Rollbacks :: AllCols (KV Int (RollbackPoint ComposedInv ()))

instance GEq AllCols where
    geq (InBackend a) (InBackend b) = geq a b
    geq Rollbacks Rollbacks = Just Refl
    geq _ _ = Nothing

instance GCompare AllCols where
    gcompare (InBackend a) (InBackend b) =
        gcompare a b
    gcompare (InBackend _) Rollbacks = GLT
    gcompare Rollbacks (InBackend _) = GGT
    gcompare Rollbacks Rollbacks = GEQ

-- * Block generation

accounts :: [String]
accounts =
    ["alice", "bob", "carol", "dave", "eve"]

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

-- * Database setup

cfg :: Config
cfg = def{createIfMissing = True}

dbPath :: FilePath
dbPath = "/tmp/chain-follower-tutorial-db"

-- * Display

type RunTx =
    forall a
     . Transaction IO ColumnFamily AllCols BatchOp a
    -> IO a

printState :: RunTx -> IO ()
printState runTx = do
    balances <-
        runTx $
            mapM
                ( \a -> do
                    b <-
                        mapColumns InBackend $
                            mapColumns InBalance $
                                query BalanceKV a
                    pure (a, b)
                )
                accounts
    flags <-
        runTx $
            mapM
                ( \a -> do
                    f <-
                        mapColumns InBackend $
                            mapColumns InAudit $
                                query FlagKV a
                    pure (a, f)
                )
                accounts
    notes <-
        runTx $
            mapM
                ( \a -> do
                    n <-
                        mapColumns InBackend $
                            mapColumns InAudit $
                                query NoteKV a
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

-- * Terminal helpers

drainInput :: IO ()
drainInput = do
    ready <- hReady stdin
    when ready $ do
        void getChar
        drainInput

-- * Main

main :: IO ()
main = do
    hSetBuffering stdin NoBuffering
    hSetEcho stdin False
    withDBCF
        dbPath
        cfg
        [ ("balances", cfg)
        , ("flags", cfg)
        , ("notes", cfg)
        , ("rollbacks", cfg)
        ]
        $ \db -> do
            let codecs =
                    fromPairList
                        [ InBackend (InBalance BalanceKV)
                            :=> Codecs
                                (prism' BS8.pack (Just . BS8.unpack))
                                ( prism'
                                    (BS8.pack . show)
                                    (readMaybe . BS8.unpack)
                                )
                        , InBackend (InAudit FlagKV)
                            :=> Codecs
                                (prism' BS8.pack (Just . BS8.unpack))
                                (prism' BS8.pack (Just . BS8.unpack))
                        , InBackend (InAudit NoteKV)
                            :=> Codecs
                                (prism' BS8.pack (Just . BS8.unpack))
                                (prism' BS8.pack (Just . BS8.unpack))
                        , Rollbacks
                            :=> Codecs
                                ( prism'
                                    (BS8.pack . show)
                                    (readMaybe . BS8.unpack)
                                )
                                ( prism'
                                    (BS8.pack . show)
                                    (readMaybe . BS8.unpack)
                                )
                        ]
                database =
                    mkRocksDBDatabase db $
                        mkColumns
                            (columnFamilies db)
                            codecs
                runTx
                    :: RunTx
                runTx =
                    runTransactionUnguarded database

            -- Lift the backend Init into the full column type
            let backend =
                    liftInit
                        (mapColumns InBackend)
                        composedInit

            -- ── Introduction ─────────────────────────────
            putStrLn ""
            putStrLn "  Chain Follower Tutorial"
            putStrLn "  ======================"
            putStrLn ""
            putStrLn "  You control a mock blockchain. The chain follower"
            putStrLn "  uses the Runner to process blocks atomically"
            putStrLn "  (backend mutations + rollback storage in one tx)."
            putStrLn ""
            putStrLn "  Controls:"
            putStrLn "    [space/f]  produce next block (roll forward)"
            putStrLn "    [r]        fork! roll back 1 slot"
            putStrLn "    [d]        delete DB and quit (fresh start next time)"
            putStrLn "    [q]        quit (state persists for next run)"
            putStrLn ""

            -- ── Initialization ───────────────────────────
            putStrLn "  Initializing..."
            mTip <- runTx $ Rollbacks.queryTip Rollbacks
            phase <- case mTip of
                Nothing -> do
                    putStrLn "  No rollback tip found. Fresh start."
                    putStrLn "  Setting up rollback sentinel at slot 0."
                    runTx $
                        Rollbacks.armageddonSetup Rollbacks 0 Nothing
                    putStrLn ""
                    putStrLn "  Phase: RESTORATION"
                    putStrLn "  The follower is far from the tip."
                    putStrLn "  Blocks are ingested fast, no inverses stored."
                    putStrLn ""
                    r <- startRestoring backend
                    pure (InRestoration r)
                Just tip -> do
                    putStrLn $
                        "  Found rollback tip at slot "
                            ++ show tip
                            ++ ". Resuming."
                    putStrLn ""
                    putStrLn "  Phase: FOLLOWING"
                    putStrLn "  Near the tip, full inverse tracking."
                    putStrLn ""
                    f <- resumeFollowing backend
                    pure (InFollowing f)

            printState runTx
            putStrLn ""

            -- ── Interactive loop ─────────────────────────
            phaseRef <- newIORef phase
            slotRef <- case mTip of
                Nothing -> newIORef (1 :: Int)
                Just tip -> newIORef (tip + 1)

            let loop = do
                    drainInput
                    p <- readIORef phaseRef
                    slot <- readIORef slotRef
                    let (phaseLabel, hint) = case p of
                            InRestoration _ ->
                                ("RESTORE", "f:forward t:transition q:quit")
                            InFollowing _ ->
                                ("FOLLOW", "f:forward r:rollback q:quit")
                    putStr $
                        "  ["
                            ++ phaseLabel
                            ++ " slot:"
                            ++ show (slot - 1)
                            ++ "] ("
                            ++ hint
                            ++ ") > "
                    hFlush stdout
                    c <- getChar
                    putStrLn ""
                    case c of
                        'q' -> do
                            putStrLn "  Quit. State persisted."
                            putStrLn $
                                "  Run again to resume from slot "
                                    ++ show (slot - 1)
                                    ++ "."
                        'Q' -> do
                            putStrLn "  Quit. State persisted."
                        'd' -> do
                            putStrLn "  Deleting database..."
                            -- Can't delete while open, just inform
                            putStrLn $
                                "  Run: rm -rf " ++ dbPath
                        'r' -> do
                            case p of
                                InRestoration _ -> do
                                    putStrLn
                                        "  Cannot rollback in restoration mode."
                                    putStrLn
                                        "  (No inverses stored yet.)"
                                    putStrLn ""
                                    loop
                                InFollowing f -> do
                                    let target = slot - 2
                                    if target < 0
                                        then do
                                            putStrLn
                                                "  Nothing to roll back."
                                            putStrLn ""
                                            loop
                                        else do
                                            putStrLn $
                                                "  ROLLBACK to slot "
                                                    ++ show target
                                            result <-
                                                runTx $
                                                    rollbackTo
                                                        Rollbacks
                                                        f
                                                        target
                                            putStrLn $
                                                "  Result: "
                                                    ++ show result
                                            writeIORef
                                                slotRef
                                                (target + 1)
                                            putStrLn ""
                                            printState runTx
                                            putStrLn ""
                                            loop
                        't' -> do
                            -- Transition to following
                            case p of
                                InRestoration _ -> do
                                    putStrLn
                                        "  Transitioning to FOLLOWING mode."
                                    putStrLn
                                        "  From now on, inverses are stored"
                                    putStrLn
                                        "  for rollback support."
                                    putStrLn ""
                                    -- Set up rollback sentinel at current position
                                    let sentinel = slot - 1
                                    runTx $
                                        Rollbacks.armageddonSetup
                                            Rollbacks
                                            sentinel
                                            Nothing
                                    f <- resumeFollowing backend
                                    writeIORef phaseRef (InFollowing f)
                                    loop
                                InFollowing _ -> do
                                    putStrLn
                                        "  Already in FOLLOWING mode."
                                    putStrLn ""
                                    loop
                        _ -> do
                            -- Forward: produce next block
                            let block = mkBlock slot
                            putStrLn $
                                "  [forward] slot "
                                    ++ show slot
                            putStr $ describeBlock block
                            p' <-
                                runTx $
                                    processBlock
                                        Rollbacks
                                        slot
                                        block
                                        p
                            writeIORef phaseRef p'
                            writeIORef slotRef (slot + 1)
                            putStrLn ""
                            printState runTx
                            putStrLn ""
                            loop
            loop
