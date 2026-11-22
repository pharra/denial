{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.denial;
  # An enabled development runtime joins the compositor's own prefix, where
  # `denialctl` finds it, instead of relying on session variables that a
  # logged-in session never sees.
  denialPackage =
    if cfg.uiDevelopment.enable then
      pkgs.denial.override {
        uiDevelopment = cfg.uiDevelopment.package;
        uiDevelopmentSourceRemote = cfg.uiDevelopment.sourceRemote;
      }
    else
      pkgs.denial;
in
{
  options.programs.denial = {
    enable = lib.mkEnableOption "Denial, a Flutter-native Wayland compositor";
    package = lib.mkPackageOption pkgs "denial" { } // {
      default = denialPackage;
      defaultText = lib.literalExpression "pkgs.denial";
    };

    engine.buildFromSource = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build the locked release engine with the host's package set instead of
        reusing the pinned cache producer. Older libc or compiler runtimes
        automatically use this path. A cache miss otherwise builds the pinned
        producer from source without requiring this option.
      '';
    };

    plugins = {
      enable = lib.mkEnableOption "Denial's plugin development and composition tools";
      package = lib.mkPackageOption pkgs "denialPluginManager" { };
    };

    uiDevelopment = {
      enable = lib.mkEnableOption ''
        Denial's live Flutter UI development runtime
      '';
      package = lib.mkOption {
        type = lib.types.package;
        default =
          if cfg.uiDevelopment.profile then pkgs.denialUiDevelopmentProfile else pkgs.denialUiDevelopment;
        defaultText = lib.literalExpression "pkgs.denialUiDevelopment";
        description = ''
          Package providing the development runtime. Its default adds the
          profile engine only when {option}`profile` is enabled.
        '';
      };

      profile = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install the AOT profile engine as well, for building and profiling
          the shell in profile mode. It is a second full engine build, and
          live editing with `denialctl ui setup` does not need it.
        '';
      };

      sourceRemote = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://github.com/denialwm/denial.git";
        description = ''
          Repository `denialctl ui setup` clones the version-matched revision
          from. Unset keeps the official repository, which is wrong when this
          package was built from a fork or a private checkout.
        '';
      };
    };

    polkitAgent = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to run a PolicyKit authentication agent in Denial sessions.
          Disable this when another desktop component already provides one.
        '';
      };
      command = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.package}/bin/denial-polkit-agent";
        defaultText = lib.literalExpression ''
          "''${config.programs.denial.package}/bin/denial-polkit-agent"
        '';
        description = "Absolute command used for the PolicyKit authentication agent.";
      };
    };

    ddc.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable I2C device access for Denial's DDC monitor controls.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = lib.mkAfter (
      lib.optional cfg.engine.buildFromSource (
        final: _prev: { denialFlutter = final.denialFlutterSource; }
      )
    );
    environment.systemPackages = [
      cfg.package
      pkgs.zenity
    ]
    ++ lib.optional cfg.plugins.enable cfg.plugins.package;
    fonts.packages = [ pkgs.source-han-sans ];

    services.displayManager.sessionPackages = [ cfg.package ];
    services.graphical-desktop.enable = true;

    security.polkit.enable = true;
    security.rtkit.enable = true;
    hardware.i2c.enable = lib.mkDefault cfg.ddc.enable;
    programs.dconf.enable = lib.mkDefault true;
    programs.xwayland.enable = lib.mkDefault true;

    systemd.user.services.denial-polkit-agent = {
      enable = cfg.polkitAgent.enable;
      description = "PolicyKit authentication agent for Denial";
      documentation = [ "https://github.com/denialwm/denial" ];
      wantedBy = [ "denial-session.target" ];
      partOf = [ "denial-session.target" ];
      after = [ "graphical-session-pre.target" ];
      serviceConfig = {
        # This becomes a drop-in for the packaged unit. Clear its command
        # before applying the configurable one; simple services allow only one.
        ExecStart = [
          ""
          cfg.polkitAgent.command
        ];
        Restart = "on-failure";
        RestartSec = "250ms";
      };
    };

    services.dbus.packages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    environment.etc."systemd/system-sleep/denial-suspend-mode".source =
      "${cfg.package}/lib/systemd/system-sleep/denial-suspend-mode";

    xdg.portal = {
      enable = lib.mkDefault true;
      wlr = {
        enable = true;
        settings.screencast = {
          # Denial does not expose layer-shell yet, so slurp cannot be used as
          # the chooser. Keep this absolute: the wlr portal does not inherit
          # the interactive session's PATH on NixOS.
          # xdpw waits for the chooser, so GTK must not call back into portals.
          chooser_type = "dmenu";
          chooser_cmd = "GDK_DEBUG=no-portals ${pkgs.zenity}/bin/zenity --list --title='Share your screen' --text='Choose a source to share' --column='Source' --width=520 --height=320";
        };
      };
      extraPortals = [
        cfg.package
        pkgs.xdg-desktop-portal-gtk
      ];
      config.denial = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Settings" = [
          "denial"
          "gtk"
        ];
        "org.freedesktop.impl.portal.Access" = [
          "denial"
          "gtk"
        ];
        "org.freedesktop.impl.portal.ScreenCast" = "wlr";
        "org.freedesktop.impl.portal.Screenshot" = "wlr";
      };
    };
  };
}
