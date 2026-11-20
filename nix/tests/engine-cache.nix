{
  lib,
  pkgs,
  runCommand,
  python3,
  denialFlutter,
  denial,
  expectedRawEngine,
}:
let
  raw = denialFlutter.pinnedRawEngine;
  engine = denialFlutter.engine;
  probe = pkgs.callPackage ../engine-probe.nix {
    embedderHeader = "${raw}/out/host_release/flutter_embedder.h";
  };
  driver = "${pkgs.mesa}/lib/libgallium-${pkgs.mesa.version}.so";
in
assert lib.assertMsg (
  raw.drvPath == expectedRawEngine.drvPath
) "Host Nixpkgs changed the cached engine producer";
runCommand "denial-engine-cache-contract"
  {
    nativeBuildInputs = [
      python3
      pkgs.binutils
    ];
    exportReferencesGraph = [
      "runtime-closure"
      denial
    ];
  }
  ''
    python3 ${../engine-manifest.py} verify ${raw} \
      --source-lock ${../../prebuilt/flutter-engine/SOURCE_LOCK.json} \
      --nix-lock ${../flutter-engine-lock.json} --platform ${pkgs.stdenv.hostPlatform.system}
    ${probe}/bin/denial-engine-probe \
      ${engine}/out/host_release/libflutter_engine.so \
      ${denial.dartShell}/lib/libapp.so --driver ${driver} >engine-driver.log
    # The composed runtime must not retain another package set's libc.
    for path in $(sed -n '/^\/nix\/store\/.*-glibc-/p' runtime-closure); do
      case "$path" in
        ${pkgs.stdenv.cc.libc}|${lib.getBin pkgs.stdenv.cc.libc}) ;;
        *) echo "Unexpected runtime libc: $path" >&2; exit 1 ;;
      esac
    done
    mkdir -p $out
    cp engine-driver.log $out/
  ''
