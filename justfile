# shellcheck shell=bash

set unstable := true

# List available recipes
default:
    @just --list

# Format all source files
format:
    #!/usr/bin/env bash
    set -euo pipefail
    for i in {1..3}; do
        fourmolu -i lib tutorial exe test
    done
    cabal-fmt -i *.cabal
    nixfmt *.nix

# Check formatting without modifying files
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fourmolu -m check lib tutorial exe test
    cabal-fmt -c *.cabal

# Run hlint
hlint:
    #!/usr/bin/env bash
    hlint lib tutorial exe test

# Build
build:
    #!/usr/bin/env bash
    cabal build all -O0

# Run tests
test:
    #!/usr/bin/env bash
    cabal test all -O0

# Full CI pipeline
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build
    just test
    just format-check
    just hlint
