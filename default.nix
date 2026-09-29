{
  lib,
  stdenv,
  rustPlatform,
  buildGoModule,
  fetchurl,
  gleam,
  beamPackages,
  python3,
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
  source = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./gleam.toml
      ./manifest.toml
      ./src
      (lib.fileset.fileFilter (file: !file.hasExt "pyc") ./priv)
      ./cli/go.mod
      ./cli/go.sum
      ./cli/cmd
      ./cli/internal
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
  daemon = stdenv.mkDerivation {
    pname = "albedo-daemon";
    version = "1.0.0";
    src = source;
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
      mkdir -p $out/lib/albedo/albedo/priv/bin
      ln -s ${render}/bin/albedo-render $out/lib/albedo/albedo/priv/bin/albedo-render
      ln -s ${usageCore}/bin/usage $out/lib/albedo/albedo/priv/bin/usage
      makeWrapper $out/lib/albedo/entrypoint.sh $out/bin/albedo-daemon \
        --add-flags run \
        --prefix PATH : ${lib.makeBinPath [erlang python3 bash coreutils render]}
      runHook postInstall
    '';
  };
in
  buildGoModule {
    pname = "albedo";
    version = "1.0.0";
    src = source;
    modRoot = "cli";
    subPackages = ["cmd/albedo"];
    vendorHash = "sha256-enSzYyW7Ku9JjLeRuzfBZsUgdAYb4P7vFGZkvPDZGSo=";
    nativeBuildInputs = [makeWrapper python3];
    ALBEDO_NO_BROWSER = "1";
    postInstall = ''
      wrapProgram $out/bin/albedo \
        --set-default ALBEDO_DAEMON ${daemon}/bin/albedo-daemon
    '';
    passthru = {inherit daemon render usageCore;};
    meta = {
      description = "coding agent daemon with a Charm terminal client";
      license = lib.licenses.wtfpl;
      mainProgram = "albedo";
      platforms = lib.platforms.unix;
    };
  }
