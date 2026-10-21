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
          nodejs
        ])
        ++ [
          gleam
          beamPackages.erlang
          (beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];})
          config.packages.albedo-lint
          config.packages.chrome-headless-shell
        ]
        ++ lib.attrValues config.treefmt.build.programs;
    };
  };
}
