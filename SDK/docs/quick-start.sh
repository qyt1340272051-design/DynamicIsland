#!/usr/bin/env bash
set -euo pipefail
# Run from the SDK directory. Each run uses a new workspace.
workspace=$(mktemp -d "${TMPDIR:-/tmp}/dynamic-island-hello.XXXXXX")
cp -R examples/hello-world "$workspace/hello-world"
python3 tools/di_plugin.py validate "$workspace/hello-world"
python3 tools/di_plugin.py package "$workspace/hello-world" "$workspace/hello-world.dip"
printf 'Plugin package: %s\n' "$workspace/hello-world.dip"
