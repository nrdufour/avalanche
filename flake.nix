{
  description = "Avalanche - Unified infrastructure monorepo";

  inputs = {
    # Nixpkgs and unstable
    # Primary source: GitHub (fast, reliable)
    # Backup mirror available at forge.internal/Mirrors/nixpkgs (synced every 8h)
    # See docs/guides/github-outage-mitigation.md for using the mirror during GitHub outages
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # nix-community hardware quirks
    # https://github.com/nix-community/nixos-hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # NUR - Nix User Repository
    nur.url = "github:nix-community/NUR";

    # sops-nix - secrets with mozilla sops
    # https://github.com/Mic92/sops-nix
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # VSCode community extensions (for workstations)
    # https://github.com/nix-community/nix-vscode-extensions
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # LLM Agents
    llm-agents.url = "github:numtide/llm-agents.nix";

    # dns.nix - Type-safe DNS zone definitions
    # https://github.com/nix-community/dns.nix
    dns = {
      url = "github:nix-community/dns.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Sentinel gateway dashboard
    sentinel = {
      url = "git+https://forge.internal/nemo/sentinel.git";
      flake = false;  # Not a flake, just source
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, sops-nix, ... }@inputs:
    let
      inherit (self) outputs;
    in
    {
      # Extend lib with custom functions
      lib = nixpkgs.lib.extend (
        final: prev: {
          inherit inputs;
          myLib = import ./nixos/lib { inherit inputs; lib = final; };
        }
      );

      nixosConfigurations =
        with self.lib;
        let
          # Make lib available for mkNixosConfig
          inherit (self) lib;

          specialArgs = {
            inherit inputs outputs;
          };

          # Import overlays for building nixosconfig with them
          overlays = import ./nixos/overlays { inherit inputs; };

          # Generate a base nixos configuration with the
          # specified overlays, hardware modules, and any extraModules applied
          mkNixosConfig =
            { hostname
            , system ? "x86_64-linux"
            , nixpkgs ? inputs.nixpkgs
            , hardwareModules ? [ ]
              # baseModules is the base of the entire machine building
              # here we import all the modules and setup everything
            , baseModules ? [
                sops-nix.nixosModules.sops
                ./nixos/profiles/global.nix # all machines get a global profile
                ./nixos/modules/nixos # all machines get nixos modules
                ./nixos/hosts/${hostname} # load this host's config folder
              ]
            , profileModules ? [ ]
            , stateVersion ? "23.11" # first system on nixos was on 23.11
            }:
            nixpkgs.lib.nixosSystem {
              inherit system lib;
              modules =
                baseModules
                ++ hardwareModules
                ++ profileModules
                ++ [ (_: { system.stateVersion = stateVersion; }) ];
              specialArgs = { inherit self inputs nixpkgs; };

              # Add our overlays
              pkgs = import nixpkgs {
                inherit system;
                overlays = builtins.attrValues overlays;
                config = {
                  allowUnfree = true;
                  allowUnfreePredicate = _: true;
                  # Enable DRM protected content in chromium (for workstations)
                  chromium.enableWideVine = true;
                };
              };
            };
        in
        {
          # Infrastructure services (from snowpea)
          eagle = mkNixosConfig {
            hostname = "eagle";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          mysecrets = mkNixosConfig {
            hostname = "mysecrets";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          possum = mkNixosConfig {
            hostname = "possum";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          # K3s Worker Nodes: Raspberry Pi 4 (from snowpea)
          raccoon00 = mkNixosConfig {
            hostname = "raccoon00";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          raccoon01 = mkNixosConfig {
            hostname = "raccoon01";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          raccoon02 = mkNixosConfig {
            hostname = "raccoon02";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          raccoon03 = mkNixosConfig {
            hostname = "raccoon03";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          raccoon04 = mkNixosConfig {
            hostname = "raccoon04";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          raccoon05 = mkNixosConfig {
            hostname = "raccoon05";
            system = "aarch64-linux";
            hardwareModules = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              ./nixos/profiles/hw-rpi4.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-worker.nix
            ];
          };

          # K3s Controller Nodes: Orange Pi 5 Plus (from snowpea)
          opi01 = mkNixosConfig {
            hostname = "opi01";
            system = "aarch64-linux";
            hardwareModules = [
              ./nixos/profiles/hw-orangepi5plus.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-controller.nix
            ];
          };

          opi02 = mkNixosConfig {
            hostname = "opi02";
            system = "aarch64-linux";
            hardwareModules = [
              ./nixos/profiles/hw-orangepi5plus.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-controller.nix
            ];
          };

          opi03 = mkNixosConfig {
            hostname = "opi03";
            system = "aarch64-linux";
            hardwareModules = [
              ./nixos/profiles/hw-orangepi5plus.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
              ./nixos/profiles/role-k3s-controller.nix
            ];
          };

          # x86 Servers (from snowpea)
          beacon = mkNixosConfig {
            hostname = "beacon";
            system = "x86_64-linux";
            hardwareModules = [
              ./nixos/profiles/hw-acer-minipc.nix
            ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          routy = mkNixosConfig {
            hostname = "routy";
            system = "x86_64-linux";
            stateVersion = "25.05";
            hardwareModules = [ ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          cardinal = mkNixosConfig {
            hostname = "cardinal";
            system = "x86_64-linux";
            stateVersion = "25.05";
            hardwareModules = [ ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          hawk = mkNixosConfig {
            hostname = "hawk";
            system = "x86_64-linux";
            stateVersion = "25.11";
            hardwareModules = [ ];
            profileModules = [
              ./nixos/profiles/role-server.nix
            ];
          };

          # Workstation: calypso (from snowy)
          calypso = mkNixosConfig {
            hostname = "calypso";
            system = "x86_64-linux";
            stateVersion = "24.05";
            hardwareModules = [
              inputs.nixos-hardware.nixosModules.asus-rog-strix-g513im
            ];
            profileModules = [
              ./nixos/profiles/role-workstation.nix
            ];
          };

          # Placeholder: cloud hosts will be added here
        };

      # Convenience output that aggregates all system builds
      # Also used in CI to build targets generally
      top =
        let
          nixtop = nixpkgs.lib.genAttrs
            (builtins.attrNames inputs.self.nixosConfigurations)
            (attr: inputs.self.nixosConfigurations.${attr}.config.system.build.toplevel);
        in
        nixtop;
    };
}
