#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
answers_test_dir=$(mktemp -d /tmp/nook-answers-tests.XXXXXX)
swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  Nook/Services/Launcher/Answers/LauncherAnswer.swift Nook/Services/Launcher/Answers/LauncherAnswers.swift \
  Nook/Services/Launcher/Answers/*Provider.swift tests/answers/DiscoveryProvider.swift tests/answers/ProviderTests.swift \
  -o "$answers_test_dir/providers"
"$answers_test_dir/providers"

for suite in RegistryTests CurrencyCacheTests; do
  swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
    Nook/Services/Launcher/Answers/LauncherAnswer.swift Nook/Services/Launcher/Answers/LauncherAnswers.swift \
    Nook/Services/Launcher/Answers/*Provider.swift "tests/answers/$suite.swift" -o "$answers_test_dir/$suite"
  "$answers_test_dir/$suite"
done

NOOK_LAUNCHER_INTERACTION_TEST=tests/answers/LauncherInteractionTests.swift bash tests/launcher/run.sh
