self: {
  config,
  options,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.noctalia-monitors;
  # The Umbriel home-manager module may not be imported at all.
  umbrielEnabled = config.programs.umbriel.enable or false;
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

    umbriel = {
      include = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Add the file written by the plugin's Save button to
          `programs.umbriel.settings.include.optional.files`, so saved layouts are loaded.
          Has no effect unless `programs.umbriel.enable` is set.
        '';
      };

      file = lib.mkOption {
        type = lib.types.str;
        default = "~/.config/umbriel/monitors.toml";
        description = "Path of the saved layout file, as written by the plugin.";
      };
    };
  };

  # Requires the Noctalia home-manager module (`programs.noctalia.settings`).
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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
    })

    # Umbriel loads the layout saved by the plugin from this file.
    (lib.optionalAttrs (options.programs ? umbriel) (lib.mkIf (cfg.enable && cfg.umbriel.include && umbrielEnabled) {
      programs.umbriel.settings.include.optional.files = [cfg.umbriel.file];
    }))
  ];
}
