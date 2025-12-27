# SOPS secrets management commands

# List available sops recipes
default:
    @just --list sops

# Update all sops secrets
update:
    #!/usr/bin/env bash
    set -euo pipefail

    # Change to the repository root (where justfile is located)
    cd "{{justfile_directory()}}"

    SECRET_FILES=$(find . -type f -name '*.sops.yaml' ! -name ".sops.yaml")

    if [ -z "$SECRET_FILES" ]; then
        echo "No SOPS secret files found"
        exit 0
    fi

    for file in $SECRET_FILES; do
        echo "Updating $file"
        sops updatekeys "$file"
    done

    echo "All SOPS secrets updated"
