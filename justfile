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
        fourmolu -i lib
    done
    cabal-fmt -i *.cabal
    nixfmt *.nix

# Check formatting without modifying files
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fourmolu -m check lib
    cabal-fmt -c *.cabal

# Run hlint
hlint:
    #!/usr/bin/env bash
    hlint lib

# Build
build:
    #!/usr/bin/env bash
    cabal build all -O0

# Generate function call graph (SVG + DOT)
call-graph:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build all -O0 --ghc-options="-fwrite-ide-info -hiedir=.hie"
    calligraphy -i .hie --show-module-path -d call-graph.dot -s call-graph.svg

# Full CI pipeline
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build
    just format-check
    just hlint
