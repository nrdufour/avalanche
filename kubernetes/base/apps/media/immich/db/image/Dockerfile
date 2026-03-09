ARG POSTGRES_VERSION=16.13@sha256:dccfe58084b97778b36d261d588b3d105754c00d7e37ae117d2526ed61be1bf8
FROM ghcr.io/cloudnative-pg/postgresql:${POSTGRES_VERSION}

# Redeclare ARG after FROM to make it available in RUN
ARG POSTGRES_MAJOR=16

USER root

# Install pgvector extension
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-${POSTGRES_MAJOR}-pgvector && \
    rm -rf /var/lib/apt/lists/*

USER postgres
