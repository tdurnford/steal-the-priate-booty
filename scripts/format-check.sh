#!/usr/bin/env bash
set -euo pipefail

echo "Checking formatting with StyLua..."
stylua --check src
echo "OK"
