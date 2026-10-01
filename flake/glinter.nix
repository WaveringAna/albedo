{
  lib,
  stdenv,
  fetchurl,
  gleam,
  beamPackages,
  makeWrapper,
  src,
}: let
  manifest = builtins.fromTOML (builtins.readFile "${src}/manifest.toml");
  packages =
    map (package: {
      inherit (package) name version;
      archive = fetchurl {
        url = "https://repo.hex.pm/tarballs/${package.name}-${package.version}.tar";
        sha256 = lib.toLower package.outer_checksum;
      };
    })
    manifest.packages;
  packageIndex = builtins.toFile "packages.toml" ("[packages]\n"
    + lib.concatMapStrings (package: "${package.name} = \"${package.version}\"\n") packages
    + "\n[git]\n");
in
  stdenv.mkDerivation {
    pname = "glinter";
    inherit (builtins.fromTOML (builtins.readFile "${src}/gleam.toml")) version;
    inherit src;
    nativeBuildInputs = [gleam beamPackages.erlang makeWrapper];
    buildPhase = ''
      runHook preBuild
      mkdir -p build/packages
      ${lib.concatMapStringsSep "\n" (package: ''
          mkdir -p build/packages/${package.name} "$TMPDIR/hex-${package.name}"
          tar -xf ${package.archive} -C "$TMPDIR/hex-${package.name}"
          tar -xzf "$TMPDIR/hex-${package.name}/contents.tar.gz" -C build/packages/${package.name}
        '')
        packages}
      cp ${packageIndex} build/packages/packages.toml
      chmod -R u+w build/packages
      gleam export erlang-shipment
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/glinter $out/bin
      cp -R build/erlang-shipment/. $out/lib/glinter/
      makeWrapper $out/lib/glinter/entrypoint.sh $out/bin/glinter \
        --add-flags run \
        --prefix PATH : ${lib.makeBinPath [beamPackages.erlang]}
      runHook postInstall
    '';
    meta = {
      description = "Gleam linter for development checks";
      license = lib.licenses.mit;
      mainProgram = "glinter";
      platforms = lib.platforms.unix;
    };
  }
