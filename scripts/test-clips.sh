#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec bash store/plugins/clips/tests/run.sh "$@"
