#!/usr/bin/env bash
set -euo pipefail

SDK_CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SDK_CHECK_ROOT"

python3 -m unittest discover -s SDK/tests -p 'test_*.py'
python3 SDK/tools/di_plugin.py validate SDK/examples/hello-world
python3 SDK/tools/di_plugin.py validate docs/plugin-system/examples/pomodoro
python3 SDK/tools/di_plugin.py validate docs/plugin-system/examples/github
python3 SDK/tools/di_plugin.py validate-node SDK/tests/fixtures/valid-node.json
node --check SDK/examples/hello-world/index.js

# CI installs the locked development-only compiler. A local configured
# compiler can be reused without installing or changing the global toolchain.
if [[ -n "${SDK_TSC_JS:-}" ]]; then
  node "$SDK_TSC_JS" -p SDK/tsconfig.json
elif [[ -f SDK/node_modules/typescript/bin/tsc ]]; then
  node SDK/node_modules/typescript/bin/tsc -p SDK/tsconfig.json
elif command -v tsc >/dev/null 2>&1; then
  tsc -p SDK/tsconfig.json
else
  printf 'SDK type checks require: npm ci --prefix SDK --ignore-scripts\n' >&2
  exit 1
fi

printf 'SDK authoring, packaging, and type checks passed.\n'
