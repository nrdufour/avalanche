#!/usr/bin/env bash
# influxdb-to-vm-migrate.sh — Import InfluxDB 2.x data into VictoriaMetrics
#
# Uses vmctl to transfer data from InfluxDB (K8s) to VictoriaMetrics (possum).
# vmctl is idempotent — safe to re-run; duplicates are deduplicated.
#
# Usage (from workstation with kubectl access):
#   ./scripts/influxdb-to-vm-migrate.sh              # Import all buckets (local mode)
#   ./scripts/influxdb-to-vm-migrate.sh home_assistant # Import single bucket
#   ./scripts/influxdb-to-vm-migrate.sh --remote      # Run vmctl on possum via SSH
#   ./scripts/influxdb-to-vm-migrate.sh --remote ha    # Remote + single bucket
#
# Local mode (default): runs vmctl on this machine, faster on a beefy laptop.
#   Requires: kubectl, nix-shell, network access to influxdb2.internal + possum.internal
#   Logs: /tmp/vmctl-<bucket>-<timestamp>.log (local)
#
# Remote mode (--remote): runs vmctl on possum in a GNU screen session.
#   Survives SSH disconnects. Monitor with:
#     ssh possum.internal "bash -c 'screen -r vmctl-home_assistant'"
#     ssh possum.internal "bash -c 'tail -f /tmp/vmctl-home_assistant-*.log'"
#
# NOTE: possum's login shell is fish. All SSH commands use "bash -c '...'" explicitly.

set -euo pipefail

INFLUX_ADDR="http://influxdb2.internal:8086"
POSSUM="possum.internal"
REMOTE=false

# ── Parse arguments ─────────────────────────────────────────────────
BUCKET_ARG=""
for arg in "$@"; do
  case "$arg" in
    --remote) REMOTE=true ;;
    *) BUCKET_ARG="$arg" ;;
  esac
done

if $REMOTE; then
  VM_ADDR="http://localhost:8428"
else
  VM_ADDR="http://possum.internal:8428"
fi

# Helper: run a command on possum via bash (not fish)
possum() { ssh "$POSSUM" bash -c "'$*'"; }

# ── Get InfluxDB token from K8s secret ──────────────────────────────
echo "Fetching InfluxDB admin token from K8s..."
INFLUX_TOKEN=$(kubectl get secret influxdb2-admin-token -n home-automation \
  -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "$INFLUX_TOKEN" ]]; then
  echo "ERROR: Failed to retrieve InfluxDB token" >&2
  exit 1
fi
echo "Token retrieved."

# ── Define buckets to import ────────────────────────────────────────
declare -A BUCKET_FILTER=(
  [rtl433_sensors]='--influx-filter-series "from /Acurite/"'
  [home_assistant]=''
  [home_sensors]=''
)
declare -A BUCKET_DESC=(
  [rtl433_sensors]='RTL433 weather sensors (Acurite only, skip pod-status junk)'
  [home_assistant]='Home Assistant metrics (2024-09 to present)'
  [home_sensors]='Historical home sensors (2019-12 to 2024-09)'
)
IMPORT_ORDER=(rtl433_sensors home_assistant home_sensors)

# Filter to a single bucket if argument provided
if [[ -n "$BUCKET_ARG" ]]; then
  case "$BUCKET_ARG" in
    rtl433|rtl433_sensors)   IMPORT_ORDER=(rtl433_sensors) ;;
    home_assistant|ha)       IMPORT_ORDER=(home_assistant) ;;
    home_sensors|hs)         IMPORT_ORDER=(home_sensors) ;;
    *)
      echo "ERROR: Unknown bucket '$BUCKET_ARG'. Use: rtl433, home_assistant, or home_sensors" >&2
      exit 1
      ;;
  esac
fi

# ── Check VictoriaMetrics connectivity ──────────────────────────────
echo "Checking VictoriaMetrics connectivity..."
if $REMOTE; then
  if ! ssh -o ConnectTimeout=5 "$POSSUM" bash -c "'true'" 2>/dev/null; then
    echo "ERROR: Cannot SSH to $POSSUM" >&2
    exit 1
  fi
  if ! possum "curl -sf http://localhost:8428/health" >/dev/null 2>&1; then
    echo "ERROR: VictoriaMetrics not responding on $POSSUM:8428" >&2
    exit 1
  fi
else
  if ! curl -sf "$VM_ADDR/health" >/dev/null 2>&1; then
    echo "ERROR: VictoriaMetrics not responding at $VM_ADDR" >&2
    exit 1
  fi
fi
echo "VictoriaMetrics is healthy."

# ── Pre-import: show current state ─────────────────────────────────
echo ""
echo "Mode: $( $REMOTE && echo "remote (possum)" || echo "local" )"
echo "Current VictoriaMetrics series count:"
curl -s "$( $REMOTE && echo "http://$POSSUM:8428" || echo "$VM_ADDR" )/api/v1/series/count"
echo ""
echo ""

