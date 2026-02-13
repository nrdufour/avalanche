# Migration Plan: Consolidate Storage & Deploy VictoriaMetrics

## Goal

Repurpose possum from a multi-role NFS/Samba/Minio box into a lean data services host running Garage S3 + VictoriaMetrics. Consolidate all file-sharing (NFS/Samba) onto cardinal. Eventually migrate all time-series data from InfluxDB 2.x to VictoriaMetrics and decommission InfluxDB.

## Current State

### possum (Raspberry Pi 4, 8GB RAM, 3.6TB WD Blue SA510 USB SSD, ext4)
- VictoriaMetrics (10y retention, data on SSD at `/data/victoriametrics`)
- SSD: `/dev/disk/by-id/ata-WD_Blue_SA510_2.5_4TB_24129M4A1E13`, single GPT partition, ext4 labeled `POSSUM_DATA`, mounted at `/data`
- NFS, Samba, Minio, nginx, ZFS — all removed

### cardinal (x86_64 mini PC, 5x 2TB NVMe RAIDZ1 ~8TB usable, ZFS)
- Garage S3 (active, serves K8s backups)
- NFS server — exports Books, Media, Images (+ migrated workloads from possum)
- Samba server — shares Books, Media
- Jellyfin, Navidrome, Calibre-Web Automated
- Rclone backups to elephant.internal NAS + Backblaze B2

### InfluxDB 2.x (runs in K8s, home-automation namespace)
- Image: `influxdb:2.8`
- Data stored on cardinal NFS (migrated from possum)
- Daily backup CronJob to Longhorn PVC (7-day retention)
- Primary data: rtl_433 weather sensors, Home Assistant metrics
- Years of historical weather data

## Migration Phases

### Phase 1: Migrate NFS + Samba from possum to cardinal ✅

**Completed.** All NFS exports and Samba shares migrated to cardinal. Minio decommissioned. Nginx and Restic backup removed from possum.

### Phase 2: Reformat possum (remove ZFS) ✅

**Completed.** ZFS pool exported and wiped. SSD reformatted:
- Wiped ZFS signatures with `wipefs -a`
- Created GPT partition table with single ext4 partition labeled `POSSUM_DATA`
- Mounted at `/data` via `/dev/disk/by-label/POSSUM_DATA` (stable across reboots)
- Removed `hostId` from NixOS config (no longer needed without ZFS)

### Phase 3: Deploy VictoriaMetrics on possum ✅

**Completed.** VictoriaMetrics v1.135.0 running on possum:8428.

NixOS config:
```nix
services.victoriametrics = {
  enable = true;
  retentionPeriod = "10y";
};

# Bind mount redirects /var/lib/victoriametrics → /data/victoriametrics (SSD)
# The NixOS module hardcodes storageDataPath to /var/lib/victoriametrics;
# the bind mount avoids writing time-series data to the SD card.
fileSystems."/var/lib/victoriametrics" = {
  device = "/data/victoriametrics";
  options = [ "bind" ];
};
```

Nginx reverse proxy: `https://vm.internal` → `localhost:8428` (step-ca ACME cert).
DNS: `vm.internal` CNAME → `possum.internal` (routy Knot static records).

**Completed:**
- Grafana datasource added (Prometheus type, URL: `http://possum.internal:8428`)
- Live data verified in Grafana dashboards

### Phase 4: Set up data ingestion pipelines

**Objective**: Route rtl_433 and Home Assistant metrics to VictoriaMetrics.

#### 4a. rtl_433 ✅

**Completed.** Added a second `-Finflux://` output to the rtl_433 deployment pointing to VM's InfluxDB-compatible write endpoint. rtl_433 now dual-writes to both InfluxDB and VictoriaMetrics.

Config change in `kubernetes/base/apps/home-automation/rtl433/helm-values.yaml`:
```yaml
- "-Finflux://influxdb2.internal:8086/api/v2/write?org=nemoworld&bucket=rtl433_sensors,token=$(INFLUXDB2_TOKEN)"
- "-Finflux://possum.internal:8428/write?db=rtl433_sensors"
```

