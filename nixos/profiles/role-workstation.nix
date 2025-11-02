# Workstation role profile
# Imports core personalities for desktop/laptop systems
# Individual hosts can add additional personalities as needed
{ config, pkgs, lib, ... }:

{
  imports = [
    ../personalities/base
    ../personalities/laptop
    ../personalities/development
  ];

  # Workstations typically need NetworkManager
  networking.networkmanager.enable = lib.mkDefault true;

  # Enable sound by default for workstations
  # (Configured in personalities/laptop/sound.nix)

  # Additional workstation-specific settings can be added here
  # User-specific personalities (ham, chat, backups, knowledge)
  # should be imported by individual host configurations
}
