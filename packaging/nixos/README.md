# NixOS

Denial ships its Nix package, overlay, and NixOS module in this repository.
The Nix derivations build the Rust compositor, locked Denial Flutter engine,
embedded shell, and Settings from source. Normal installations reuse a separately
cached engine and adapt it to the host's dependencies; a cache miss builds that
same engine derivation from source. Denial release archives are not build inputs.

Add Denial to the flake that owns the NixOS system:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://denial.cachix.org" ];
    extra-trusted-public-keys = [
      "denial.cachix.org-1:wd8YTnvPmugFrtdMJWtR1XdVknR3/g2nmBJkT+vAruo="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    denial.url = "github:denialwm/denial";
  };

  outputs =
    { nixpkgs, denial, ... }:
    {
      nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          denial.nixosModules.default
          {
            programs.denial.enable = true;
            programs.denial.plugins.enable = true; # Optional Plugin Manager.
          }
        ];
      };
    };
}
```

Rebuild the system normally, then choose **Denial** in the existing display
manager. The module deliberately does not enable a display manager, select a
default session, or configure autologin.

`programs.denial.package` can replace the package without replacing the
module. When enabled, the module adds Denial's overlay and defaults to
`pkgs.denial`, built with the host's Nixpkgs dependencies. This keeps the
compositor's libc and graphics libraries aligned with the system's drivers,
including on NixOS unstable. The overlay also respects the host's package
overrides.

Plugin tooling is a separate `denial-plugin-manager` flake package and
`pkgs.denialPluginManager` overlay attribute. Set
`programs.denial.plugins.enable = true` to install it. Its wrapper puts the
exact locked Dart derivation in `PATH`; the main `pkgs.denial` closure does not
contain the Plugin Manager or compiler kit.

Denial derives every output from one Nixpkgs input: its own packages, the
module's `pkgs.denial`, and the Flutter build helper definitions. Select
another set the usual way, by making it follow yours:

```nix
inputs.denial.inputs.nixpkgs.follows = "nixpkgs";
```

The whole evaluation then uses that set, consistently: the compositor, the
shell and Settings, the engine, and the module's other packages. A host that
keeps Denial's input as it is builds exactly the derivations CI publishes to
the cache; one that follows another Nixpkgs rebuilds them against it.

Flutter and Skia source revisions remain pinned by `SOURCE_LOCK.json`. The
engine is another package of the set in use, so it links the same libc, loader
and graphics libraries as the compositor that maps it, and no adaptation step
rewrites its ELF paths. Compiler snapshots require the exact SDK hash, so the
Dart SDK stays paired with the engine even when another SDK reports the same
Dart version.

`denial.packages.x86_64-linux.denial` is the same derivation the module
installs, built from the Nixpkgs input, which is what CI publishes and what
the module's `pkgs.denial` evaluates to on a host that has not overridden the
input. The overlay applies the same expressions to a package set of your
choosing:

```nix
{
  nixpkgs.overlays = [ denial.overlays.default ];
  # pkgs.denial and pkgs.denialFlutter now use this system's package set.
}
```

The module also registers the Wayland session, Denial's Settings portal and
systemd user unit, the wlroots screenshot/screencast portal, Xwayland, polkit,
realtime scheduling, and Denial's CJK fallback font.

The module starts a PolicyKit authentication agent by default and enables I2C
access for DDC monitor controls. Existing desktop integrations can replace or
disable these defaults:

```nix
{ pkgs, ... }:
{
  programs.denial = {
    polkitAgent.enable = false;
    # Or retain the service with another absolute executable:
    # polkitAgent.command = "${pkgs.someAgent}/bin/some-agent";
    ddc.enable = false;
  };
}
```

Screen sharing uses an absolute Zenity executable path. Denial does not yet
implement layer-shell, so the module explicitly supplies this regular
xdg-shell chooser to `xdg-desktop-portal-wlr` instead of relying on its default
Slurp chooser.

Denial resolves its compositor, control client, Settings executable, Flutter
bundle, and packaged defaults from the installed package prefix. A Nix store
path is therefore supported directly; no `/usr/bin` compatibility links are
needed. Machine-specific configuration can still replace the packaged
defaults conventionally:

```nix
{
  environment.etc."denial/session.conf".source = ./session.conf;
  environment.etc."denial/outputs.conf".source = ./outputs.conf;
}
```

An ordinary writable `~/.config/denial/outputs.conf` remains the live display
state for compatibility. A read-only file or symlink there, including a Home
Manager link into the Nix store, is instead treated as declarative input. The
launcher gives Denial a writable copy at
`$XDG_STATE_HOME/denial/outputs.conf`; live changes persist until the
declarative source changes, at which point that source becomes the new state.
When no per-user file exists, `/etc/denial/outputs.conf` is the declarative
source and therefore follows later system rebuilds.

## Build resources and lock maintenance

Trusted `dev` and `main` validation builds publish Denial's Nix outputs to the
public `denial.cachix.org` cache. The top-level example repeats the cache URL
and signing key because Nix does not apply the `nixConfig` of a flake used only
as an input. Direct commands against the Denial flake can accept its identical
checked-in configuration with `--accept-flake-config`.

A host that keeps Denial's Nixpkgs input downloads the compositor, the shell,
Settings and the engine from the same cache. One that follows another Nixpkgs
builds them from the locked sources with that set, including the engine. No
engine artifact is re-linked or verified outside Nix's own derivation and
signature contract.

Overriding `programs.denial.package` with a package built from another Nixpkgs
mixes two sets again: after a host update, drivers loaded from
`/run/opengl-driver` can require glibc symbols the package's libc does not
provide. The module's default package is built from the system's set.

CI checks the Nixpkgs input: source locks, module integration with host
dependencies, the engine's build configuration, the packaged paths, and a
runtime contract that loads the engine and the shell bundle with the set's
Mesa driver in one process and requires a single libc in the composed closure.
A host that follows another Nixpkgs runs the same checks against it. Actual
graphics/session tests are recorded in
[the validation results](VALIDATION.md).

If startup reports GBM backend initialization failure for an already-open DRM
device, the device was opened successfully. A GBM `No such file or directory`
error can refer to loading a driver or its dependencies. Check the preceding
Mesa loader output on stderr or in the display manager's session logs for the
underlying error, including missing `GLIBC_*` symbols.

A cache miss still performs the complete source build and has
required more than 48 GiB of temporary Nix store space on the validation host;
plan a builder with at least 64 GiB of free working space. Subsequent builds
reuse Nix store objects, and source filtering keeps the engine and unrelated
Flutter applications from rebuilding.

The following checked-in locks make source changes explicit:

- `nix/flutter-engine-lock.json` records every fixed-output hash associated
  with `prebuilt/flutter-engine/SOURCE_LOCK.json`;
- the three `nix/*-pubspec-lock.json` files are generated representations of
  their authoritative Dart lock or Flutter tool input.

After advancing the engine source lock, run:

```sh
tools/denial-nix refresh-engine-lock
tools/denial-nix refresh-pub-locks
tools/denial-nix verify-locks
```

The helper obtains its pinned `jq` and `yq` maintenance tools from this flake,
so they do not need to be installed globally.

The regular `tools/denial-flutter-engine refresh-metadata` workflow invokes
the corresponding Nix refresh when its required tools are available. Nix
evaluation rejects a stale engine or Pub lock before a normal package build
can silently use it.

The flake currently exposes `x86_64-linux`; native AArch64 Nix output will be
added after its engine source closure is independently pinned and validated.