**Why this works:** VM's `/write` endpoint accepts InfluxDB line protocol and applies the same `{measurement}_{field}{tags}` naming as vmctl. The `?db=rtl433_sensors` parameter adds the `db` label, matching the historical import. No Telegraf or extra components needed.

#### 4b. Home Assistant — not started

Home Assistant has a built-in Prometheus integration:
1. Enable in Home Assistant config: `prometheus:`
2. Add scrape target in VictoriaMetrics (via `-promscrape.config`):
   ```yaml
   scrape_configs:
     - job_name: homeassistant
       metrics_path: /api/prometheus
       bearer_token: "<long-lived access token>"
       static_configs:
         - targets: ["home-assistant.internal:8123"]
   ```

**Note:** Unlike rtl_433, HA's Prometheus integration produces Prometheus-format metrics natively, so the live scrape metrics will have different names than the vmctl-imported InfluxDB data. This needs consideration before starting — options:
- Accept different naming for live vs historical (query both in Grafana)
- Use VM's relabeling to align names
- Skip live HA scrape and just keep importing from InfluxDB periodically until decommission

### Phase 5: Migrate historical InfluxDB data — in progress

**Objective**: Import historical data from InfluxDB into VictoriaMetrics.

**Tool**: `vmctl` (from `nix-shell -p victoriametrics`). Run locally on workstation for speed (not on possum RPi4).

**Strategy**: Set up live ingestion first (Phase 4), then backfill historical data. This avoids gaps — live data flows while the slow import runs.

#### InfluxDB inventory

| Bucket | Time Range | Measurements | Notes |
|---|---|---|---|
| `rtl433_sensors` | 2022-01 → now | 5 real sensors + ~118 pod-status junk | Primary target |
| `home_assistant` | 2024-09 → now | Many HA entities | Active |
| `home_sensors` | 2019-12 → 2024-09 | 8 (light, pressure, temp, etc.) | Historical, dead since Sep 2024 |
| `test_scrapper` | — | 0 | Empty, skip |

**rtl433_sensors details:**
- Real sensor measurements: `Acurite-Atlas`, `Acurite-Tower`, `Acurite-515`, `Acurite-6045M`, `Acurite-986`
- 212 series, 158 numeric fields, 13 tags
- The `rtl_433_<pod-hash>` measurements are per-pod status metrics from pod restarts — low value, filter out

#### Access details

- **InfluxDB endpoint**: `http://influxdb2.internal:8086` (LoadBalancer service in `home-automation` namespace)
- **Org**: `nemoworld`
- **Admin token**: `kubectl get secret influxdb2-admin-token -n home-automation -o jsonpath='{.data.token}' | base64 -d`
- **v1 compat API**: Works — DBRP mappings exist for all buckets, bucket name = database name, retention policy = `autogen`

#### vmctl auth workaround (InfluxDB 2.x)

vmctl uses the InfluxDB v1 query API. InfluxDB 2.x v1 compat rejects query-param auth (`?u=&p=`) but accepts Basic auth. To make vmctl send Basic auth, **both user and password must be set**:

```bash
INFLUX_TOKEN=$(kubectl get secret influxdb2-admin-token -n home-automation -o jsonpath='{.data.token}' | base64 -d)

ssh possum.internal "bash -c 'export INFLUX_PASSWORD=\"$INFLUX_TOKEN\" && vmctl influx \
  --influx-addr http://influxdb2.internal:8086 \
  --influx-user token \
  --influx-database rtl433_sensors \
  --influx-filter-series \"from /Acurite/\" \
  --vm-addr http://localhost:8428 \
  --disable-progress-bar \
  -s 2>&1'"
```

Key: `--influx-user token` (any non-empty string) + `INFLUX_PASSWORD=<token>` env var.

#### Naming convention

vmctl produces `{measurement}_{field}{tags}` by default (separator configurable via `--influx-measurement-field-separator`):
- InfluxDB: measurement=`Acurite-Atlas`, field=`wind_avg_mi_h`, tags=`{channel="C", id="837"}`
- VM: `Acurite-Atlas_wind_avg_mi_h{channel="C", id="837", db="rtl433_sensors"}`

