#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-daily-ui.XXXXXX)"
npm install --prefix "$scratch_dir" --no-save --package-lock=false jsdom@26.1.0 >/dev/null 2>&1
cp "$repo_dir/tests/keyboard/plugin.cjs" "$repo_dir/tests/migrate2/settings-ui.cjs" "$scratch_dir/"
cd "$repo_dir"
if [[ "$1" != agents ]]; then node "$scratch_dir/plugin.cjs" "$1"; fi
node "$scratch_dir/settings-ui.cjs" "$1"
