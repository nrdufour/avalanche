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

    # Sunshine: open-source remote play server for Moonlight clients
    services.sunshine = {
        enable = true;
        autoStart = true;
        capSysAdmin = true;
        openFirewall = true;
    };

    # Avahi for Sunshine mDNS discovery
    services.avahi.publish.enable = true;
    services.avahi.publish.userServices = true;

    # Allow Steam to access input devices for remote play
    # /dev/uinput: for injecting input events
    # /dev/input/event*: for reading input events
    services.udev.extraRules = ''
        KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
        KERNEL=="event[0-9]*", SUBSYSTEM=="input", MODE="0660", GROUP="input"
    '';

    # Ensure input/video groups exist and add user to them
    # input: for /dev/uinput access (input injection)
    # video: for /dev/dri/* access (GPU frame capture for Remote Play)
    users.groups.input = {};
    users.groups.video = {};
    users.extraGroups.input.members = [ "ndufour" ];
    users.extraGroups.video.members = [ "ndufour" ];

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