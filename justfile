# Main justfile for Avalanche infrastructure management

# Root directory
root_dir := justfile_directory()
kubernetes_dir := root_dir / "kubernetes"

# Environment variables
# Note: KUBECONFIG and SOPS_AGE_KEY_FILE are set by direnv via .envrc
# kubernetes_dir is still needed for justfile recipes


# Import sub-justfiles as modules
mod nix '.justfiles/nix.just'
mod sops '.justfiles/sops.just'
mod sd '.justfiles/sd.just'
mod k8s '.justfiles/k8s.just'
mod vw '.justfiles/vw.just'

# Default recipe - list available commands
default:
    @just --list

# Run statix lint
lint:
    statix check .

# Format project files
format:
    nixpkgs-fmt {{justfile_directory()}}

# Install fish completions for just
install-fish-completions:
    #!/usr/bin/env bash
    set -euo pipefail
    FISH_COMPLETION_DIR="${HOME}/.config/fish/completions"
    mkdir -p "${FISH_COMPLETION_DIR}"
    cp "{{root_dir}}/scripts/completions/just.fish" "${FISH_COMPLETION_DIR}/just.fish"
    echo "Fish completions installed to ${FISH_COMPLETION_DIR}/just.fish"
    echo "Run 'exec fish' or 'source ~/.config/fish/completions/just.fish' to reload"
