#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /tmp/nook-store-swift.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT # Only the isolated, generated test executable.
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  "$repo_dir/Nook/Core/PluginEngine/PluginManifestV2.swift" "$repo_dir/Nook/Core/PluginStoreClient.swift" "$repo_dir/tests/store/StoreClientTests.swift" \
  -o "$test_dir/store-tests"
"$test_dir/store-tests" "$repo_dir/store"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  "$repo_dir/Nook/Core/PluginEngine/PluginManifestV2.swift" "$repo_dir/Nook/Core/PluginStoreClient.swift" "$repo_dir/cli/swift/PluginStorePublisher.swift" \
  "$repo_dir/tests/store/StorePublisherTests.swift" -o "$test_dir/publisher-tests"
"$test_dir/publisher-tests" "$repo_dir/store"
