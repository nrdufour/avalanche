ARG POSTGRES_VERSION=16.13@sha256:cd222003ce1d712c12a657310d0abc6ca583deaa3125e81bfe0bbb2d9135386e
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
