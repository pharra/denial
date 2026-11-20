{
  pkgs,
  module,
  nixosSystem,
}:

let
  evaluated = nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      module
      {
        # A consumer overlay must reach Denial's native runtime rather than
        # being bypassed by self.packages from the flake's own package set.
        nixpkgs.overlays = [
          (_final: prev: {
            libgbm = prev.libgbm.overrideAttrs (_: {
              pname = "denial-module-host-libgbm";
            });
            libglvnd = prev.libglvnd.overrideAttrs (_: {
              pname = "denial-module-host-libglvnd";
            });
            fontconfig = prev.fontconfig.overrideAttrs (_: {
              pname = "denial-module-host-fontconfig";
            });
          })
        ];
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        programs.denial.enable = true;
        system.stateVersion = "26.05";
      }
    ];
  };
  cfg = evaluated.config;
  hostPkgs = evaluated.pkgs;
  expectedChooser = "GDK_DEBUG=no-portals ${hostPkgs.zenity}/bin/zenity --list --title='Share your screen' --text='Choose a source to share' --column='Source' --width=520 --height=320";
  disabledIntegrations = nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      module
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        programs.denial = {
          enable = true;
          polkitAgent.enable = false;
          ddc.enable = false;
        };
        system.stateVersion = "26.05";
      }
    ];
  };
  disabledCfg = disabledIntegrations.config;
in
pkgs.runCommand "denial-module-evaluation" { } ''
  test '${toString cfg.programs.denial.enable}' = 1
  test '${toString (cfg.programs.denial.package.drvPath == hostPkgs.denial.drvPath)}' = 1
  test '${toString (builtins.elem hostPkgs.libgbm cfg.programs.denial.package.compositor.buildInputs)}' = 1
  test '${
    toString (
      cfg.programs.denial.package.compositor.stdenv.cc.libc.drvPath == hostPkgs.stdenv.cc.libc.drvPath
    )
  }' = 1
  # The engine is this set's own build, not a re-linked artifact.
  test '${
    toString (hostPkgs.denialFlutter.engine.release.drvPath == hostPkgs.denialFlutter.engine.drvPath)
  }' = 1
  test '${
    toString (hostPkgs.denialFlutter.engine.nativeLibc.drvPath == hostPkgs.stdenv.cc.libc.drvPath)
  }' = 1
  test '${toString (hostPkgs.denialFlutter.engine.buildStrategy == "host-source")}' = 1
  test '${
    toString (hostPkgs.denialFlutter.dart.drvPath == hostPkgs.denialFlutter.engine.dart.drvPath)
  }' = 1
  test '${toString (builtins.elem "--slimpeller" hostPkgs.denialFlutter.engine.engineBuild.configureFlags)}' = 1
  test '${
    toString (
      pkgs.lib.hasInfix "denial-args.gn" (hostPkgs.denialFlutter.engine.engineBuild.preInstall or "")
    )
  }' = 1
  test '${toString (builtins.elem cfg.programs.denial.package cfg.services.displayManager.sessionPackages)}' = 1
  test '${toString cfg.security.polkit.enable}' = 1
  test '${toString cfg.security.rtkit.enable}' = 1
  test '${toString cfg.hardware.i2c.enable}' = 1
  test '${toString cfg.programs.xwayland.enable}' = 1
  test '${toString (builtins.elem hostPkgs.source-han-sans cfg.fonts.packages)}' = 1
  test '${cfg.xdg.portal.wlr.settings.screencast.chooser_type}' = dmenu
  test '${toString (cfg.xdg.portal.wlr.settings.screencast.chooser_cmd == expectedChooser)}' = 1
  test '${
    toString (
      cfg.systemd.user.services.denial-polkit-agent.serviceConfig.ExecStart == [
        ""
        "${cfg.programs.denial.package}/bin/denial-polkit-agent"
      ]
    )
  }' = 1
  test '${toString (builtins.elem "denial-session.target" cfg.systemd.user.services.denial-polkit-agent.wantedBy)}' = 1
  test '${toString (!disabledCfg.hardware.i2c.enable)}' = 1
  test '${toString (!disabledCfg.systemd.user.units."denial-polkit-agent.service".enable)}' = 1
  touch $out
''
