{ pkgs, ... }: {
    programs.steam = {
        enable = true;
        remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
        dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
        extest.enable = true; # Load extest library for input event translation on Wayland/XWayland
    };

    programs.nix-ld.enable = true;

    programs.gamemode.enable = true;
    programs.gamescope.enable = true;

    # Allow Steam to access input devices for remote play
    # /dev/uinput: for injecting input events
    # /dev/input/event*: for reading input events
    services.udev.extraRules = ''
        KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
        KERNEL=="event[0-9]*", SUBSYSTEM=="input", MODE="0660", GROUP="input"
    '';

    # Ensure the 'input' group exists and add user to it
    users.groups.input = {};
    users.extraGroups.input.members = [ "ndufour" ];

    environment.systemPackages = with pkgs; [
        # Lutris platform
        ## See https://nixos.wiki/wiki/Lutris for more
        lutris

        # for minecraft
        prismlauncher
        
        (atlauncher.override { 
            additionalLibs = [
                xorg.libX11
                xorg.libXcursor
                xorg.libXext
                xorg.libXrender
                xorg.libXtst
                xorg.libXi
                xorg.libXrandr
            ];
        })
    ];
}