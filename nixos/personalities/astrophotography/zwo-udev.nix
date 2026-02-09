{ ... }: {
    # Unprivileged access to ZWO ASI cameras (vendor ID 03c3)
    services.udev.extraRules = ''
        SUBSYSTEM=="usb", ATTR{idVendor}=="03c3", MODE="0666"
    '';
}
