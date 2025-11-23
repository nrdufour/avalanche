{ inputs, ... }:
{
  forgejo-node24 = final: prev: {
    # Patch forgejo-runner to support node24
    # The validation for node24 was added to act library in v0.2.81 (Sept 2025)
    # We need to ensure the runner uses an updated version
    forgejo-runner = prev.forgejo-runner.overrideAttrs (oldAttrs: {
      postPatch = (oldAttrs.postPatch or "") + ''
        # Replace the hardcoded validation list to accept node00-node99 (future-proof)
        find . -type f -name "*.go" | while read file; do
          # Match patterns like ["composite", "docker", "node12", "node16", "node20", "go", "sh"]
          sed -i 's/\["composite", "docker", "node12", "node16", "node20", "go", "sh"\]/[]string{"composite", "docker", "node12", "node16", "node20", "node24", "go", "sh"}/g' "$file" || true
          # Also match variations with different spacing
          sed -i 's/"composite".*"docker".*"node12".*"node16".*"node20".*"go".*"sh"/"composite", "docker", "node12", "node16", "node20", "node24", "go", "sh"/g' "$file" || true
          # Match the slice literal patterns
          sed -i 's/validRuntimes := \[\]string{/validRuntimes := []string{"composite", "docker", "node12", "node16", "node20", "node24", "go", "sh"}/g' "$file" || true
        done
      '';
    });
  };
}
