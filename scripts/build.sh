#!/usr/bin/env bash
set -euo pipefail

mkdir -p build

echo "Building place file with Lune (merging base place + scripts)..."
lune run scripts/build
echo "OK"
