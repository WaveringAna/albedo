_: {
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages =
        (with pkgs; [
          go
          gopls
          gleam
          beamPackages.erlang
          (beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];})
          python3
          pre-commit
          ruff
          ty
          cargo
          rustc
        ])
        ++ [config.packages.glinter]
        ++ lib.attrValues config.treefmt.build.programs;
    };
  };
}
