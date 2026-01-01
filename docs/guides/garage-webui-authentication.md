# Garage Web UI Authentication

This guide explains how to generate and configure authentication credentials for the Garage web UI.

## Overview

The Garage web UI supports bcrypt-based authentication using the `AUTH_USER_PASS` environment variable. The format is:

```
username:$2y$10$...bcrypt_hash...
```

## Generating Authentication Credentials

### 1. Generate the bcrypt hash

Use the `htpasswd` utility from `apache2-utils` to generate a username and bcrypt-hashed password:

```bash
nix-shell -p apacheHttpd --run "htpasswd -nbBC 10 'USERNAME' 'PASSWORD'"
```

**Parameters:**
- `-n` - Display output to stdout (don't create a file)
- `-b` - Use command-line password (non-interactive)
- `-B` - Use bcrypt algorithm
- `-C 10` - Bcrypt cost factor (10 is standard, higher = more secure but slower)

**Example:**
```bash
$ nix-shell -p apacheHttpd --run "htpasswd -nbBC 10 'admin' 'mypassword'"
admin:$2y$10$Gl4sOci.FgpxV2f9jtn9N.LhPVL6q80IJUq8u/VMDjvRtIwmpfaRO
```

### 2. Add to SOPS secrets

Add the complete output (including username and hash) to your host's SOPS file:

**Example** (`secrets/cardinal/secrets.sops.yaml`):
```bash
sops secrets/cardinal/secrets.sops.yaml
```

Add a new entry:
```yaml
garage_webui_auth: "admin:$2y$10$Gl4sOci.FgpxV2f9jtn9N.LhPVL6q80IJUq8u/VMDjvRtIwmpfaRO"
```

Save and exit. SOPS will automatically encrypt the value.

### 3. Declare the secret in NixOS configuration

In your Garage configuration file (e.g., `nixos/hosts/cardinal/garage/default.nix`):

```nix
sops = {
  secrets = {
    # ... other secrets ...
    "garage_webui_auth" = {};
  };
};
```

### 4. Add to web UI environment

In your Garage web UI configuration (e.g., `nixos/hosts/cardinal/garage/garage-webui.nix`):

```nix
sops.templates."garage-webui.env" = {
  owner = "root";
  content = ''
    API_BASE_URL=http://cardinal.internal:3903
    S3_ENDPOINT_URL=http://cardinal.internal:3900
    API_ADMIN_KEY=${config.sops.placeholder.storage_garage_admin_token}
    AUTH_USER_PASS=${config.sops.placeholder.garage_webui_auth}
  '';
};
```

### 5. Deploy

Deploy the configuration to your host:

```bash
just nix deploy cardinal
```

## Security Notes

- **Cost factor**: The `-C` parameter controls bcrypt iterations. Higher values (12-14) provide better security but increase CPU usage during login
- **Password strength**: Use strong, randomly generated passwords
- **SOPS encryption**: Always store credentials in SOPS-encrypted files, never in plaintext
- **HTTPS**: Ensure the web UI is accessed over HTTPS to protect credentials in transit

## Troubleshooting

### Authentication not working

1. Verify the secret is properly decrypted:
   ```bash
   ssh cardinal.internal
   sudo cat /run/secrets-rendered/garage-webui.env | grep AUTH_USER_PASS
   ```

2. Check the container logs:
   ```bash
   ssh cardinal.internal
   sudo podman logs garage-webui
   ```

3. Verify the format is correct (should be `username:$2y$10$...`)

### Changing credentials

To update the password:

1. Generate a new bcrypt hash with the new password
2. Update the `garage_webui_auth` entry in SOPS
3. Redeploy the configuration

## References

- [Garage Web UI Documentation](https://github.com/khairul169/garage-webui)
- [bcrypt Wikipedia](https://en.wikipedia.org/wiki/Bcrypt)
- [Apache htpasswd documentation](https://httpd.apache.org/docs/current/programs/htpasswd.html)
