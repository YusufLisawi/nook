#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mouse_test_dir=$(mktemp -d /tmp/nook-mouse-tests.XXXXXX)
swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  Nook/Core/SyntheticInput.swift store/plugins/mouse/native/MouseEventState.swift \
  store/plugins/mouse/native/MouseConfig.swift store/plugins/mouse/native/MouseActions.swift \
  store/plugins/mouse/native/MouseFixService.swift store/plugins/mouse/native/MouseScroller.swift \
  Nook/Services/Dictation/HotkeyMonitor.swift Nook/Services/Dictation/DictationShortcut.swift \
  tests/mouse/Stubs.swift tests/mouse/NativeTests.swift -o "$mouse_test_dir/native"
"$mouse_test_dir/native"
node --check store/plugins/mouse/main.js
npm install --prefix "$mouse_test_dir" --no-save --package-lock=false --silent jsdom@26.1.0
cp tests/mouse/plugin.cjs "$mouse_test_dir/plugin.cjs"
node "$mouse_test_dir/plugin.cjs" "$PWD/store/plugins/mouse"
