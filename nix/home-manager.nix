self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.noctalia-monitors;
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
  };
}
