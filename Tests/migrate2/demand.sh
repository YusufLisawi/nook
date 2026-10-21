#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-demand-tests.XXXXXX)"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
 "$repo_dir/Nook/Core/PluginEngine/PluginActivities.swift" \
 "$repo_dir/Nook/Core/PluginEngine/PluginEngine.swift" \
 "$repo_dir/Nook/Core/PluginEngine/PluginManifestV2.swift" \
 "$repo_dir/Nook/Core/PluginEngine/PluginRPC.swift" \
 "$repo_dir/Nook/Core/PluginEngine/PluginHelperProcess.swift" \
 "$repo_dir/tests/migrate2/EngineDemandTests.swift" -o "$scratch_dir/tests"
"$scratch_dir/tests" "$scratch_dir"
