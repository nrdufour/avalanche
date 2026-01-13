{ pkgs, ... }: {
    environment.systemPackages = with pkgs; [
        # Tools used by vscode extensions
        helm-ls

        # VS Code with FHS wrapper (allows mutable extensions in ~/.vscode/extensions)
        # Extensions are now managed imperatively via VS Code UI or `code --install-extension`
        # Backup of previous declarative extensions saved to ~/vscode-extensions-backup.txt
        unstable.vscode-fhs
    ];
}
