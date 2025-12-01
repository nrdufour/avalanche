{ pkgs, ... }: {
    imports = [
        ./custom_kernel.nix
        ./sound.nix
        ./fonts.nix
        ./dm
        ./printing.nix
        ./gaming.nix
        ./video.nix
        ./bluetooth.nix
        ./asusd.nix
        ./browsing.nix
    ];

    # Prevent the laptop to suspend when the lid is closed and still on external power
    services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

    environment.systemPackages = with pkgs; [
        inkscape
        unstable.discord
        gnome-tweaks
        koreader
        gimp
    ];
}