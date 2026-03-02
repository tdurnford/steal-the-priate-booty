#!/usr/bin/env bash
set -euo pipefail

echo "Formatting with StyLua..."
stylua src
echo "OK"
