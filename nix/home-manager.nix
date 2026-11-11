self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.noctalia-monitors;

  # Where the plugin's Save button writes, per compositor (relative to the config dir).
  layoutFiles = {
    umbriel = "umbriel/monitors.toml";
    hyprland = "hypr/monitors.lua";
    niri = "niri/monitors.kdl";
  };
in {
  options.programs.noctalia-monitors = {
    enable = lib.mkEnableOption "the Noctalia monitors plugin";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "noctalia-monitors.packages.\${system}.default";
      description = "The plugin source package (a directory containing `monitors/`).";
    };

    sourceName = lib.mkOption {
      type = lib.types.str;
      default = "noctalia-monitors";
      description = "Name of the Noctalia plugin source that points at the package.";
    };

    layoutFiles = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames layoutFiles));
      default = [];
      example = ["umbriel"];
      description = ''
        Compositors to create an empty, writable layout file for, if it does not exist yet:
        `~/.config/umbriel/monitors.toml`, `~/.config/hypr/monitors.lua` or `~/.config/niri/monitors.kdl`.
        The plugin's Save button fills it in. The module never edits the compositor config:
        include the file there yourself (the panel shows the exact line).
      '';
    };
  };

  # Requires the Noctalia home-manager module (`programs.noctalia.settings`).
  config = lib.mkIf cfg.enable {
    # The plugin applies changes with wlr-randr.
    home.packages = [pkgs.wlr-randr];

    programs.noctalia.settings.plugins = {
      enabled = ["elotoja/monitors"];
      source = [
        {
          name = cfg.sourceName;
          kind = "path";
          location = "${cfg.package}";
          enabled = true;
        }
      ];
    };

    # A plain file, not a store symlink, so the plugin can overwrite it. An
    # existing file is never touched.
    home.activation.noctaliaMonitorsLayoutFiles = lib.mkIf (cfg.layoutFiles != []) (
      lib.hm.dag.entryAfter ["writeBoundary"] (
        lib.concatMapStringsSep "\n" (compositor: let
          path = "${config.xdg.configHome}/${layoutFiles.${compositor}}";
        in ''
          if [ ! -e ${lib.escapeShellArg path} ]; then
            run mkdir -p ${lib.escapeShellArg (dirOf path)}
            run touch ${lib.escapeShellArg path}
          fi
        '')
        cfg.layoutFiles
      )
    );
  };
}
