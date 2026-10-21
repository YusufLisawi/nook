#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cli="${NOOK_ENGINE_CLI:-$repo_dir/build/Build/Products/Release/Nook.app/Contents/MacOS/nook-cli}"
scratch_dir="$(mktemp -d /tmp/nook-engine-cli.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT
export NOOK_SUPPORT_DIR="$scratch_dir/Nook"
export NOOK_RESOURCES="$repo_dir/store"
for language in node python swift rust; do
  "$cli" new "test-$language" --native "$language" --output "$scratch_dir/plugins" --name 'Hello "Nook"'
  if [[ "$language" == swift || "$language" == rust ]]; then bash "$scratch_dir/plugins/test-$language/build.sh"; fi
  "$cli" validate "$scratch_dir/plugins/test-$language"
done
"$cli" validate "$repo_dir/store/plugins/mouse"
"$cli" dev "$scratch_dir/plugins/test-node" --once
"$cli" dev "$scratch_dir/plugins/test-node" --once
python3 "$repo_dir/tests/engine/templates.py" "$scratch_dir/plugins" "$cli"
echo 'PASS: CLI native scaffolds (four languages), universal builds, validation, isolated dev sync and exec process-group trampoline.'
