# What a cached engine must guarantee on the host that runs it.
{
  lib,
  pkgs,
  runCommand,
  denialFlutter,
  denial,
}:
let
  engine = denialFlutter.engine;
  probe = pkgs.callPackage ../engine-probe.nix {
    embedderHeader = "${engine}/out/host_release/flutter_embedder.h";
  };
  driver = "${pkgs.mesa}/lib/libgallium-${pkgs.mesa.version}.so";
in
runCommand "denial-engine-runtime-contract"
  {
    nativeBuildInputs = [
      pkgs.binutils
    ];
    exportReferencesGraph = [
      "runtime-closure"
      denial
    ];
  }
  ''
    # The engine and the shell bundle load with this set's Mesa driver, and
    # their Flutter and Denial extension symbols resolve in one process.
    ${probe}/bin/denial-engine-probe \
      ${engine}/out/host_release/libflutter_engine.so \
      ${denial.dartShell}/lib/libapp.so --driver ${driver} >engine-driver.log

    # The composed runtime must hold one libc: the one it was built against.
    for path in $(sed -n '/^\/nix\/store\/.*-glibc-/p' runtime-closure); do
      case "$path" in
        ${pkgs.stdenv.cc.libc}|${lib.getBin pkgs.stdenv.cc.libc}) ;;
        *) echo "Unexpected runtime libc: $path" >&2; exit 1 ;;
      esac
    done

    mkdir -p $out
    cp engine-driver.log $out/
  ''
