#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
keyboard_test_dir=$(mktemp -d /tmp/nook-keyboard-tests.XXXXXX)
swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  Nook/Prefs.swift Nook/Core/Extensions.swift Nook/Core/ShortcutRegistry.swift \
  Nook/Core/TabHotkeys.swift Nook/Core/OpenNookShortcut.swift Nook/Core/TabNavigation.swift \
  Nook/Core/TabNavigationStore.swift Nook/Core/TabNavigationViewModel.swift \
  Nook/Core/NativeShortcutIntegration.swift Nook/Core/NotchKeyboard.swift Nook/Core/KeyboardActions.swift \
  Nook/NotchViewModel.swift Nook/Services/Dictation/DictationShortcut.swift \
  Nook/Services/Windows/WindowActions.swift Nook/Services/Windows/WindowShortcuts.swift \
  Nook/Views/Settings/SettingsShortcutRecorder.swift \
  tests/tabs/IntegrationStubs.swift tests/keyboard/NativeTests.swift -o "$keyboard_test_dir/native"
"$keyboard_test_dir/native"
npm install --prefix "$keyboard_test_dir" --no-save --package-lock=false jsdom@26.1.0
cp tests/keyboard/plugin.cjs "$keyboard_test_dir/plugin.cjs"
node "$keyboard_test_dir/plugin.cjs"
