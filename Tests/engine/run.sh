#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-engine-tests.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT # Isolated generated fixtures only.
mkdir -p "$scratch_dir/work"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  "$repo_dir/Nook/Core/FeatureLifecycle.swift" \
  "$repo_dir/Nook/Core/PluginEngine/PluginManifestV2.swift" \
  "$repo_dir/Nook/Core/PluginEngine/PluginRPC.swift" \
  "$repo_dir/Nook/Core/PluginEngine/PluginHelperProcess.swift" \
  "$repo_dir/Nook/Core/PluginEngine/PluginShellCommand.swift" \
  "$repo_dir/tests/engine/EngineTests.swift" -o "$scratch_dir/engine-tests"
if [[ -n "${NOOK_ENGINE_CLI:-}" ]]; then
  "$scratch_dir/engine-tests" "$scratch_dir/work" "$NOOK_ENGINE_CLI"
else
  "$scratch_dir/engine-tests" "$scratch_dir/work"
fi
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  "$repo_dir/Nook/Core/PluginEngine/PluginManifestV2.swift" \
  "$repo_dir/Nook/Core/PluginStoreClient.swift" \
  "$repo_dir/tests/engine/StoreV2Tests.swift" -o "$scratch_dir/store-tests"
"$scratch_dir/store-tests" "$repo_dir/store"
node --test "$repo_dir/tests/engine/manifest.test.mjs"
cp "$repo_dir/tests/engine/web-bridge.cjs" "$scratch_dir/web-bridge.cjs"
node "$scratch_dir/web-bridge.cjs" "$repo_dir"
python3 "$repo_dir/tests/engine/mouse-protocol.py" "$repo_dir/store/plugins/mouse/bin/helper" "$scratch_dir"
