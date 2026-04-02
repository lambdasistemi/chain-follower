# Changelog

## 1.0.0 (2026-04-02)


### Features

* add abstract chain follower types ([eaba871](https://github.com/lambdasistemi/chain-follower/commit/eaba871e6c6553e77fc59f304aaaeb02550ff979))
* add ChainFollower.Laws — testable backend laws ([0d97929](https://github.com/lambdasistemi/chain-follower/commit/0d97929ade6913e581505e069df0d945fa621ac8))
* add CPS backend interface and rollback runner ([95e4888](https://github.com/lambdasistemi/chain-follower/commit/95e4888bc3909807d10e3e050071400e5b60eb2a))
* add interactive tutorial executable ([3d04a6a](https://github.com/lambdasistemi/chain-follower/commit/3d04a6acf2bb308fcf3d2d5f0653829a5966a472))
* add Lean formalization of block tree DFS equivalence ([aa1b778](https://github.com/lambdasistemi/chain-follower/commit/aa1b778296a1280345423ab17caa3ab298e2095b))
* add Lean proofs for pruning correctness ([5081e09](https://github.com/lambdasistemi/chain-follower/commit/5081e091df288e211d91032aabcfb706ad28ab8b))
* add metadata support to Backend and queryHistory ([5f13cf8](https://github.com/lambdasistemi/chain-follower/commit/5f13cf8c408aadd78c45e7828a02bdc6d490ea2c))
* add onBlock callback to processBlock for atomic checkpoints ([561ed99](https://github.com/lambdasistemi/chain-follower/commit/561ed99c287d1796143dc75d689d5289f8d13e3c))
* add Phase state machine with Lean proofs ([6e19757](https://github.com/lambdasistemi/chain-follower/commit/6e197578db0f72282bb9e4d4c239a5eb9c651273))
* add test suite (E2E, QuickCheck, recovery) ([48aff7d](https://github.com/lambdasistemi/chain-follower/commit/48aff7ded66fd72e50b1006a8fe8fa15d40e13d2))
* add tracer to processBlock for phase transition events ([9db5107](https://github.com/lambdasistemi/chain-follower/commit/9db51071e189d72bcd2fce5ab3735a65b7763f9e)), closes [#23](https://github.com/lambdasistemi/chain-follower/issues/23)
* add tutorial mimicking CSMT and Cage patterns ([0a6ae90](https://github.com/lambdasistemi/chain-follower/commit/0a6ae909563d882be194e1a8f58091b9bd68fbd1))
* atomic transition wipes checkpoint, no sentinel needed ([8681499](https://github.com/lambdasistemi/chain-follower/commit/8681499f6a2591f7f1a60439498cba5128b648fa))
* auto-prune in processBlock, add pruneExcess ([0729dd1](https://github.com/lambdasistemi/chain-follower/commit/0729dd108f60b420c5bd5269a58369d9a5375f5e))
* prove dfs_equiv_canonical with no sorry ([75f4b32](https://github.com/lambdasistemi/chain-follower/commit/75f4b3226d3881f267349c68e57e635142814d9d))
* rewrite tests as QuickCheck state machine + lifecycle ([12b8510](https://github.com/lambdasistemi/chain-follower/commit/12b851054d2b3c8671fd9ab9e841a86192cfa150))
* rewrite tutorial as non-interactive lifecycle narrative ([9d305aa](https://github.com/lambdasistemi/chain-follower/commit/9d305aadfd37ad0188e1db26ddc6b29e0e6ec9fc))
* rewrite tutorial to use full Runner + Init + rollback column ([0a98197](https://github.com/lambdasistemi/chain-follower/commit/0a981970a9ac03ad19a6fef4d4ce26cb8f2368c9))
* simplify Init to single start, add atTip to processBlock ([a77b6cd](https://github.com/lambdasistemi/chain-follower/commit/a77b6cd37b0e6c6c00f7de022eeb416ff0920831))
* store restoration checkpoint in rollback column ([0ff79c9](https://github.com/lambdasistemi/chain-follower/commit/0ff79c92c565a66faf8fb70419af9457264da2ce)), closes [#20](https://github.com/lambdasistemi/chain-follower/issues/20)
* use random block generators in all tests ([ab3cc9c](https://github.com/lambdasistemi/chain-follower/commit/ab3cc9c01a33745c04d3731cfa438b2e5e522435))
* verify tutorial backend satisfies all three laws ([17bb165](https://github.com/lambdasistemi/chain-follower/commit/17bb165c3dd9c47da9dd54e4f1e75eecf50d2bb6))


### Bug Fixes

* all tests green with new phase transition API ([5772412](https://github.com/lambdasistemi/chain-follower/commit/577241287cb305125be35602ac5d8cc7339dadbc))
* correct inverse application order and AddNote inverse ([7c4fd5c](https://github.com/lambdasistemi/chain-follower/commit/7c4fd5c169399cfedf208f692cb01c01e271fd28))
* enable tests in cabal build, revert CI hack ([61e9a34](https://github.com/lambdasistemi/chain-follower/commit/61e9a34181ea7f34daf67463eaf8aeb7414854c0))
* formatting in Laws.hs ([90be7df](https://github.com/lambdasistemi/chain-follower/commit/90be7dffd5d67373ac95570524c0f700dfb9cc1e))
* fourmolu formatting in Runner.hs ([b4c4c72](https://github.com/lambdasistemi/chain-follower/commit/b4c4c72b2933295c71e7f2e3100a99ce6cb2dbbc))
* improve tutorial UX for restart and phase transitions ([afd216c](https://github.com/lambdasistemi/chain-follower/commit/afd216c3f72c97ccc4c7817129b6819aa38408ad))
* relax data-default upper bound to &lt;0.9 ([83b2291](https://github.com/lambdasistemi/chain-follower/commit/83b22913e35e501592a05bff2aff87499102c980)), closes [#7](https://github.com/lambdasistemi/chain-follower/issues/7)
* resolve all hlint warnings ([1d7faa8](https://github.com/lambdasistemi/chain-follower/commit/1d7faa8f44c26ff747c062d3e71e5e6216509832))
* show available commands in tutorial prompt ([451bb8a](https://github.com/lambdasistemi/chain-follower/commit/451bb8a1ecfd04c3fa2374c960770971e5934c60))

## 0.1.0.0

- Initial release with `Follower`, `Intersector`, and `ProgressOrRewind` types.
