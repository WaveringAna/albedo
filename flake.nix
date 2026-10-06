{
  description = "albedo coding agent and terminal client";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: that channel lags by days, and while
    # it still shipped Gleam 1.18 every CI run compiled Gleam 1.19 from source.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Development linter, separate from the daemon's Gleam dependencies.
    glinter = {
      url = "github:pairshaped/glinter";
      flake = false;
    };

    # Pinned Zig usage CLI consumed by the daemon as a non-flake archive.
    usage-core = {
      url = "https://api.next.tangled.org/xrpc/org.tangled.temp.git.getArchive?repo=did%3Aplc%3A2lf7buutfnfcucljnmaypf7u&ref=1a4bff9&format=tar.gz&prefix=provide-usage-main";
      flake = false;
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        ./flake
        inputs.treefmt-nix.flakeModule
      ];
    };
}
