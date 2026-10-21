#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$plugin_dir/../../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/nook-agents-tests.XXXXXX)"
cp "$plugin_dir/tests/mock-codex.py" "$scratch_dir/mock-codex"
chmod +x "$scratch_dir/mock-codex"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors -parse-as-library  "$repo_dir/Nook/Core/Extensions.swift" "$plugin_dir/native/AgentModels.swift" "$plugin_dir/native/AgentProcess.swift"  "$plugin_dir/native/AgentDiff.swift" "$plugin_dir/native/AgentService.swift" "$plugin_dir/tests/native.swift" -o "$scratch_dir/native-tests"
"$scratch_dir/native-tests" "$scratch_dir"
cp "$plugin_dir/tests/"*.cjs "$scratch_dir/"
node "$scratch_dir/plugin.cjs" "$plugin_dir"
node "$scratch_dir/interface.cjs" "$plugin_dir"
python3 "$repo_dir/tests/migrate2/helper_protocol.py" agents
bash "$repo_dir/tests/migrate2/run-ui.sh" agents
node "$scratch_dir/transport.cjs" "$plugin_dir"
