{
  description = "Avalanche - Unified infrastructure monorepo";

  inputs = {
    # Nixpkgs and unstable
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
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
                };
              };
            };
        in
        {
          # Workstation: calypso (from snowy)
          # Will be migrated in next step

          # Infrastructure services
          # Will be migrated from snowpea in next step

          # K3s cluster hosts
          # Will be migrated from snowpea in next step

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
