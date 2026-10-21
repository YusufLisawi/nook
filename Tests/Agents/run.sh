#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
agents_test_dir=$(mktemp -d /tmp/nook-agents-tests.XXXXXX)
cp Tests/Agents/mock-codex.py "$agents_test_dir/mock-codex"
chmod +x "$agents_test_dir/mock-codex"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -warnings-as-errors \
  Nook/Core/Extensions.swift Nook/Services/Agents/AgentModels.swift \
  Nook/Services/Agents/AgentProcess.swift Nook/Services/Agents/AgentDiff.swift \
  Nook/Services/Agents/AgentService.swift Tests/Agents/native.swift -o "$agents_test_dir/native-tests"
"$agents_test_dir/native-tests" "$agents_test_dir"
cp Tests/Agents/plugin.cjs "$agents_test_dir/plugin.cjs"
node "$agents_test_dir/plugin.cjs" "$PWD/Plugins/agents"
cp Tests/Agents/interface.cjs Tests/Agents/dom.cjs "$agents_test_dir/"
node "$agents_test_dir/interface.cjs" "$PWD/Plugins/agents"
printf 'Test artifacts: %s\n' "$agents_test_dir"
