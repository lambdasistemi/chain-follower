{
  description = "Abstract chain follower types";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix.url =
      "github:input-output-hk/haskell.nix/baa6a549ce876e9c44c494a12116f178f1becbe6";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    dev-assets-mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
  };
  outputs =
    inputs@{ self, nixpkgs, flake-parts, haskellNix, dev-assets-mkdocs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { system, ... }:
        let
          mkdocs = dev-assets-mkdocs.packages.${system};
          pkgs = import nixpkgs {
            overlays = [ haskellNix.overlay ];
            inherit system;
          };
          indexState = "2025-12-07T00:00:00Z";
          indexTool = { index-state = indexState; };
          project = pkgs.haskell-nix.cabalProject' {
            name = "chain-follower";
            src = ./.;
            compiler-nix-name = "ghc984";
            shell = {
              tools = {
                cabal = indexTool;
                cabal-fmt = indexTool;
                fourmolu = indexTool;
                hlint = indexTool;
              };
              buildInputs = [
                pkgs.just
                pkgs.nixfmt-classic
                pkgs.elan
                pkgs.mkdocs
                mkdocs.from-nixpkgs
              ];
            };
          };
        in {
          packages.default = project.hsPkgs.chain-follower.components.library;
          packages.tutorial =
            project.hsPkgs.chain-follower.components.exes.chain-follower-tutorial;
          devShells.default = project.shell;
        };
    };
}
