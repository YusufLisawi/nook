#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
launcher_test_dir=$(mktemp -d /tmp/nook-launcher-tests.XXXXXX)
swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  Nook/Core/Extensions.swift Nook/Core/KeyboardActions.swift \
  Nook/Services/Launcher/LauncherRanking.swift tests/launcher/RankingTests.swift -o "$launcher_test_dir/ranking"
"$launcher_test_dir/ranking"
node --check Plugins/agents/main.js
swiftc -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  Nook/Prefs.swift Nook/Core/Extensions.swift Nook/Core/ShortcutRegistry.swift \
  Nook/Core/TabHotkeys.swift Nook/Core/OpenNookShortcut.swift Nook/Core/TabNavigation.swift \
  Nook/Core/TabNavigationStore.swift Nook/Core/TabNavigationViewModel.swift \
  Nook/Core/NativeShortcutIntegration.swift Nook/Core/NotchKeyboard.swift Nook/Core/KeyboardActions.swift Nook/Core/SyntheticInput.swift \
  Nook/NotchViewModel.swift Nook/Services/Dictation/DictationShortcut.swift \
  Nook/Services/Windows/WindowActions.swift Nook/Services/Windows/WindowShortcuts.swift \
  Nook/Views/Settings/SettingsShortcutRecorder.swift \
  Nook/Services/Launcher/LauncherRanking.swift Nook/Services/Launcher/LauncherPreferences.swift \
  Nook/Services/Launcher/LauncherFeature.swift \
  Nook/Services/Launcher/Answers/LauncherAnswer.swift Nook/Services/Launcher/Answers/LauncherAnswers.swift \
  Nook/Services/Launcher/Answers/*Provider.swift tests/answers/InteractionStubs.swift \
  tests/tabs/IntegrationStubs.swift tests/launcher/StateStubs.swift "${NOOK_LAUNCHER_INTERACTION_TEST:-tests/launcher/InteractionTests.swift}" -o "$launcher_test_dir/interactions"
"$launcher_test_dir/interactions"

cp tests/launcher/agents.cjs "$launcher_test_dir/agents.cjs"
node "$launcher_test_dir/agents.cjs" "$PWD/Plugins/agents" "$PWD/Tests/Agents/dom.cjs"
