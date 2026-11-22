{
  src ? ../.,
  version ? "0.0.0+unknown",
  buildIdentity ? "nix.unknown",
  sourceRevision ? "unknown",
  flutterNixpkgs ? null,
  pluginCollection ? null,
  # The denial-apps and gpui-touch commits settings/SOURCE_LOCK.json names.
  denialApps ? null,
  gpuiTouch ? null,
  # The branch `denialctl ui setup` clones before checking out the revision.
  uiDevelopmentSourceRef ? "main",
  uiDevelopmentSourceRevision ? sourceRevision,
}:

final: _prev:
let
  cleanSrc = final.lib.cleanSourceWith {
    name = "source";
    inherit src;
    filter =
      path: type:
      let
        name = baseNameOf (toString path);
      in
      !(
        type == "directory"
        && builtins.elem name [
          ".dart_tool"
          ".git"
          "build"
          "out"
          "profiling"
          "target"
        ]
      )
      && name != "libflutter_engine.so";
  };
in
{
  denialFlutter = final.callPackage ./flutter-engine.nix (
    final.lib.optionalAttrs (flutterNixpkgs != null) { inherit flutterNixpkgs; }
  );
  denialFlutterSource = final.callPackage ./flutter-engine.nix (
    {
      buildEngineFromSource = true;
    }
    // final.lib.optionalAttrs (flutterNixpkgs != null) { inherit flutterNixpkgs; }
  );
  denial = final.callPackage ./package.nix {
    src = cleanSrc;
    inherit version buildIdentity sourceRevision;
    taskbarSrc =
      if pluginCollection == null then null else pluginCollection + "/plugins/denial_taskbar";
    denialAppsSrc = denialApps;
    gpuiTouchSrc = gpuiTouch;
  };
  denialPluginManager = final.denial.pluginManager;
  # Optional live UI development: the native client, a JIT engine, the pinned
  # toolchain and the editable workspace template.
  denialUiDevelopment = final.callPackage ./ui-development.nix {
    inherit version;
    sourceRevision = uiDevelopmentSourceRevision;
    sourceRef = uiDevelopmentSourceRef;
    denialFlutter = final.denialFlutter;
    workspace = final.denial.uiWorkspaceSource;
    compositorSrc = final.denial.compositorSource;
    withProfileEngine = false;
  };
  # The same package with the profile engine, for the performance-analysis
  # workflow. It is a second full engine build, so it stays opt-in.
  denialUiDevelopmentProfile = final.callPackage ./ui-development.nix {
    inherit version;
    sourceRevision = uiDevelopmentSourceRevision;
    sourceRef = uiDevelopmentSourceRef;
    denialFlutter = final.denialFlutter;
    workspace = final.denial.uiWorkspaceSource;
    compositorSrc = final.denial.compositorSource;
    withProfileEngine = true;
  };
}
