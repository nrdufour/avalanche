ARG POSTGRES_VERSION=16.13@sha256:a93b1974ead1779795ea6a17dccd4acbffed1464172f84d79c2010d3e80722d3
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
