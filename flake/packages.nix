{inputs, ...}: {
  perSystem = {
    pkgs,
    beamPackages,
    ...
  }: {
    packages = rec {
      glinter = pkgs.callPackage ./glinter.nix {
        inherit beamPackages;
        src = inputs.glinter;
      };
      albedo = pkgs.callPackage ../default.nix {
        inherit beamPackages;
        inherit (inputs) usage-core;
      };
      albedo-client = albedo.client;
      albedo-server = albedo.server;
      inherit (albedo) daemon render usageCore;
      default = albedo;
    };
  };
}
