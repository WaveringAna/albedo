_: {
  perSystem = {gleam, ...}: {
    treefmt.config.programs = {
      alejandra.enable = true;
      deadnix.enable = true;
      gleam = {
        enable = true;
        package = gleam;
      };
      gofmt.enable = true;
      ruff-check.enable = true;
      ruff-format.enable = true;
      shfmt.enable = true;
      statix.enable = true;
    };
  };
}
