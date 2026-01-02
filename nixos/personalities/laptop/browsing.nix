{
  pkgs,
  ...
}: {

  environment.systemPackages = with pkgs; [

    # Actual browsing
    firefox       # as the default
    librewolf     # as the "burner"
    vivaldi       # as the contender
    google-chrome # for peculiar sites
    tor-browser   # really safe browsing

    # Emails
    thunderbird
  ];


  # Enable drm protected content playing in chrome
  # Note: chromium.enableWideVine moved to flake.nix pkgs config
  # to avoid conflict with externally created pkgs instance
  # nixpkgs.config = {
  #     chromium = {
  #         enableWideVine = true;
  #     };
  # };
}