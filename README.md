# chain-follower

Generic blockchain synchronization library with rollback support, phase management, and formally verified correctness.

**[Documentation](https://lambdasistemi.github.io/chain-follower/)**

## What it does

Chain Follower sits between a chain source and your application backend. It manages block ingestion across two phases (bulk restoration and near-tip following), stores inverse operations for rollback, and guarantees that fork resolution produces the correct final state regardless of the traversal path.

Core correctness properties are proved in Lean 4 and mirrored as QuickCheck properties via `ChainFollower.Laws`.

## Quick start

```bash
# Run the tutorial (demonstrates full lifecycle)
nix run github:lambdasistemi/chain-follower#tutorial

# Development shell
nix develop

# Build, test, lint
just ci
```

## Modules

| Module | Purpose |
|--------|---------|
| `ChainFollower.Backend` | CPS backend interface: `Restoring`, `Following`, `Init` |
| `ChainFollower.Runner` | State machine: `processBlock`, `rollbackTo` |
| `ChainFollower.Rollbacks.*` | Swap-partition rollback store |
| `ChainFollower.MockChain` | `BlockTree`, DFS walk, canonical path |
| `ChainFollower.Laws` | Testable backend laws derived from Lean proofs |

## Lean formalization

The `lean/` directory contains machine-checked proofs:

- `swap_inverse_restores` -- swap is an involution
- `rollback_restores` -- multi-step rollback via reversed inverse log
- `dfs_equiv_canonical` -- DFS walk of a well-formed block tree equals the canonical path (fully proved, no sorry)

## License

Apache-2.0
