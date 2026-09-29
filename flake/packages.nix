{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages = rec {
      albedo = pkgs.callPackage ../default.nix {inherit (inputs) usage-core;};
      inherit (albedo) daemon render usageCore;
      default = albedo;
    };
  };
}
