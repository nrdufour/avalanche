ARG POSTGRES_VERSION=16.4
ARG POSTGRES_MAJOR=16
FROM ghcr.io/cloudnative-pg/postgresql:${POSTGRES_VERSION}

USER root

# Install pgvector extension
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-${POSTGRES_MAJOR}-pgvector && \
    rm -rf /var/lib/apt/lists/*

USER postgres
