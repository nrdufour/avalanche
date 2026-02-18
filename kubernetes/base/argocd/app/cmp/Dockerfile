# CMP Sidecar image with kustomize + envsubst
# Build: docker build -t forge.internal/nemo/argocd-cmp-kustomize-envsubst:v3.2.0 .
#
FROM quay.io/argoproj/argocd:v3.3.1

USER root

# Install envsubst (from gettext package)
RUN apt-get update && \
    apt-get install -y --no-install-recommends gettext-base && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

USER argocd
