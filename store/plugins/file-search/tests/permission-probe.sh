#!/bin/bash
# A standalone, independently attributed process. It never launches Nook.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
probe_dir=$(mktemp -d /tmp/nook-file-permission-probe.XXXXXX)
probe_label="com.yusuf.nook.files-permission-probe.$$"
xcrun clang -std=c11 -O3 -Wall -Wextra -Werror -c store/plugins/file-search/native/FileNameIndex.c -o "$probe_dir/index.o"
xcrun swiftc -O -swift-version 5 -warnings-as-errors \
  -import-objc-header store/plugins/file-search/native/NookFiles-Bridging.h \
  store/plugins/file-search/tests/RuntimeStubs.swift store/plugins/file-search/native/FileSearchModels.swift store/plugins/file-search/native/FileIndexQuery.swift \
  store/plugins/file-search/native/FileSearchAccessPolicy.swift store/plugins/file-search/native/FileNameIndex.swift \
  store/plugins/file-search/tests/PermissionProbe.swift "$probe_dir/index.o" -o "$probe_dir/permission-probe"
codesign --force --sign - --identifier "$probe_label" "$probe_dir/permission-probe"
python3 - "$probe_dir" "$probe_label" <<'PY'
import plistlib, sys
path, label = sys.argv[1:]
with open(path + '/probe.plist', 'wb') as f:
    plistlib.dump(dict(Label=label, ProgramArguments=[path + '/permission-probe', path + '/cache'],
                      RunAtLoad=True, KeepAlive=False, StandardOutPath=path + '/stdout', StandardErrorPath=path + '/stderr'), f)
PY
probe_domain="gui/$(id -u)"
trap 'launchctl bootout "$probe_domain/$probe_label" 2>/dev/null || true' EXIT
launchctl bootstrap "$probe_domain" "$probe_dir/probe.plist"
for ((probe_second=0; probe_second<110; probe_second++)); do
  if test -f "$probe_dir/stdout" && rg -q '^PASS:' "$probe_dir/stdout"; then
    cat "$probe_dir/stdout" "$probe_dir/stderr"
    echo "Probe evidence: $probe_dir"
    exit 0
  fi
  sleep 1
done
cat "$probe_dir/stdout" "$probe_dir/stderr" 2>/dev/null || true
exit 1
