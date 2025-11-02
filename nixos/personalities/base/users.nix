{ pkgs, lib, ... }: {
    users.users.ndufour = {
        isNormalUser = lib.mkDefault true;
        description = lib.mkDefault "Nicolas Dufour";
        extraGroups = lib.mkDefault [ "networkmanager" "wheel" "dialout" ];
        shell = lib.mkDefault pkgs.fish;
    };
}
