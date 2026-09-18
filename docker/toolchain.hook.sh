#!/usr/bin/env bash
# Project toolchain hook — add whatever your projects need.
#
# Runs as root during `docker build`, after the base toolchain and before the
# agent CLIs. Anything installed here is baked into the image and therefore
# survives `portal update` (unlike things a user sudo-installs at runtime,
# which are lost when the container is recreated).
#
# Keep it idempotent and non-interactive.
#
# Examples:
#   apt-get update && apt-get install -y --no-install-recommends postgresql-client
#   npm install -g pnpm
#   pip install --break-system-packages uv
#   curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- your toolchain here ---------------------------------------------------

# ---------------------------------------------------------------------------

# Leave the image tidy if you used apt above.
rm -rf /var/lib/apt/lists/*
