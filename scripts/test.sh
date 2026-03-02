#!/bin/bash
# Run tests using run-in-roblox (requires Roblox Studio)
# First builds the project, then runs tests in Studio

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "Building project..."
rojo build default.project.json -o build/test.rbxl

echo ""
echo "To run tests:"
echo "  1. Open build/test.rbxl in Roblox Studio"
echo "  2. Go to Test > Run (or press F8)"
echo "  3. Check Output window for test results"
echo ""
echo "Alternatively, if you have run-in-roblox installed:"
echo "  run-in-roblox --place build/test.rbxl --script scripts/run-tests.lua"
