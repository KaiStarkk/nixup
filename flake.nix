{
  description = "Fast NixOS package update checker - like 'pacman -Qu' for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      checker = pkgs.callPackage ./nixup.nix {};
    in {
      default = checker;
      nixup = checker;
      nix-update-popup = pkgs.callPackage ./nix-update-popup.nix {
        nixup = checker;
        yad = pkgs.yad;
        zenity = pkgs.zenity;
      };
    });

    # Overlay for easy integration into NixOS configs
    overlays.default = final: prev: {
      nixup = self.packages.${final.system}.nixup;
      nix-update-popup = self.packages.${final.system}.nix-update-popup;
    };

    # Home Manager module
    homeManagerModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.nixup;
      checker = self.packages.${pkgs.system}.nixup;
      popup = self.packages.${pkgs.system}.nix-update-popup;
    in {
      options.services.nixup = {
        enable = lib.mkEnableOption "nixup service";

        interval = lib.mkOption {
          type = lib.types.str;
          default = "6h";
          description = "How often to check for updates (systemd timer format)";
        };

        onBoot = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run check shortly after boot";
        };

        bootDelay = lib.mkOption {
          type = lib.types.str;
          default = "2min";
          description = "Delay after boot before first check";
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = [checker popup];

        systemd.user.services.nixup = {
          Unit.Description = "Nix package update checker";
          Service = {
            Type = "oneshot";
            ExecStart = "${checker}/bin/nixup refresh";
            Environment = [
              "XDG_CACHE_HOME=%h/.cache"
              "HOME=%h"
            ];
          };
        };

        systemd.user.timers.nixup = {
          Unit.Description = "Nix package update checker timer";
          Install.WantedBy = ["timers.target"];
          Timer = {
            OnBootSec = lib.mkIf cfg.onBoot cfg.bootDelay;
            OnUnitActiveSec = cfg.interval;
            Persistent = true;
          };
        };
      };
    };
  };
}
