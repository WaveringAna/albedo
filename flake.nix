{
  description = "albedo coding agent and terminal client";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  # usage-core, pinned: a pure Zig provider-usage core whose CLI the daemon
  # drives one round at a time (see robot-docs/usage-feed.md). A tarball off
  # the knot, not a git input, so no fetchGit machinery enters the build.
  inputs.usage-core = {
    url = "https://api.next.tangled.org/xrpc/org.tangled.temp.git.getArchive?repo=did%3Aplc%3A2lf7buutfnfcucljnmaypf7u&ref=1a4bff9&format=tar.gz&prefix=provide-usage-main";
    flake = false;
  };

  outputs = { self, nixpkgs, usage-core }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in {
      packages = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in rec {
          albedo = pkgs.callPackage ./default.nix { inherit usage-core; };
          inherit (albedo) daemon render usageCore;
          default = albedo;
        });
      devShells = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          beam = pkgs.beamPackages;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.go pkgs.gopls
              pkgs.gleam beam.erlang (beam.rebar3WithPlugins { plugins = [ beam.pc ]; })
              pkgs.python3 pkgs.pre-commit pkgs.ruff
              pkgs.cargo pkgs.rustc
            ];
          };
        });
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.albedo}/bin/albedo";
        };
      });
    };
}
