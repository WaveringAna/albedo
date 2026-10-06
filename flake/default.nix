{
  imports = [
    ./devShells.nix
    ./packages.nix
    ./treefmt.nix
  ];

  # The daemon needs OTP 29: its HTTP streams flush zstd frames per event.
  # Passed explicitly rather than overlaid, so cached packages built against
  # the default Erlang, gleam among them, are not rebuilt.
  perSystem = {pkgs, ...}: {
    _module.args.beamPackages = pkgs.beam.packages.erlang_29;
  };
}
