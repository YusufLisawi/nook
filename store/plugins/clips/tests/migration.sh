#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d /tmp/nook-migration-test.XXXXXX)
trap 'rm -rf "$scratch_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library "$plugin_dir/native/PluginRuntime.swift" "$plugin_dir/tests/MigrationTests.swift" -o "$scratch_dir/migration"
NOOK_DATA_DIR="$scratch_dir/Data" "$scratch_dir/migration"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library "$plugin_dir/native/PluginRuntime.swift" "$plugin_dir/native/ClipModels.swift" "$plugin_dir/native/ClipMigration.swift" "$plugin_dir/native/CaptureFolderScope.swift" "$plugin_dir/tests/ClipMigrationTests.swift" -o "$scratch_dir/clips"
NOOK_DATA_DIR="$scratch_dir/ClipsData" "$scratch_dir/clips"
