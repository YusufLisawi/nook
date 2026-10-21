#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
bash "$repo_dir/store/plugins/agents/tests/run.sh"
