---
name: cnpg-backup
description: Trigger manual CNPG database backups. Use when the user asks to back up databases, create a database backup, or run CNPG backups.
allowed-tools: Bash, AskUserQuestion
---

# CNPG Backup

Trigger manual backups of CloudNative-PG database clusters using the `just cnpg` commands.

## Available commands

- `just cnpg backup <cluster-name>` — back up a single cluster (e.g. `just cnpg backup mealie-16-db`)
- `just cnpg backup-all` — back up all clusters in parallel

## Behavior

1. If the user specifies a particular database or cluster name, run `just cnpg backup <cluster-name>`.
2. If the user says "all databases", "all clusters", "everything", or similar, run `just cnpg backup-all`.
3. If it's ambiguous whether they want one or all, use AskUserQuestion to ask which clusters to back up. List "All clusters" as the first option, then include individual cluster names as choices.
4. Cluster names end in `-db` (e.g. `mealie-16-db`, `hass-16-db`). If the user says just the app name (e.g. "mealie", "immich"), append `-16-db` to form the cluster name.

## Timeout

Set `timeout: 300000` on the Bash call — hass-16-db can take up to 3 minutes.
