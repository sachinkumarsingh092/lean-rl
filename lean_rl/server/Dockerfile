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
FROM ${BASE_IMAGE} AS builder

WORKDIR /app

# Ensure git is available (required for installing dependencies from VCS)
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

# Lean 4 via elan
ENV ELAN_HOME=/root/.elan
ENV PATH=${ELAN_HOME}/bin:${PATH}
RUN curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf \
| sh -s -- -y --default-toolchain leanprover/lean4:v4.29.0

# Build the Lean verifier project once at image build time
COPY lean_rl/lean /app/lean
RUN cd /app/lean && lake build