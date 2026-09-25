{
  description = "albedo coding agent and terminal client";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in {
      packages = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in rec {
          albedo = pkgs.callPackage ./default.nix { };
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
              pkgs.python3
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
