_: {
  perSystem = _: {
    treefmt.config.programs = {
      alejandra.enable = true;
      deadnix.enable = true;
      gleam.enable = true;
      gofmt.enable = true;
      ruff-format.enable = true;
      shfmt.enable = true;
      statix.enable = true;
    };
  };
}
