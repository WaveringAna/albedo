{inputs, ...}: {
  perSystem = {
    pkgs,
    beamPackages,
    gleam,
    ...
  }: {
    packages = rec {
      chrome-headless-shell = pkgs.callPackage ./chrome-headless-shell.nix {};
      glinter = pkgs.callPackage ./glinter.nix {
        inherit beamPackages gleam;
        src = inputs.glinter;
      };
      albedo = pkgs.callPackage ../default.nix {
        inherit beamPackages gleam chrome-headless-shell;
        inherit (inputs) usage-core;
      };
      albedo-client = albedo.client;
      albedo-server = albedo.server;
      inherit (albedo) daemon render usageCore;
      default = albedo;
    };
  };
}
