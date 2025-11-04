# Kanidm User Management Guide

Kanidm running on `mysecrets` at `https://auth.internal`

User identities: `username@auth.internal`

## Common Operations

All commands run on mysecrets host: `ssh mysecrets.internal`

### Creating a User

```bash
# Create a person account
sudo kanidm person create <username> "Display Name" --name idm_admin

# Example
sudo kanidm person create ndufour "Nicolas Dufour" --name idm_admin
```

### Setting User Password

**Option 1: Generate a reset token (recommended for initial setup)**
```bash
sudo kanidm person credential create-reset-token <username> --name idm_admin
```
This generates a URL that the user visits to set their own password.

**Option 2: Set password directly**
```bash
sudo kanidm person credential update <username> password --name idm_admin
```
You'll be prompted to enter a password.

### Managing Groups

**Add user to a group:**
```bash
sudo kanidm group add-members <groupname> <username> --name idm_admin

# Make someone an admin
sudo kanidm group add-members idm_admins <username> --name idm_admin
```

**Remove user from group:**
```bash
sudo kanidm group remove-members <groupname> <username> --name idm_admin
```

**List group members:**
```bash
sudo kanidm group get <groupname> --name idm_admin
```

### Viewing Users

**List all users:**
```bash
sudo kanidm person list --name idm_admin
```

**Get user details:**
```bash
sudo kanidm person get <username> --name idm_admin
```

### Deleting Users

```bash
sudo kanidm person delete <username> --name idm_admin
```

### Account Recovery

If admin loses access:
```bash
sudo kanidmd recover-account admin
```
This generates a new recovery password.

## Built-in Groups

- `idm_admins` - Full administrative access
- `idm_people_manage_priv` - Can create/modify users
- `idm_group_manage_priv` - Can manage groups
- `idm_account_manage_priv` - Can manage accounts

## OAuth2 Configuration (CLI)

### Create OAuth2 Client

```bash
# Create the client
sudo kanidm system oauth2 create <client_name> "Display Name" <redirect_url> --name idm_admin

# Example for an app
sudo kanidm system oauth2 create miniflux "Miniflux RSS" https://miniflux.example.com/oauth2/callback --name idm_admin

# Get the client secret
sudo kanidm system oauth2 show-basic-secret <client_name> --name idm_admin
```

### Manage OAuth2 Scope Maps

```bash
# Create a scope map (links groups to OAuth scopes)
sudo kanidm system oauth2 create-scope-map <client_name> <group_name> <scope_names> --name idm_admin

# Example: Give all members of 'readers' group access
sudo kanidm system oauth2 create-scope-map miniflux readers openid,profile,email --name idm_admin
```

## Web UI (Limited)

Users can access `https://auth.internal` for:
- Changing their own password
- Managing their credentials (passkeys, TOTP)
- Viewing their profile
- OAuth2 consent flows

**Note:** There is NO admin panel in the web UI. All administration is via CLI.

## Useful Commands

**Check Kanidm status:**
```bash
sudo systemctl status kanidm
sudo journalctl -u kanidm -n 50 --no-pager
```

**Verify configuration:**
```bash
sudo kanidmd configtest
```

**Database backup location:**
```
/srv/backups/kanidm/
```
(Automatic daily backups at 22:00 UTC, keeps 7 versions)

## References

- [Kanidm Documentation](https://kanidm.github.io/kanidm/stable/)
- [Client Tools Reference](https://kanidm.github.io/kanidm/stable/client_tools.html)
- [OAuth2 Configuration](https://kanidm.github.io/kanidm/stable/integrations/oauth2.html)

## Configuration Files

- Server config: `/nix/store/.../server.toml` (generated from NixOS config)
- Database: `/srv/kanidm/kanidm.db` (bind mounted from `/var/lib/kanidm`)
- Certificates: `/var/lib/kanidm/certs/` (self-signed for localhost)
- Nginx cert: `/var/lib/acme/auth.internal/` (from step-ca)

## Domain Settings

- **domain:** `auth.internal`
- **origin:** `https://auth.internal`
- Users: `username@auth.internal`

**⚠️ WARNING:** Changing the domain will break all registered credentials (WebAuthn, OAuth tokens, etc.)
