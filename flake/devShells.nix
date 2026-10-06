_: {
  perSystem = {
    config,
    lib,
    pkgs,
    beamPackages,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages =
        (with pkgs; [
          go
          gopls
          gleam
          python311
          pre-commit
          ruff
          ty
          cargo
          rustc
        ])
        ++ [
          beamPackages.erlang
          (beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];})
          config.packages.glinter
        ]
        ++ lib.attrValues config.treefmt.build.programs;
    };
  };
}
