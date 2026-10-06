{
  lib,
  runCommand,
  stdenv,
  playwright-driver,
}: let
  directories = {
    aarch64-darwin = "chrome-headless-shell-mac-arm64";
    aarch64-linux = "chrome-headless-shell-linux-arm64";
    x86_64-linux = "chrome-headless-shell-linux64";
  };
  directory = directories.${stdenv.hostPlatform.system};
  browser = playwright-driver.components.chromium-headless-shell;
  version = playwright-driver.browsersJSON.chromium-headless-shell.browserVersion;
in
  runCommand "chrome-headless-shell-${version}" {
    meta = {
      description = "Chrome's standalone headless browser";
      mainProgram = "chrome-headless-shell";
      platforms = lib.attrNames directories;
    };
  } ''
    mkdir -p "$out/bin"
    ln -s ${browser}/${directory}/chrome-headless-shell "$out/bin/chrome-headless-shell"
  ''