# ── Run imports ─────────────────────────────────────────────────────
for bucket in "${IMPORT_ORDER[@]}"; do
  filter_args="${BUCKET_FILTER[$bucket]}"
  description="${BUCKET_DESC[$bucket]}"
  timestamp=$(date +%Y%m%d-%H%M%S)
  logfile="/tmp/vmctl-${bucket}-${timestamp}.log"
  session="vmctl-${bucket}"

  echo "════════════════════════════════════════════════════════"
  echo "Importing: $bucket"
  echo "  Description: $description"
  echo "  Filter: ${filter_args:-none}"
  echo "  Log: $logfile"
  if $REMOTE; then
    echo "  screen session: $session (on possum)"
  fi
  echo "════════════════════════════════════════════════════════"

  # Build the vmctl command line
  vmctl_args="vmctl influx"
  vmctl_args+=" --influx-addr $INFLUX_ADDR"
  vmctl_args+=" --influx-user token"
  vmctl_args+=" --influx-database $bucket"
  if [[ -n "$filter_args" ]]; then
    vmctl_args+=" $filter_args"
  fi
  vmctl_args+=" --vm-addr $VM_ADDR"
  if $REMOTE; then
    vmctl_args+=" --disable-progress-bar"
  fi
  vmctl_args+=" -s"

  if $REMOTE; then
    # ── Remote mode: run on possum in a screen session ──────────────
    ssh "$POSSUM" bash -c "'cat > /tmp/vmctl-run-${bucket}.sh'" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export INFLUX_PASSWORD='${INFLUX_TOKEN}'
echo "Started: \$(date)"
echo "Bucket: $bucket"
echo "════════════════════════════════════════════════════════"
nix-shell -p victoriametrics --run '$vmctl_args' 2>&1
rc=\$?
echo "════════════════════════════════════════════════════════"
echo "Finished: \$(date)"
echo "Exit code: \$rc"
rm -f /tmp/vmctl-run-${bucket}.sh
exit \$rc
EOF

    ssh "$POSSUM" bash -c "'chmod +x /tmp/vmctl-run-${bucket}.sh'"
    ssh "$POSSUM" bash -c "'screen -S $session -X quit 2>/dev/null || true'"
    ssh "$POSSUM" bash -c "'screen -dmS $session bash -c \"bash /tmp/vmctl-run-${bucket}.sh 2>&1 | tee $logfile\"'"

    echo ""
    echo "Import for '$bucket' launched in background on possum."
    echo "  Monitor:  ssh $POSSUM \"bash -c 'screen -r $session'\""
    echo "  Tail log: ssh $POSSUM \"bash -c 'tail -f $logfile'\""
    echo ""

    # Wait for completion before starting next bucket
    if [[ ${#IMPORT_ORDER[@]} -gt 1 ]]; then
      echo "Waiting for '$bucket' import to complete before starting next..."
      echo "(Press Ctrl+C to abort waiting — screen session continues on possum)"
      echo ""

      while ssh -o ConnectTimeout=5 "$POSSUM" bash -c "'screen -list | grep -q $session'" 2>/dev/null; do
        sleep 30
        tail_line=$(ssh "$POSSUM" bash -c "'tail -1 $logfile 2>/dev/null'" 2>/dev/null || echo "(no output yet)")
        echo "  [$(date +%H:%M:%S)] $tail_line"
      done

      echo ""
      echo "Bucket '$bucket' import finished. Last lines:"
      ssh "$POSSUM" bash -c "'tail -5 $logfile'" 2>/dev/null || true
      echo ""
    fi

  else
    # ── Local mode: run vmctl directly on this machine ──────────────
    echo ""
    echo "Running vmctl locally. Output logged to $logfile"
    echo "(Press Ctrl+C to abort — vmctl is idempotent, safe to re-run)"
    echo ""

    export INFLUX_PASSWORD="$INFLUX_TOKEN"
    nix-shell -p victoriametrics --run "$vmctl_args" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    unset INFLUX_PASSWORD

    echo ""
    if [[ $rc -eq 0 ]]; then
      echo "Bucket '$bucket' import completed successfully."
    else
      echo "WARNING: Bucket '$bucket' import exited with code $rc."
    fi
    echo ""
  fi
done

# ── Post-import summary ────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "All imports launched/completed."
echo ""
echo "VictoriaMetrics series count:"
curl -s "$( $REMOTE && echo "http://$POSSUM:8428" || echo "$VM_ADDR" )/api/v1/series/count"
echo ""
echo ""
echo "Metric families:"
curl -s "$( $REMOTE && echo "http://$POSSUM:8428" || echo "$VM_ADDR" )/api/v1/label/__name__/values?start=2019-01-01T00:00:00Z"
echo ""
echo ""
echo "Next steps:"
echo "  1. Verify data in Grafana (Prometheus datasource: http://possum.internal:8428)"
echo "  2. Keep InfluxDB running in parallel until satisfied"
echo "  3. See docs/plans/possum-cardinal-migration.md Phase 6 for decommission steps"
echo "════════════════════════════════════════════════════════"
