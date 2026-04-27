ARG POSTGRES_VERSION=16.13@sha256:da09a5927dd7af1572591df6c2c1a192d441054ff73e6df823402fcbf08c5ff0
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
