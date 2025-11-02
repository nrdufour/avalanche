# Main justfile for Avalanche infrastructure management

# Root directory
root_dir := justfile_directory()
kubernetes_dir := root_dir / "kubernetes"

# Environment variables
export KUBECONFIG := kubernetes_dir / "main/kubeconfig"
export SOPS_AGE_KEY_FILE := env_var('HOME') / ".config/sops/age/keys.txt"

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
