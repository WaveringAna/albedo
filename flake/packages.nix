{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages = rec {
      glinter = pkgs.callPackage ./glinter.nix {src = inputs.glinter;};
      albedo = pkgs.callPackage ../default.nix {inherit (inputs) usage-core;};
      inherit (albedo) daemon render usageCore;
      default = albedo;
    };
  };
}
