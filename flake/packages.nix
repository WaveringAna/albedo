{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages = rec {
      albedo = pkgs.callPackage ../default.nix {usage-core = inputs.usage-core;};
      inherit (albedo) daemon render usageCore;
      default = albedo;
    };
  };
}
