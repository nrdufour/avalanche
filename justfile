# Main justfile for Avalanche infrastructure management

# Root directory
root_dir := justfile_directory()
kubernetes_dir := root_dir / "kubernetes"

# Environment variables
# Note: KUBECONFIG and SOPS_AGE_KEY_FILE are set by direnv via .envrc
# kubernetes_dir is still needed for justfile recipes


# Import sub-justfiles
import '.justfiles/nix.just'
import '.justfiles/sops.just'
import '.justfiles/sd.just'
import '.justfiles/k8s.just'

# Default recipe - list available commands
default:
    @just --list

# Run statix lint
lint:
    statix check .

# Format project files
format:
    nixpkgs-fmt {{justfile_directory()}}
