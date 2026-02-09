{ pkgs, ... }: {
    imports = [
        ./zwo-udev.nix
    ];

    environment.systemPackages = with pkgs; [
        # INDI server with all drivers including unfree ones (ZWO ASI driver: indi_asi_ccd)
        # indi-full only includes free-licensed drivers; indi-full-nonfree adds
        # unfree drivers like indi-asi which depends on ZWO's proprietary libasi SDK
        indi-full-nonfree

        # KStars includes Ekos for camera control and capture
        kstars

        # Java runtime for FireCapture (run manually: java -jar FireCapture.jar)
        jdk

        # Post-processing
        siril
    ];

    # Verification steps:
    #   lsusb | grep -i zwo
    #   indiserver -v indi_asi_ccd
    #   Connect via KStars/Ekos to localhost:7624
}
