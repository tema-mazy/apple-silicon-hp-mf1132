#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the locally built filter (build/out) with the release installer.
# Run after scripts/build.sh:  sudo scripts/install-queue.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/release/install.sh" "$ROOT/build/out"
