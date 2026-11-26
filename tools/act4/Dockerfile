FROM ghcr.io/riscv/act4-build@sha256:7f91dd68ceca47300dc59e320797a86998b8c94062b011bf6de9a3ba3ad57a03
USER root
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
USER ubuntu
