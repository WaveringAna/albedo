_: {
  perSystem = {
    config,
    lib,
    pkgs,
    beamPackages,
    gleam,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages =
        (with pkgs; [
          go
          gopls
          python311
          pre-commit
          ruff
          ty
          cargo
          rustc
        ])
        ++ [
          gleam
          beamPackages.erlang
          (beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];})
          config.packages.glinter
        ]
        ++ lib.attrValues config.treefmt.build.programs;
    };
  };
}
