{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  # nativeBuildInputs is usually what you want -- tools you need to run
  nativeBuildInputs = with pkgs.buildPackages; [
    # Common tools
    just
    jq

    # NixOS tools
    statix
    nixpkgs-fmt
    nixos-rebuild

    # Kubernetes tools
    kubectl
    kubectl-cnpg
    fluxcd
    kubernetes-helm
    yamllint
    cmctl
    argocd
  ];
}
