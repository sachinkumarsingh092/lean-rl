# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

# Multi-stage build using openenv-base
# This Dockerfile is flexible and works for both:
# - In-repo environments (with local OpenEnv sources)
# - Standalone environments (with openenv from PyPI/Git)
# The build script (openenv build) handles context detection and sets appropriate build args.

ARG BASE_IMAGE=ghcr.io/meta-pytorch/openenv-base:latest
FROM ${BASE_IMAGE}

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -L "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# kwok + kwokctl
ARG KWOK_VERSION=v0.6.1
RUN curl -L "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwokctl-linux-amd64" \
  -o /usr/local/bin/kwokctl && chmod +x /usr/local/bin/kwokctl && \
    curl -L "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok-linux-amd64" \
  -o /usr/local/bin/kwok && chmod +x /usr/local/bin/kwok

# Lean 4
ENV ELAN_HOME=/root/.elan
ENV PATH=${ELAN_HOME}/bin:${PATH}
RUN curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf \
  | sh -s -- -y --default-toolchain leanprover/lean4:v4.29.0

# Build Lean verifier
COPY lean_rl/lean /app/lean_rl/lean
RUN cd /app/lean_rl/lean && lake build

# Python deps (server only — no training libs)
COPY lean_rl/pyproject.toml /app/lean_rl/pyproject.toml
COPY lean_rl/server /app/lean_rl/server
COPY lean_rl/models.py lean_rl/__init__.py lean_rl/openenv.yaml /app/lean_rl/
RUN pip install /app/lean_rl

EXPOSE 8000
CMD kwokctl create cluster && \
    uvicorn lean_rl.server.app:app --host 0.0.0.0 --port 8000