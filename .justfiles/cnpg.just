# CloudNative-PG recipes

# List available cnpg recipes
default:
    @just --list cnpg

# Trigger a manual backup for a specific CNPG cluster
backup cluster:
    #!/usr/bin/env bash
    set -euo pipefail

    # Resolve namespace from cluster name
    NS=$(kubectl get clusters.postgresql.cnpg.io --all-namespaces \
        -o jsonpath='{range .items[?(@.metadata.name=="{{cluster}}")]}{.metadata.namespace}{end}')

    if [ -z "$NS" ]; then
        echo "Error: CNPG cluster '{{cluster}}' not found"
        echo ""
        echo "Available clusters:"
        kubectl get clusters.postgresql.cnpg.io --all-namespaces \
            -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace --no-headers
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_NAME="{{cluster}}-manual-${TIMESTAMP}"

    echo "Triggering backup for {{cluster}} in ${NS}..."
    kubectl apply -f - <<EOF
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      name: ${BACKUP_NAME}
      namespace: ${NS}
    spec:
      method: plugin
      pluginConfiguration:
        name: barman-cloud.cloudnative-pg.io
      cluster:
        name: {{cluster}}
    EOF

    echo "Waiting for backup ${BACKUP_NAME} to complete..."
    while true; do
        PHASE=$(kubectl get backup.postgresql.cnpg.io "${BACKUP_NAME}" -n "${NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        case "${PHASE}" in
            completed)
                echo "Backup ${BACKUP_NAME} completed successfully."
                break
                ;;
            failed)
                echo "Backup ${BACKUP_NAME} failed!"
                kubectl get backup.postgresql.cnpg.io "${BACKUP_NAME}" -n "${NS}" \
                    -o jsonpath='{.status.error}'
                echo ""
                exit 1
                ;;
            *)
                sleep 5
                ;;
        esac
    done

# Trigger manual backups for all CNPG clusters
backup-all:
    #!/usr/bin/env bash
    set -euo pipefail

    CLUSTERS=$(kubectl get clusters.postgresql.cnpg.io --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    if [ -z "$CLUSTERS" ]; then
        echo "No CNPG clusters found."
        exit 1
    fi

    echo "Triggering backups for all CNPG clusters..."
    echo ""

    PIDS=()
    NAMES=()
    while IFS= read -r NAME; do
        just cnpg backup "${NAME}" &
        PIDS+=($!)
        NAMES+=("${NAME}")
    done <<< "$CLUSTERS"

    FAILED=0
    for i in "${!PIDS[@]}"; do
        if ! wait "${PIDS[$i]}"; then
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    if [ "$FAILED" -gt 0 ]; then
        echo "${FAILED} backup(s) failed!"
        exit 1
    fi
    echo "All backups completed successfully."

# List the latest backup for each CNPG cluster
list-backups:
    #!/usr/bin/env bash
    set -euo pipefail

    kubectl get backups.postgresql.cnpg.io --all-namespaces -o json | jq -r '
      def duration:
        ((.[1] | sub("\\.[0-9]+Z$";"Z") | fromdate) - (.[0] | sub("\\.[0-9]+Z$";"Z") | fromdate)) |
        if . >= 60 then "\(. / 60 | floor)m\(. % 60)s"
        else "\(.)s"
        end;
      [.items[] | select(.status.phase == "completed")] |
      group_by(.spec.cluster.name) |
      map(sort_by(.status.stoppedAt) | last) |
      sort_by(.spec.cluster.name) |
      ["CLUSTER", "NAMESPACE", "LAST BACKUP", "DURATION", "BACKUP NAME"],
      ["-------", "---------", "-----------", "--------", "-----------"],
      (.[] | [
        .spec.cluster.name,
        .metadata.namespace,
        (.status.stoppedAt | sub("T";" ") | sub("Z";"")),
        ([.status.startedAt, .status.stoppedAt] | duration),
        .metadata.name
      ]) |
      @tsv
    ' | column -t -s $'\t'
