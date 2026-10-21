#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../../.."
answers_test_dir=$(mktemp -d /tmp/nook-answers-tests.XXXXXX)
swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
  store/plugins/launcher/tests/RuntimeStubs.swift store/plugins/launcher/native/LauncherAnswer.swift store/plugins/launcher/native/LauncherAnswers.swift \
  store/plugins/launcher/native/*Provider.swift store/plugins/launcher/tests/answers/DiscoveryProvider.swift store/plugins/launcher/tests/answers/ProviderTests.swift \
  -o "$answers_test_dir/providers"
"$answers_test_dir/providers"

for suite in RegistryTests CurrencyCacheTests; do
  swiftc -O -swift-version 5 -warnings-as-errors -target "$(uname -m)-apple-macos14.2" \
    store/plugins/launcher/tests/RuntimeStubs.swift store/plugins/launcher/native/LauncherAnswer.swift store/plugins/launcher/native/LauncherAnswers.swift \
    store/plugins/launcher/native/*Provider.swift "store/plugins/launcher/tests/answers/$suite.swift" -o "$answers_test_dir/$suite"
  "$answers_test_dir/$suite"
done
