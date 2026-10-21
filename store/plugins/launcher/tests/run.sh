#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."
scratch_dir=$(mktemp -d /tmp/nook-launcher-tests.XXXXXX)
trap 'rm -rf "$scratch_dir"' EXIT
xcrun swiftc -O -swift-version 5 -warnings-as-errors store/plugins/launcher/native/KeyboardSearch.swift store/plugins/launcher/native/LauncherRanking.swift store/plugins/launcher/tests/RankingTests.swift -o "$scratch_dir/ranking"
"$scratch_dir/ranking"
bash store/plugins/launcher/tests/answers/run.sh
xcrun swiftc -swift-version 5 -warnings-as-errors Nook/Core/PluginEngine/PluginSearchQueue.swift store/plugins/launcher/tests/SearchQueueTests.swift -o "$scratch_dir/queue"
"$scratch_dir/queue"

bash store/plugins/launcher/tests/migration.sh
python3 store/plugins/launcher/tests/protocol.py

node store/plugins/launcher/tests/plugin.test.cjs
