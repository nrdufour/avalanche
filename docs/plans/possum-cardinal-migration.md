# Migration Plan: Consolidate Storage & Deploy VictoriaMetrics

## Goal

Repurpose possum from a multi-role NFS/Samba/Minio box into a lean data services host running Garage S3 + VictoriaMetrics. Consolidate all file-sharing (NFS/Samba) onto cardinal. Eventually migrate all time-series data from InfluxDB 2.x to VictoriaMetrics and decommission InfluxDB.

## Current State

### possum (Raspberry Pi 4, 8GB RAM, 3TB USB 3.0 SSD, ZFS)
- Minio S3 (legacy, Garage on cardinal has replaced it)
- NFS server — exports `/tank/NFS/*` datasets for K8s workloads:
  - influxdb2, home-assistant, esphome, grafana, mqtt, kanboard, komga, calibre, znc, zwave, marmitton
- Samba server — shares Books, Media
- ZFS pool "tank" on USB SSD
- Nginx reverse proxy + ACME
- Restic backup of Books to Scaleway S3

### cardinal (x86_64 mini PC, 5x 2TB NVMe RAIDZ1 ~8TB usable, ZFS)
- Garage S3 (active, serves K8s backups)
- NFS server — exports Books, Media, Images
- Samba server — shares Books, Media
- Jellyfin, Navidrome, Calibre-Web Automated
- Rclone backups to elephant.internal NAS + Backblaze B2

### InfluxDB 2.x (runs in K8s, home-automation namespace)
- Image: `influxdb:2.8`
- Data stored on possum NFS: `possum.internal:/tank/NFS/influxdb2`
- Daily backup CronJob to Longhorn PVC (7-day retention)
- Primary data: rtl_433 weather sensors, Home Assistant metrics
- Years of historical weather data

## Migration Phases

### Phase 1: Migrate NFS + Samba from possum to cardinal

**Objective**: Move all file-sharing responsibilities off possum so ZFS can be removed.

#### 1a. Migrate K8s NFS workloads

The following ZFS datasets on possum serve K8s pods via NFS. Each needs to be moved to cardinal.

| Dataset | Current path (possum) | UID:GID |
|---------|----------------------|---------|
| influxdb2 | /tank/NFS/influxdb2 | 1000:1000 |
| home-assistant | /tank/NFS/home-assistant | 0:0 |
| esphome | /tank/NFS/esphome | 0:0 |
| grafana | /tank/NFS/grafana | 472:472 |
| mqtt | /tank/NFS/mqtt | 1883:1883 |
| kanboard | /tank/NFS/kanboard | 0:0 |
| komga (config) | /tank/NFS/komga/config | 1000:1000 |
| komga (data) | /tank/NFS/komga/data | 1000:1000 |
| calibre-books | /tank/NFS/calibre-books | 1000:1000 |
| calibre-config | /tank/NFS/calibre-config | 1000:1000 |
| znc | /tank/NFS/znc | 100:101 |
| zwave | /tank/NFS/zwave | 0:0 |
| marmitton | /tank/NFS/marmitton | 0:0 |

**Steps:**
1. Create matching directories on cardinal under `/tank/NFS/` (or similar)
2. Set correct ownership (UID:GID) for each
3. Add NFS exports on cardinal for each directory
4. rsync data from possum to cardinal for each dataset
5. Update K8s PersistentVolume definitions to point to `cardinal.internal` instead of `possum.internal`
6. Restart affected pods, verify functionality
7. Remove NFS exports from possum

**Note:** Some of these NFS workloads may be candidates for migration to VolSync + Longhorn instead of NFS. Evaluate on a case-by-case basis — this migration is a good opportunity to reduce NFS dependencies.

#### 1b. Migrate Samba shares

possum and cardinal already share the same Samba config (Books + Media). If the underlying data is the same (or cardinal already has copies), this may just be removing the Samba config from possum.

If possum has unique data in `/tank/Books` or `/tank/Media`:
1. rsync to cardinal
2. Verify on cardinal
3. Remove Samba config from possum

#### 1c. Migrate Books backup

possum runs a Restic backup of `/tank/Books` to Scaleway S3. Once Books lives on cardinal:
1. Add equivalent Restic backup job to cardinal config (or rely on cardinal's existing B2 backup)
2. Remove backup job from possum

#### 1d. Decommission Minio

Minio on possum is legacy (Garage on cardinal has replaced it). If nothing still depends on it:
1. Verify no services point to `minio.internal` / `s3.internal`
2. Remove Minio config from possum
3. Remove nginx vhosts for minio/s3

### Phase 2: Reformat possum (remove ZFS)

**Objective**: Strip ZFS from possum, reformat SSD with ext4, minimal footprint.

**Prerequisites**: Phase 1 complete. No data remains on possum's ZFS pool.

1. Verify nothing reads from possum NFS or Samba
2. SSH to possum, export ZFS pool: `zpool export tank`
3. Update possum NixOS config:
   - Remove ZFS configuration (hostId, pool settings, datasets)
   - Remove NFS server config
   - Remove Samba server config
   - Remove Minio config
   - Remove nginx vhosts for removed services
4. Reformat SSD as ext4, mount at `/data` (or similar)
5. Deploy updated config

### Phase 3: Deploy VictoriaMetrics on possum

**Objective**: Get VictoriaMetrics running and accessible for experimentation.

1. Add to possum NixOS config:
   ```nix
   services.victoriametrics = {
     enable = true;
     extraOptions = [
       "-retentionPeriod=10y"
       "-storageDataPath=/data/victoriametrics"
       "-httpListenAddr=:8428"
     ];
   };
   ```
2. Add nginx reverse proxy: `https://vm.internal` → `localhost:8428`
3. Open firewall port (or rely on Tailscale)
4. Deploy and verify VictoriaMetrics is running
5. Add as Grafana datasource (Prometheus type, URL: `http://possum.internal:8428`)
6. Test writing sample metrics and querying them

### Phase 4: Set up data ingestion pipelines

**Objective**: Route rtl_433 and Home Assistant metrics to VictoriaMetrics.

#### 4a. rtl_433

rtl_433 currently publishes to MQTT. Options:
- **Telegraf**: MQTT consumer → VictoriaMetrics remote write (Telegraf has native support for both)
- **mqtt2prometheus**: Lightweight MQTT-to-Prometheus bridge, VM scrapes it
- **VictoriaMetrics native**: VM supports InfluxDB line protocol on `/write` endpoint — a lightweight MQTT-to-HTTP bridge could forward directly

Recommended: Start with Telegraf since it handles both MQTT input and VM output natively, and can run on possum as a NixOS service.

#### 4b. Home Assistant

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

### Phase 5: Migrate historical InfluxDB data

**Objective**: Import years of weather data from InfluxDB into VictoriaMetrics.

**Tool**: `vmctl` — VictoriaMetrics's migration CLI with native InfluxDB support.

1. Ensure InfluxDB is accessible from possum (it runs in K8s, service on port 8086)
2. Plan metric naming convention:
   - InfluxDB model: `measurement` + `tags` + `fields`
   - Prometheus model: `metric_name{labels}`
   - Example: InfluxDB `weather,sensor=outdoor temperature=21.5` → VM `weather_temperature{sensor="outdoor"} 21.5`
3. Run `vmctl` in dry-run mode first to verify mapping
4. Run full import
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
