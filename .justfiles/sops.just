# SOPS secrets management commands

# List available sops recipes
default:
    @just --list sops

# Update all sops secrets
update:
    #!/usr/bin/env bash
    set -euo pipefail
    SECRET_FILES=$(find . -type f -name '*.sops.yaml' ! -name ".sops.yaml")
    for file in $SECRET_FILES; do
        echo "Updating $file"
        sops updatekeys "$file"
    done
