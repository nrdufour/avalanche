---
id: "001"
title: "Install Gateway API CRDs"
branch: "prd/001-gateway-api-crds"
status: pending
depends_on: []
verify:
  - cmd: "kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[0].name}'"
    desc: "Gateway CRD is installed on the cluster"
  - cmd: "kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[0].name}'"
    desc: "HTTPRoute CRD is installed on the cluster"
  - cmd: "kubectl get crd gatewayclasses.gateway.networking.k8s.io -o jsonpath='{.spec.versions[0].name}'"
    desc: "GatewayClass CRD is installed on the cluster"
  - cmd: "argocd app get gateway-api --output json | jq -r '.status.sync.status'"
    desc: "ArgoCD Application is synced"
---

# Install Gateway API CRDs

## Context

Ingresses are the current standard for HTTP routing in the cluster, but Gateway API is the future of Kubernetes networking (see [issue #33](https://forge.internal/nemo/avalanche/issues/33)). This is the first step: install the Gateway API CRDs on the cluster so that future work can build on them.

The official Gateway API project ([gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/)) does not provide a Helm chart. The recommended installation method is applying the upstream YAML manifest with server-side apply.

## Requirements

1. Install Gateway API **v1.4.1** (latest stable) using the **standard channel** (`standard-install.yaml`), which includes GA and Beta resources: GatewayClass, Gateway, HTTPRoute, GRPCRoute, ReferenceGrant, and BackendTLSPolicy.
2. Deploy as an ArgoCD Application at `kubernetes/base/infra/network/gateway-api-app.yaml`, following the existing multi-source or kustomize pattern used by other network services.
3. Store the upstream `standard-install.yaml` in `kubernetes/base/infra/network/gateway-api/` and reference it via a `kustomization.yaml` — this keeps the version pinned and auditable.
4. Use `ServerSideApply=true` in the ArgoCD sync options (required by upstream for CRD installation).
5. CRDs are cluster-scoped; the ArgoCD Application destination namespace should be `network` for consistency with other network infra apps.

## Out of Scope

- Choosing or installing a Gateway controller implementation (e.g., Envoy Gateway, Cilium, Traefik).
- Creating any GatewayClass or Gateway resources.
- Migrating existing Ingress resources to HTTPRoute.
- Installing the experimental channel CRDs.
