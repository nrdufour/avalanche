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

**Remaining:**
1. Add as Grafana datasource (Prometheus type, URL: `http://possum.internal:8428`)
2. Test writing sample metrics and querying them

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
