# Kubernetes recipes

# renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
prometheus_operator_version := "v0.80.0"

# Module-local variables
# Note: justfile_directory() returns the module's directory (.justfiles/), so we need to go up one level
kubernetes_dir := justfile_directory() / ".." / "kubernetes"

# List available k8s recipes
default:
    @just --list k8s

# Retrieve kubeconfig from the main cluster host
get-kubeconfig host="opi01.internal":
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Retrieving kubeconfig from {{host}}..."

    # Retrieve the kubeconfig file via SSH
    ssh {{host}} 'sudo cat /etc/rancher/k3s/k3s.yaml' > {{kubernetes_dir}}/kubeconfig.tmp

    # Replace 127.0.0.1 with the VIP address (kube-vip)
    sed 's/127\.0\.0\.1/10.1.0.5/g' {{kubernetes_dir}}/kubeconfig.tmp > {{kubernetes_dir}}/kubeconfig

    # Clean up temporary file
    rm {{kubernetes_dir}}/kubeconfig.tmp

    echo "Kubeconfig saved to {{kubernetes_dir}}/kubeconfig"
    echo "The server URL has been updated to use the kube-vip VIP: 10.1.0.5"

# Bootstrap Flux on a cluster (default: main)
bootstrap cluster="main":
    #!/usr/bin/env bash
    set -euo pipefail

    # Check precondition: SOPS_AGE_KEY_FILE must exist
    if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
        echo "Error: SOPS_AGE_KEY_FILE not found at $SOPS_AGE_KEY_FILE"
        exit 1
    fi

    echo "Installing Prometheus Operator CRDs..."
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusagents.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
    kubectl --context {{cluster}} apply --server-side --force-conflicts --filename https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/{{prometheus_operator_version}}/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml

    echo "Installing Flux..."
    # TODO: see why --force-conflicts is actually needed, especially after a reconcile
    # Wonder if the install manifests are that different (seems related to limits and other helm deployment)
    kubectl --context {{cluster}} apply --server-side --force-conflicts --kustomize {{kubernetes_dir}}/kubernetes/{{cluster}}/bootstrap/flux

    echo "Applying gitea access and sops keys..."
    sops --decrypt {{kubernetes_dir}}/kubernetes/{{cluster}}/bootstrap/flux/gitea-access.sops.yaml | kubectl --context {{cluster}} apply --force-conflicts --server-side --filename -
    sops --decrypt {{kubernetes_dir}}/kubernetes/{{cluster}}/bootstrap/flux/sops-age.sops.yaml | kubectl --context {{cluster}} apply --server-side --filename -

    echo "Applying kustomizations..."
    kubectl --context {{cluster}} apply --server-side --kustomize {{kubernetes_dir}}/kubernetes/{{cluster}}/flux/config

    echo "Bootstrap complete!"

# Force all ExternalSecrets to immediately refresh (clear sync time to trigger refresh)
force-es-refresh:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Forcing all ExternalSecrets to refresh..."

    # Get all ExternalSecrets across all namespaces
    kubectl get externalsecrets --all-namespaces -o json | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read namespace name; do
            echo "Refreshing $namespace/$name..."
            # Patch the ExternalSecret to trigger immediate refresh by updating the spec
            kubectl patch externalsecret "$name" -n "$namespace" \
                --type merge -p '{"metadata":{"annotations":{"force-refresh":"'"$(date +%s)"'"}}}'
        done

    echo "All ExternalSecrets refresh triggered!"

# Check status of all ExternalSecrets and their last refresh times
check-es-status:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Checking ExternalSecrets status..."
    echo ""

    # Get all ExternalSecrets with their status information
    kubectl get externalsecrets --all-namespaces \
        -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[0].type,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason,LAST_CHECK:.status.lastCheck --sort-by=.metadata.namespace

    echo ""
    echo "For detailed status of a specific ExternalSecret, use:"
    echo "  kubectl describe externalsecret <name> -n <namespace>"
