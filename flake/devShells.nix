_: {
  perSystem = {pkgs, ...}: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        go
        gopls
        gleam
        beamPackages.erlang
        (beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];})
        python3
        pre-commit
        ruff
        cargo
        rustc
      ];
    };
  };
}
