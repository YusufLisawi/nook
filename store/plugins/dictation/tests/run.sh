#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$plugin_dir/../../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-dictation-insertion.XXXXXX)"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library "$repo_dir/Nook/Core/SelectionInsertion.swift" "$repo_dir/Nook/Core/PluginEngine/PluginLegacyPasteSafety.swift" "$plugin_dir/tests/SelectionInsertionTests.swift" -o "$scratch_dir/insertion-tests"
"$scratch_dir/insertion-tests"
python3 "$repo_dir/tests/migrate2/helper_protocol.py" dictation
bash "$repo_dir/tests/migrate2/run-ui.sh" dictation
