#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../../../.." && pwd)"
python3 "$repo_dir/tests/migrate2/helper_protocol.py" commands
bash "$repo_dir/tests/migrate2/run-ui.sh" commands