#### Progress

| Bucket | Live ingestion | Historical import | Next action |
|---|---|---|---|
| `rtl433_sensors` | ✅ Dual-write via `-Finflux://` | Partial (2022–~2025), needs gap backfill | Run `./scripts/influxdb-to-vm-migrate.sh rtl433` |
| `home_assistant` | Not started (Phase 4b) | Not started | Set up HA Prometheus scrape first, then import |
| `home_sensors` | N/A (dead since Sep 2024) | Not started | One-time import: `./scripts/influxdb-to-vm-migrate.sh home_sensors` |

#### Migration script

`scripts/influxdb-to-vm-migrate.sh` — runs vmctl locally (default) or on possum (`--remote`). Safe to re-run (vmctl deduplicates but re-transfers all data each time).

```bash
# Import all remaining buckets (runs for hours)
./scripts/influxdb-to-vm-migrate.sh

# Import a single bucket
./scripts/influxdb-to-vm-migrate.sh home_assistant
./scripts/influxdb-to-vm-migrate.sh home_sensors

# Monitor (from another terminal)
ssh possum.internal "bash -c 'screen -r vmctl-home_assistant'"
ssh possum.internal "bash -c 'tail -f /tmp/vmctl-home_assistant-*.log'"
```

#### Remaining steps

1. Backfill `rtl433_sensors` gap: `./scripts/influxdb-to-vm-migrate.sh rtl433`
2. Set up Home Assistant live ingestion (Phase 4b) — decide on naming strategy
3. Import `home_assistant`: `./scripts/influxdb-to-vm-migrate.sh home_assistant`
4. Import `home_sensors` (one-time): `./scripts/influxdb-to-vm-migrate.sh home_sensors`
5. Verify data in Grafana — compare InfluxDB and VM dashboards side by side
6. Keep InfluxDB running in parallel until confident

### Phase 6: Decommission InfluxDB

**Objective**: Remove InfluxDB from the cluster once VictoriaMetrics is proven.

**Prerequisites**: Phase 5 complete. All consumers (Grafana dashboards, rtl_433, Home Assistant) point to VictoriaMetrics. Historical data verified.

1. Stop InfluxDB deployment in K8s
2. Keep the NFS data on cardinal (migrated in Phase 1) for a grace period
3. Remove K8s manifests: `kubernetes/base/apps/home-automation/influxdb2/`
4. Remove ArgoCD application
5. After grace period, delete the InfluxDB data directory

### Phase 7: Deploy Garage S3 on possum (optional, future)

**Objective**: Move Garage from cardinal to possum if desired.

This is independent of the VictoriaMetrics migration and can be done whenever convenient. Considerations:
- possum's USB 3.0 SSD may be a bottleneck for heavy S3 traffic
- cardinal's NVMe RAIDZ1 is significantly faster
- Evaluate whether the move makes sense based on actual Garage workload

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| K8s pods break during NFS migration | Migrate one workload at a time, verify each before proceeding |
| Data loss during rsync | Keep possum data intact until cardinal is verified. Use `rsync --checksum` |
| InfluxDB metric naming doesn't map cleanly to Prometheus | Do a test import with `vmctl` dry-run before full migration |
| Historical data gaps after migration | Run InfluxDB and VM in parallel, compare dashboards |
| possum SSD too slow for Garage + VM | Monitor I/O. Garage migration (Phase 7) is optional |
| NFS workloads should use Longhorn/VolSync instead | Evaluate during Phase 1 — migrate to VolSync where appropriate |

## Decision Log

- **VictoriaMetrics over Mimir/Thanos**: Lower resource usage (critical for RPi4), native InfluxDB protocol support, simpler operations (single binary), `vmctl` for migration. Mimir requires more resources and is designed for K8s deployment.
- **possum over cardinal for VM**: Keeps metrics store independent from the K8s cluster it monitors. Cardinal is already busy with media services.
- **Remove ZFS from possum**: Frees RAM (ZFS ARC), simplifies operations. All file-serving consolidated on cardinal's beefier hardware.
