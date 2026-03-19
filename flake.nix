{
  description = "Abstract chain follower types";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };
  outputs = inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { pkgs, ... }:
        let
          hp = pkgs.haskellPackages;
          chain-follower = hp.callCabal2nix "chain-follower" ./. { };
        in {
          packages.default = chain-follower;
          devShells.default = hp.shellFor {
            packages = _: [ chain-follower ];
            nativeBuildInputs = [
              hp.cabal-install
              hp.fourmolu
              hp.hlint
              hp.cabal-fmt
              pkgs.just
              pkgs.nixfmt-classic
            ];
          };
        };
    };
}
