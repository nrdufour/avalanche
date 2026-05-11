ARG POSTGRES_VERSION=16.13@sha256:425e365273a0519c9cc1deb199a69c226734041a9a59a1f8250fecb06f6dcbb5
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
