# SD card image management commands

# List available sd recipes
default:
    @just --list sd

# Build the SD card image for a host
build host:
    nix build -L .#nixosConfigurations.{{host}}.config.system.build.sdImage

# Flash the SD card image (with rpi-imager)
flash host:
    just sd build {{host}}
    nix-shell -p rpi-imager --run "QT_QPA_PLATFORM=wayland rpi-imager ./result/sd-image/{{host}}.img.zst"
