# Running the Tutorial

The tutorial is a non-interactive executable that demonstrates the full lifecycle
of a chain follower: restoration, following, rollback, fork handling, and
restart scenarios.

## With Nix (remote)

```bash
nix run github:lambdasistemi/chain-follower/feat/rollback-support#tutorial
```

## With Nix (local)

From within the repository:

```bash
nix develop -c cabal run chain-follower-tutorial
```

## What it does

The tutorial creates a temporary RocksDB database at `/tmp/chain-follower-tutorial-db`,
runs through seven phases of the chain follower lifecycle, and verifies
correctness at the end. The database is deleted automatically when the tutorial
finishes.

No user interaction is required. The output is printed to stdout.

## Expected output

The tutorial prints a header, then seven phases:

| Phase | Description |
|---|---|
| 1. Fresh Start | Bulk restoration of blocks 1--15 with no inverse tracking |
| 2. Transition to Following | Set up rollback sentinel, follow blocks 16--20 with inverses |
| 3. Simulate a Fork | Roll back blocks 19--20, undoing their mutations |
| 4. Follow the Forked Chain | Apply new blocks 19--22 on the fork |
| 5. Small-Gap Restart | Gap of 3 slots (within stability window), stay in following mode |
| 6. Large-Gap Restart | Gap of 15 slots (exceeds window), armageddon wipe and re-restore |
| 7. Verification | Compare final state against a single-pass canonical chain |

After each phase, state snapshots are printed showing balances, flags, and notes
for each key. Phase 7 prints `PASS: states match.` if everything is correct.

!!! note
    The tutorial uses deterministic block generation (`mkBlock`), so output is
    reproducible across runs. In a real chain follower, block content comes from
    the blockchain.
