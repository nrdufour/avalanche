{ pkgs, lib, ... }: {
    users.users.ndufour = {
        isNormalUser = lib.mkDefault true;
        description = lib.mkDefault "Nicolas Dufour";
        extraGroups = lib.mkMerge [
            (lib.mkDefault [ "networkmanager" "wheel" "dialout" "input" ])
        ];
        shell = lib.mkDefault pkgs.fish;
    };
}
