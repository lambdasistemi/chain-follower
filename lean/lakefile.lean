import Lake
open Lake DSL

package «chain-follower» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib ChainFollower where
  srcDir := "."
