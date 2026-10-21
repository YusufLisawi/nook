#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec bash store/plugins/file-search/tests/run.sh "$@"
