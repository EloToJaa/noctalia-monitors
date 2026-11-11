{
  description = "Monitor configuration panel plugin for the Noctalia shell (Umbriel)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};

        # A Noctalia *source*: a directory holding one subdirectory per plugin,
        # named after the part of the plugin id after the "/".
        # Point a `kind = "path"` plugin source at the output of this package.
        noctalia-monitors = pkgs.stdenvNoCC.mkDerivation {
          pname = "noctalia-monitors";
          version = "0.1.0";
          src = ./monitors;

          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/monitors
            cp -r ./. $out/monitors/
            runHook postInstall
          '';

          meta = {
            description = "Monitor configuration panel plugin for Noctalia (Umbriel)";
            homepage = "https://github.com/EloToJaa/noctalia-monitors";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux;
          };
        };
      in {
        packages = {
          default = noctalia-monitors;
          inherit noctalia-monitors;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            luau
            luau-lsp
            wlr-randr
            jq
            just
            alejandra
          ];
        };

        formatter = pkgs.alejandra;
      }
    )
    // {
      # Home Manager module: registers the plugin source and enables the plugin
      # in the Noctalia config. See README for usage.
      homeModules.default = import ./nix/home-manager.nix self;
    };
}
