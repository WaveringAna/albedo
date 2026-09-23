{ lib, stdenv, buildGoModule, fetchurl, gleam, beamPackages, rebar3, python3, bash, coreutils, makeWrapper }:
let
  erlang = beamPackages.erlang;
  manifest = builtins.fromTOML (builtins.readFile ./manifest.toml);
  source = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./gleam.toml ./manifest.toml ./src
      (lib.fileset.fileFilter (file: !file.hasExt "pyc") ./priv)
      ./cli/go.mod ./cli/go.sum ./cli/cmd ./cli/internal
    ];
  };
  hexPackages = map (p: {
    inherit (p) name version;
    archive = fetchurl {
      url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
      sha256 = lib.toLower p.outer_checksum;
    };
  }) manifest.packages;
  packageIndex = builtins.toFile "packages.toml" ("[packages]\n" + lib.concatMapStrings
    (p: "${p.name} = \"${p.version}\"\n") hexPackages + "\n[git]\n");
  daemon = stdenv.mkDerivation {
    pname = "albedo-daemon";
    version = "1.0.0";
    src = source;
    nativeBuildInputs = [ gleam erlang rebar3 makeWrapper ];
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME" build/packages
      ${lib.concatMapStringsSep "\n" (p: ''
        mkdir -p build/packages/${p.name} "$TMPDIR/hex-${p.name}"
        tar -xf ${p.archive} -C "$TMPDIR/hex-${p.name}"
        tar -xzf "$TMPDIR/hex-${p.name}/contents.tar.gz" -C build/packages/${p.name}
      '') hexPackages}
      cp ${packageIndex} build/packages/packages.toml
      chmod -R u+w build/packages
      gleam export erlang-shipment
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/albedo $out/bin
      cp -R build/erlang-shipment/. $out/lib/albedo/
      makeWrapper $out/lib/albedo/entrypoint.sh $out/bin/albedo-daemon \
        --add-flags run \
        --prefix PATH : ${lib.makeBinPath [ erlang python3 bash coreutils ]}
      runHook postInstall
    '';
  };
in buildGoModule {
  pname = "albedo";
  version = "1.0.0";
  src = source;
  modRoot = "cli";
  subPackages = [ "cmd/albedo" ];
  vendorHash = "sha256-6zL5hCue5V3Vjv42iRyZqBzF/OWum6sJ9YktyT2OOgM=";
  nativeBuildInputs = [ makeWrapper ];
  ALBEDO_NO_BROWSER = "1";
  postInstall = ''
    wrapProgram $out/bin/albedo \
      --set-default ALBEDO_DAEMON ${daemon}/bin/albedo-daemon
  '';
  passthru = { inherit daemon; };
  meta = {
    description = "coding agent daemon with a Charm terminal client";
    license = lib.licenses.wtfpl;
    mainProgram = "albedo";
    platforms = lib.platforms.unix;
  };
}
