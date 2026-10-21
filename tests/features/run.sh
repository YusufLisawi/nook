#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
feature_test_dir=$(mktemp -d /tmp/nook-features-tests.XXXXXX)
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors -parse-as-library \
  Nook/Core/FeatureLifecycle.swift tests/features/LifecycleTests.swift -o "$feature_test_dir/lifecycle"
"$feature_test_dir/lifecycle"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors -parse-as-library \
  Nook/Core/SyntheticInput.swift Nook/Core/HotkeyMonitor.swift tests/features/HotkeyTests.swift -o "$feature_test_dir/hotkeys"
"$feature_test_dir/hotkeys"
python3 - "$feature_test_dir/BridgeHelpers.swift" <<'PYHELPER'
from pathlib import Path
import sys
source = Path('Nook/Core/WebPluginHost.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + source[source.index('enum Shell {'):source.index('enum Notifier {')])
PYHELPER
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors -parse-as-library \
  Nook/Core/PluginWork.swift Nook/Core/ProcessTree.swift "$feature_test_dir/BridgeHelpers.swift" tests/features/BridgeWorkTests.swift -o "$feature_test_dir/bridge"
"$feature_test_dir/bridge"
python3 tests/features/integration.py
npm install --prefix "$feature_test_dir" --no-save --package-lock=false jsdom@26.1.0
cp tests/features/visibility.cjs "$feature_test_dir/visibility.cjs"
node "$feature_test_dir/visibility.cjs" "$PWD"
