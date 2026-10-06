{
  lib,
  stdenv,
  rustPlatform,
  buildGoModule,
  symlinkJoin,
  fetchurl,
  gleam,
  beamPackages,
  python311,
  bash,
  coreutils,
  makeWrapper,
  zig,
  usage-core,
}: let
  inherit (beamPackages) erlang;
  # esqlite loads the pc plugin during its Rebar3 build, which cannot fetch
  # plugins from Hex inside the Nix sandbox.
  rebar3 = beamPackages.rebar3WithPlugins {plugins = [beamPackages.pc];};
  manifest = builtins.fromTOML (builtins.readFile ./manifest.toml);
  serverSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./gleam.toml
      ./manifest.toml
      ./src
      (lib.fileset.fileFilter (file: !file.hasExt "pyc") ./priv)
    ];
  };
  clientSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./cli/go.mod
      ./cli/go.sum
      ./cli/cmd
      ./cli/internal
      ./test/fixtures/build-digest
    ];
  };
  hexPackages =
    map (p: {
      inherit (p) name version;
      archive = fetchurl {
        url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
        sha256 = lib.toLower p.outer_checksum;
      };
    })
    manifest.packages;
  packageIndex = builtins.toFile "packages.toml" ("[packages]\n"
    + lib.concatMapStrings
    (p: "${p.name} = \"${p.version}\"\n")
    hexPackages
    + "\n[git]\n");
  renderSource = lib.fileset.toSource {
    root = ./native/render;
    fileset = lib.fileset.unions [
      ./native/render/Cargo.toml
      ./native/render/Cargo.lock
      ./native/render/src
      ./native/render/fonts
      ./native/render/tests
    ];
  };
  render = rustPlatform.buildRustPackage {
    pname = "albedo-render";
    version = "0.1.0";
    src = renderSource;
    cargoLock.lockFile = ./native/render/Cargo.lock;
    meta = {
      description = "renders a range of a source file as syntax-highlighted PNG pages";
      license = lib.licenses.wtfpl;
      mainProgram = "albedo-render";
      platforms = lib.platforms.unix;
    };
  };
  # The provide-usage CLI: a pure Zig core the daemon drives one round at a
  # time (see robot-docs/usage-feed.md). Pinned by the flake input, built with
  # the toolchain its build.zig.zon demands.
  usageCore = stdenv.mkDerivation {
    pname = "usage-core";
    version = "0.1.0";
    src = usage-core;
    # The knot serves the archive with a query string, so the store path has
    # no extension for unpackPhase to sniff: one explicit tar it is.
    unpackPhase = ''
      runHook preUnpack
      tar -xzf $src
      runHook postUnpack
    '';
    sourceRoot = "provide-usage-main";
    nativeBuildInputs = [zig];
    # The build.zig ranlib step hardcodes zig-out, so the default prefix it is
    # (no --prefix): artifacts are copied out in installPhase instead.
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      zig build --cache-dir "$TMPDIR/zig-cache" --global-cache-dir "$TMPDIR/zig-global-cache"
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp zig-out/bin/usage $out/bin/usage
      runHook postInstall
    '';
    meta = {
      description = "stateless provider usage and quota core with a CLI";
      mainProgram = "usage";
      platforms = lib.platforms.unix;
    };
  };
  server = stdenv.mkDerivation {
    pname = "albedo-server";
    version = "1.0.0";
    src = serverSource;
    nativeBuildInputs = [gleam erlang rebar3 makeWrapper];
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME" build/packages
      ${lib.concatMapStringsSep "\n" (p: ''
          mkdir -p build/packages/${p.name} "$TMPDIR/hex-${p.name}"
          tar -xf ${p.archive} -C "$TMPDIR/hex-${p.name}"
          tar -xzf "$TMPDIR/hex-${p.name}/contents.tar.gz" -C build/packages/${p.name}
        '')
        hexPackages}
      cp ${packageIndex} build/packages/packages.toml
      chmod -R u+w build/packages
      gleam export erlang-shipment
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/albedo $out/bin
      cp -R build/erlang-shipment/. $out/lib/albedo/
      # Kernels import this python from the read-only store, where Python
      # cannot cache bytecode, so each would compile it again (megabytes per
      # kernel). Hash-checked, because the store resets every mtime.
      ${python311}/bin/python3 -m compileall -q --invalidation-mode checked-hash \
        $out/lib/albedo/albedo/priv/python
      mkdir -p $out/lib/albedo/albedo/priv/bin
      ln -s ${render}/bin/albedo-render $out/lib/albedo/albedo/priv/bin/albedo-render
      ln -s ${usageCore}/bin/usage $out/lib/albedo/albedo/priv/bin/usage
      makeWrapper $out/lib/albedo/albedo/priv/bin/albedo-daemon $out/bin/albedo-daemon \
        --add-flags "$out/lib/albedo/entrypoint.sh run" \
        --set-default ALBEDO_BUILD $out/bin/albedo-daemon \
        --prefix PATH : ${lib.makeBinPath [erlang python311 bash coreutils render]}
      runHook postInstall
    '';
    meta = {
      description = "coding agent daemon with its runtime and native helpers";
      license = lib.licenses.wtfpl;
      mainProgram = "albedo-daemon";
      platforms = lib.platforms.unix;
    };
  };
  client = buildGoModule {
    pname = "albedo-client";
    version = "1.0.0";
    src = clientSource;
    modRoot = "cli";
    subPackages = ["cmd/albedo"];
    vendorHash = "sha256-Pl+bXHakJyxncOSWMI1FVpNui/LI/zgKg74nvjCwSKU=";
    nativeBuildInputs = [python311];
    ALBEDO_NO_BROWSER = "1";
    meta = {
      description = "Charm terminal client for the albedo coding agent";
      license = lib.licenses.wtfpl;
      mainProgram = "albedo";
      platforms = lib.platforms.unix;
    };
  };
in
  symlinkJoin {
    name = "albedo-${client.version}";
    paths = [client server];
    nativeBuildInputs = [makeWrapper];
    postBuild = ''
      rm $out/bin/albedo
      makeWrapper ${client}/bin/albedo $out/bin/albedo \
        --set-default ALBEDO_DAEMON ${server}/bin/albedo-daemon
    '';
    passthru = {
      inherit client server render usageCore;
      daemon = server;
    };
    meta =
      client.meta
      // {
        description = "coding agent daemon with a Charm terminal client";
      };
  }
