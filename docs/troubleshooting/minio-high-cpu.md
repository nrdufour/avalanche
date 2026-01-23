# Minio High CPU Usage (Scanner)

## Problem

Minio process runs at ~30% CPU constantly on possum, even when idle.

## Cause

Minio's internal scanner runs at `speed=default` (maximum), continuously iterating through all files checking for bitrot. With 100k+ files in the cloudnative-pg bucket (PostgreSQL WAL backups), this causes constant CPU usage.

On a single-node minio setup without erasure coding, the scanner provides no benefit - there's no redundancy to heal from.

## Fix

Set scanner speed to slow:

```bash
mc alias set local http://localhost:9000 <user> <password>
mc admin config set local/ scanner speed=slow
```

Setting persists in `/tank/Minio/.minio.sys/config/`.

## Status

Minio is scheduled for decommissioning (replaced by Garage S3).
