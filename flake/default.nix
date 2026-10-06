{
  imports = [
    ./devShells.nix
    ./packages.nix
    ./treefmt.nix
  ];

  # The daemon needs OTP 29: its HTTP streams flush zstd frames per event.
  # Passed explicitly rather than overlaid, so cached packages built against
  # the default Erlang, gleam among them, are not rebuilt.
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    _module.args.beamPackages = pkgs.beam.packages.erlang_29;

    # The sources are formatted by Gleam 1.19, whose formatter and 1.18's
    # each reject the other's output. Built from source (hashes from nixpkgs
    # master) only while the locked nixpkgs still ships an older release.
    _module.args.gleam =
      if lib.versionAtLeast pkgs.gleam.version "1.19.0"
      then pkgs.gleam
      else
        pkgs.gleam.overrideAttrs (finalAttrs: _: {
          version = "1.19.0";
          src = pkgs.fetchFromGitHub {
            owner = "gleam-lang";
            repo = "gleam";
            tag = "v${finalAttrs.version}";
            hash = "sha256-uMD1ZI8A0gdQbIFvJ9q9CVSJ+jvxJiCzdJ1d2r/BHys=";
          };
          cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
            inherit (finalAttrs) pname version src;
            hash = "sha256-TZWaKlgdKKM7IUjYu96rbgWsNjHW16E+UKleB68yIh0=";
          };
          # nixpkgs runs the compiler's suite for this release already.
          doCheck = false;
        });
  };
}
