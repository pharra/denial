# Denial's optional live Flutter UI development runtime.
#
# `denialctl ui setup` materializes an editable checkout from the workspace
# template this package installs, and `denial-ui` prepares the JIT bundle the
# compositor then runs. Everything here must belong to the same locked Flutter
# generation as the running compositor: the JIT and profile engines are built
# from that source, and the Pub cache seed satisfies the shell's locked
# dependencies offline.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  runCommand,
  rustPlatform,
  pkg-config,
  fetchurl,
  denialFlutter,
  workspace,
  compositorSrc,
  version,
  sourceRevision,
  sourceRef ? "main",
  platform ? "linux-x64",
  # The profile engine is a second full engine build for the optional
  # performance-analysis workflow; the JIT runtime `denialctl ui setup` uses
  # does not need it.
  withProfileEngine ? true,
}:

let
  # The runtime refuses a template, cache seed or engine from another
  # generation, so read the generation from the compositor that defines it.
  generationLine = lib.findFirst (line: lib.hasInfix "FLUTTER_ENGINE_ABI: &str" line) "" (
    lib.splitString "\n" (builtins.readFile ../compositor/src/lib.rs)
  );
  generation = lib.elemAt (lib.splitString "\"" generationLine) 1;
  # Nixpkgs patches the Flutter tool to take its host platform from this
  # compile-time define instead of `uname`, and refuses an unknown value.
  systemPlatform = stdenvNoCC.hostPlatform.system;

  debugEngine = denialFlutter.debugEngine;
  profileEngine = if withProfileEngine then denialFlutter.profileEngine else null;
  debugEngineOut = "${debugEngine}/out/${debugEngine.outName}";
  profileEngineOut =
    if profileEngine == null then null else "${profileEngine}/out/${profileEngine.outName}";
  # The JIT and profile builds skip Flutter's GTK desktop embedder; Denial
  # never loads it, but `flutter assemble` expects the artifact set. Take it
  # from the release engine, whose own build still produces it.
  releaseEngineOut = "${denialFlutter.engine}/out/${denialFlutter.engine.outName}";
  sdk = denialFlutter.sdk;
  pubspecLock = lib.importJSON ./dart_shell-pubspec-lock.json;
  hostedPackages = lib.filterAttrs (_: package: package.source == "hosted") pubspecLock.packages;

  denialUi = rustPlatform.buildRustPackage {
    pname = "denial-ui";
    inherit version;
    src = compositorSrc;
    sourceRoot = "source/compositor";
    cargoLock = {
      lockFile = ../compositor/Cargo.lock;
      outputHashes = {
        "smithay-0.7.0" = "sha256-+Ey/zDrbQhw3FkY3Qn+NBaDofTr57KfZ919csFFXP10=";
        "smithay-drm-extras-0.1.0" = "sha256-+Ey/zDrbQhw3FkY3Qn+NBaDofTr57KfZ919csFFXP10=";
      };
    };
    nativeBuildInputs = [ pkg-config ];
    cargoBuildFlags = [
      "--package"
      "denial"
      "--bin"
      "denial-ui"
      "--no-default-features"
      "--features"
      "denial/ui-development"
    ];
    doCheck = false;
    meta.mainProgram = "denial-ui";
  };

  # The Flutter SDK view the live runtime compiles against: the pinned
  # framework and tool, the engine artifacts Flutter's own tool resolves from
  # `bin/cache/artifacts/engine`, and the shell's dart:ui declarations. The
  # layout is the one the released `denial-ui-development` package installs, so
  # `flutter assemble` finds every input offline and without `--local-engine`.
  flutterRuntime = runCommand "denial-ui-development-flutter" { } ''
    export HOME="$TMPDIR/home"
    mkdir --parents "$HOME" \
      $out/bin/cache/pkg \
      $out/bin/cache/artifacts/engine/common \
      $out/bin/cache/artifacts/engine/${platform} \
      $out/bin/cache/artifacts/engine/${platform}-profile \
      $out/packages
    cp --recursive ${sdk}/bin/internal $out/bin/internal
    cp --recursive ${sdk}/bin/cache/artifacts/material_fonts \
      $out/bin/cache/artifacts/material_fonts
    for cacheFile in ${sdk}/bin/cache/*.stamp ${sdk}/bin/cache/*.json \
      ${sdk}/bin/cache/engine.realm; do
      if [ -e "$cacheFile" ]; then
        cp "$cacheFile" $out/bin/cache/
      fi
    done
    # `version` is the legacy framework version file: the tool creates it when
    # it is missing, which a store path cannot accept.
    for frameworkFile in AUTHORS LICENSE PATENT_GRANT version; do
      cp ${sdk}/$frameworkFile $out/$frameworkFile
    done
    for frameworkPackage in flutter flutter_localizations flutter_test flutter_tools; do
      cp --recursive ${sdk}/packages/$frameworkPackage $out/packages/$frameworkPackage
    done
    cp --recursive ${debugEngineOut}/gen/dart-pkg/sky_engine $out/bin/cache/pkg/sky_engine
    if [ -d ${debugEngineOut}/gen/dart-pkg/flutter_gpu ]; then
      cp --recursive ${debugEngineOut}/gen/dart-pkg/flutter_gpu $out/bin/cache/pkg/flutter_gpu
    fi
    cp --recursive ${debugEngineOut}/flutter_patched_sdk \
      $out/bin/cache/artifacts/engine/common/flutter_patched_sdk
    # The tool reads these from the mode's engine directory, not from the
    # engine's `gen/` tree.
    for compilerInput in impellerc shader_lib font-subset icudtl.dat; do
      cp --recursive ${debugEngineOut}/$compilerInput \
        $out/bin/cache/artifacts/engine/${platform}/$compilerInput
    done
    cp ${debugEngineOut}/gen/const_finder.dart.snapshot \
      $out/bin/cache/artifacts/engine/${platform}/const_finder.dart.snapshot
    cp --recursive ${releaseEngineOut}/flutter_linux \
      $out/bin/cache/artifacts/engine/${platform}/flutter_linux
    cp ${releaseEngineOut}/libflutter_linux_gtk.so \
      $out/bin/cache/artifacts/engine/${platform}/libflutter_linux_gtk.so
    # A debug `copy_flutter_bundle` copies both snapshots out of the cache
    # before it drops them; the JIT engine supplies the real VM snapshots. The
    # engine defines the VM one as an empty placeholder
    # (`generated_file contents=""`) and builds the isolate one from the
    # patched SDK with `gen_snapshot --snapshot_kind=core`.
    touch $out/bin/cache/artifacts/engine/${platform}/vm_isolate_snapshot.bin
    ${releaseEngineOut}/gen_snapshot \
      --snapshot_kind=core \
      --enable_mirrors=false \
      --snapshot_data=$out/bin/cache/artifacts/engine/${platform}/isolate_snapshot.bin \
      --snapshot_text=$TMPDIR/isolate_snapshot_instructions.bin \
      $out/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill
    ${lib.optionalString withProfileEngine ''
      cp ${profileEngineOut}/gen_snapshot \
        $out/bin/cache/artifacts/engine/${platform}-profile/gen_snapshot
      cp --recursive ${releaseEngineOut}/flutter_linux \
        $out/bin/cache/artifacts/engine/${platform}-profile/flutter_linux
      cp ${releaseEngineOut}/libflutter_linux_gtk.so \
        $out/bin/cache/artifacts/engine/${platform}-profile/libflutter_linux_gtk.so
      # An AOT profile build snapshots with `Artifact.genSnapshot`, which the
      # tool resolves from the Android arm profile artifacts of the host.
      mkdir --parents $out/bin/cache/artifacts/engine/android-arm-profile/${platform}
      cp ${profileEngineOut}/gen_snapshot \
        $out/bin/cache/artifacts/engine/android-arm-profile/${platform}/gen_snapshot
    ''}
    # Flutter's own tool runs in front of the shell, so compile the same tool
    # sources Nixpkgs packages into the AOT image `dartaotruntime` executes.
    # Compiler snapshots, DevTools and analysis keep using the pinned VM.
    ln --symbolic ${sdk}/bin/cache/dart-sdk $out/bin/cache/dart-sdk
    # Compile the tool exactly as `cargo xtask flutter-tool-snapshot` does: an
    # AOT kernel, then an ELF snapshot. `dart compile` would resolve
    # dependencies again, and this build is offline. The host-platform define
    # is what Nixpkgs' Flutter patches read instead of `uname`.
    dart_sdk=$out/bin/cache/dart-sdk
    "$dart_sdk/bin/dartaotruntime" \
      "$dart_sdk/bin/snapshots/gen_kernel_aot.dart.snapshot" \
      --platform="$dart_sdk/lib/_internal/vm_platform_product.dill" \
      -Ddart.vm.product=true \
      -Ddart.vm.asan=false \
      -Ddart.vm.msan=false \
      -Ddart.vm.tsan=false \
      -DNIX_FLUTTER_HOST_PLATFORM=${systemPlatform} \
      --target-os=linux \
      --aot \
      --no-embed-sources \
      --output=$TMPDIR/flutter_tools.dill \
      --invocation-modes=compile \
      --verbosity=error \
      --packages=$out/packages/flutter_tools/.dart_tool/package_config.json \
      $out/packages/flutter_tools/bin/flutter_tools.dart
    "$dart_sdk/bin/utils/gen_snapshot" \
      --deterministic \
      --remove-script-timestamps-for-test \
      --target-unknown-cpu \
      --snapshot-kind=app-aot-elf \
      --elf=$out/bin/cache/flutter_tools.snapshot \
      $TMPDIR/flutter_tools.dill
    # Flutter treats an artifact set as current only when its stamp exists and
    # the directories it owns do. Otherwise `updateAll` downloads into
    # `bin/cache/downloads`, which a store path cannot accept. The view ships
    # the artifacts themselves, so record the bookkeeping here.
    engine_version="$(cat $out/bin/internal/engine.version)"
    # `engine_stamp` is the `informative` set the runner updates before every
    # command, including `assemble`.
    for stamp in engine_stamp flutter_sdk linux-sdk font-subset; do
      printf '%s' "$engine_version" > $out/bin/cache/$stamp.stamp
    done
    printf '%s' "$(cat $out/bin/internal/gradle_wrapper.version)" \
      > $out/bin/cache/gradle_wrapper.stamp
    # A Gradle wrapper, the release Linux artifacts and `flutter_gpu` are not
    # part of a debug desktop build, but each artifact set is checked whole.
    mkdir --parents \
      $out/bin/cache/artifacts/gradle_wrapper \
      $out/bin/cache/artifacts/engine/${platform}-release \
      $out/bin/cache/pkg/flutter_gpu
    printf 'name: flutter_gpu\nversion: 0.0.0\nenvironment:\n  sdk: ^3.5.0\n' \
      > $out/bin/cache/pkg/flutter_gpu/pubspec.yaml
    install -m755 ${./ui-development-flutter.sh} $out/bin/flutter
    substituteInPlace $out/bin/flutter \
      --replace-fail '@flutterRoot@' "$out"
  '';

  # The shell's locked dependencies, resolved offline exactly as the pinned
  # toolchain expects them: Pub reads hosted packages and their content
  # hashes from its cache, and the seed records the generation it belongs to.
  pubCacheSeed = runCommand "denial-ui-development-pub-cache" { } ''
    mkdir --parents $out/hosted/pub.dev $out/hosted-hashes/pub.dev
    ${lib.concatStrings (
      lib.mapAttrsToList (
        name: package:
        let
          archive = fetchurl {
            url = "${package.description.url}/packages/${package.description.name}/versions/${package.version}.tar.gz";
            sha256 = package.description.sha256;
          };
        in
        ''
          mkdir --parents $out/hosted/pub.dev/${name}-${package.version}
          tar --extract --gzip --file ${archive} \
            --directory $out/hosted/pub.dev/${name}-${package.version}
          # Pub stores the archive hash without a trailing newline and
          # compares the file byte for byte.
          printf '%s' '${package.description.sha256}' \
            > $out/hosted-hashes/pub.dev/${name}-${package.version}.sha256
        ''
      ) hostedPackages
    )}
    printf '%s\n' '${generation}' > $out/.denial-generation
  '';
in
assert lib.assertMsg (builtins.stringLength sourceRevision == 40) ''
  denial-ui-development records the Git revision `denialctl ui setup` checks
  out, so build it from a Git checkout of Denial (source revision: ${sourceRevision})
'';
stdenvNoCC.mkDerivation {
  pname = "denial-ui-development";
  inherit version;

  dontUnpack = true;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    # The client resolves its runtime from `DENIAL_UI_DEVELOPMENT_ROOT` or the
    # fixed `/usr` layout of a system package, so a Nix installation names its
    # own root instead of relying on a session variable.
    install -Dm755 ${denialUi}/bin/denial-ui $out/bin/denial-ui
    wrapProgram $out/bin/denial-ui \
      --set DENIAL_UI_DEVELOPMENT_ROOT $out/lib/denial/ui-development
    # `denial-flutter` is the Flutter tool passthrough by program name, which a
    # wrapper would rename, so it forwards the subcommand instead.
    cat > $out/bin/denial-flutter <<EOF
    #!${stdenvNoCC.shell}
    exec $out/bin/denial-ui flutter "\$@"
    EOF
    chmod 755 $out/bin/denial-flutter

    mkdir --parents $out/lib/denial/ui-development
    cp --recursive ${flutterRuntime} $out/lib/denial/ui-development/flutter
    install -Dm755 ${debugEngineOut}/libflutter_engine.so \
      $out/lib/denial/ui-development/lib/libflutter_engine.so
    ${lib.optionalString withProfileEngine ''
      install -Dm755 ${profileEngineOut}/libflutter_engine.so \
        $out/lib/denial/ui-development/profile/lib/libflutter_engine.so
    ''}
    install -Dm644 ${debugEngineOut}/icudtl.dat \
      $out/lib/denial/ui-development/data/icudtl.dat
    cp --recursive ${pubCacheSeed} $out/lib/denial/ui-development/pub-cache

    mkdir --parents $out/share/denial/ui-development
    cp --recursive ${workspace} $out/share/denial/ui-development/workspace
    chmod --recursive u+w $out/share/denial/ui-development/workspace
    install -Dm644 ${./ui-development-source.json} \
      $out/share/denial/ui-development/workspace/.denial-ui-source.json
    substituteInPlace $out/share/denial/ui-development/workspace/.denial-ui-source.json \
      --replace-fail '@generation@' '${generation}' \
      --replace-fail '@sourceRef@' '${sourceRef}' \
      --replace-fail '@sourceRevision@' '${sourceRevision}'
    # The editor configuration keeps the system defaults. `denialctl ui
    # setup` names the installation it was invoked from when it copies the
    # template, which also covers a runtime built from a checkout.

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    test -x $out/bin/denial-ui
    test -x $out/bin/denial-flutter
    grep --fixed-strings 'DENIAL_UI_DEVELOPMENT_ROOT' $out/bin/denial-ui
    test -f $out/lib/denial/ui-development/flutter/bin/cache/flutter_tools.snapshot
    test -f $out/lib/denial/ui-development/flutter/bin/cache/dart-sdk/bin/dartaotruntime
    test -f $out/lib/denial/ui-development/flutter/bin/cache/pkg/sky_engine/lib/ui/ui.dart
    test -f $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}/impellerc
    test -f $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}/const_finder.dart.snapshot
    test -f $out/lib/denial/ui-development/flutter/version
    test -f $out/lib/denial/ui-development/flutter/bin/cache/engine_stamp.stamp
    test -f $out/lib/denial/ui-development/flutter/bin/cache/flutter_sdk.stamp
    test -f $out/lib/denial/ui-development/flutter/bin/cache/linux-sdk.stamp
    test -f $out/lib/denial/ui-development/flutter/bin/cache/font-subset.stamp
    test -f $out/lib/denial/ui-development/flutter/bin/cache/gradle_wrapper.stamp
    test -d $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}-release
    test -d $out/lib/denial/ui-development/flutter/bin/cache/artifacts/gradle_wrapper
    test -f $out/lib/denial/ui-development/flutter/bin/cache/pkg/flutter_gpu/pubspec.yaml
    test -f $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}/isolate_snapshot.bin
    test -s $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}/isolate_snapshot.bin
    test -f $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/${platform}/vm_isolate_snapshot.bin
    test -f $out/lib/denial/ui-development/flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill
    test -f $out/lib/denial/ui-development/lib/libflutter_engine.so
    ${lib.optionalString withProfileEngine ''
      test -f $out/lib/denial/ui-development/profile/lib/libflutter_engine.so
    ''}
    test -f $out/lib/denial/ui-development/data/icudtl.dat
    test -f $out/lib/denial/ui-development/pub-cache/.denial-generation
    grep --fixed-strings '${generation}' \
      $out/lib/denial/ui-development/pub-cache/.denial-generation
    test -f $out/share/denial/ui-development/workspace/.denial-ui-source.json
    test -f $out/share/denial/ui-development/workspace/dart_shell/lib/main.dart
    test -f $out/share/denial/ui-development/workspace/plugins/denial_taskbar/pubspec.yaml
    grep --fixed-strings '"workspace": "dart_shell"' \
      $out/share/denial/ui-development/workspace/.denial-ui-source.json
    # The template ships the system layout, which `denialctl ui setup`
    # replaces with the paths of the installation it runs from.
    grep --fixed-strings \
      '/usr/lib/denial/ui-development/flutter/bin/cache/dart-sdk' \
      $out/share/denial/ui-development/workspace/dart_shell/.vscode/settings.json
    grep --fixed-strings '/usr/bin/denial-ui' \
      $out/share/denial/ui-development/workspace/dart_shell/.vscode/tasks.json
    grep --fixed-strings '/usr/bin/denial-flutter' \
      $out/share/denial/ui-development/workspace/dart_shell/.vscode/launch.json
    runHook postInstallCheck
  '';

  passthru = {
    inherit
      denialUi
      debugEngine
      pubCacheSeed
      flutterRuntime
      generation
      ;
  }
  // lib.optionalAttrs withProfileEngine { inherit profileEngine; };

  meta = {
    description = "Live Flutter UI development runtime for Denial";
    license = with lib.licenses; [
      gpl3Plus
      cc-by-sa-40
      ofl
    ];
    platforms = [ "x86_64-linux" ];
  };
}
