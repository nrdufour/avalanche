---
name: cnpg-backup
description: Manage CNPG database backups. Use when the user asks to back up databases, create a database backup, list backups, check backup status, or show recent backups.
allowed-tools: Bash, AskUserQuestion
---

# CNPG Backup

Manage CloudNative-PG database cluster backups using the `just cnpg` commands.

## Available commands

- `just cnpg backup <cluster-name>` — back up a single cluster (e.g. `just cnpg backup mealie-16-db`)
- `just cnpg backup-all` — back up all clusters in parallel
- `just cnpg list-backups` — show the latest backup for each cluster with timestamp and duration

## Behavior

1. If the user asks to **list**, **show**, or **check** backups/backup status, run `just cnpg list-backups`.
2. If the user asks to **create/trigger a backup** for a particular database or cluster, run `just cnpg backup <cluster-name>`.
3. If the user asks to **back up all** databases/clusters, run `just cnpg backup-all`.
4. If it's ambiguous whether they want to list or create backups, or which clusters to back up, use AskUserQuestion to clarify.
5. Cluster names end in `-16-db` (e.g. `mealie-16-db`, `hass-16-db`). If the user says just the app name (e.g. "mealie", "immich"), append `-16-db` to form the cluster name.

## Timeout

Set `timeout: 300000` on Bash calls — hass-16-db can take up to 3 minutes.
