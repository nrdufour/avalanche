{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    # Helix editor
    helix

    # Rust toolchain
    rustc
    cargo
    rustfmt
    clippy

    # LSP servers for languages used in this project

    # Nix
    nil # Nix LSP

    # Go (gopls already available via go-tools in default.nix)
    templ # Go HTML templating (used by sentinel)

    # YAML (Kubernetes manifests, configs)
    yaml-language-server

    # JSON
    vscode-langservers-extracted # provides JSON, HTML, CSS language servers

    # Bash/Shell
    nodePackages.bash-language-server
    shellcheck # shell linting

    # Rust
    rust-analyzer

    # Python
    pyright

    # Markdown
    marksman

    # TOML (Cargo.toml, config files)
    taplo

    # Tailwind CSS (used by sentinel)
    tailwindcss-language-server

    # Helm (Kubernetes)
    # helm-ls already in vscode.nix

    # Additional formatters/linters used by Helix
    nixfmt-rfc-style # Nix formatter
    nodePackages.prettier # JS/TS/JSON/YAML/MD formatter
  ];

  # Helix configuration (languages.toml and config.toml)
  # Users can customize further in ~/.config/helix/
}
