/* Fixed scan roots. Filenames and stored values are never interpolated into commands. */
const CleanerShell = (() => {
  const roots = {
    caches: [['caches', 'Library/Caches']],
    logs: [['logs', 'Library/Logs']],
    derived: [['derived', 'Library/Developer/Xcode/DerivedData']],
    devices: [['devices', 'Library/Developer/Xcode/iOS DeviceSupport']],
    simulators: [['simulators', 'Library/Developer/CoreSimulator/Caches']],
    packages: [
      ['npm', '.npm/_cacache'], ['bun', '.bun/install/cache'],
      ['pnpm', 'Library/pnpm/store'], ['yarn', 'Library/Caches/Yarn'],
      ['pip', 'Library/Caches/pip'], ['CocoaPods', 'Library/Caches/CocoaPods'],
      ['Gradle', '.gradle/caches'],
    ],
    downloads: [['downloads', 'Downloads']],
  };
  const quote = (value) => "'" + String(value).replace(/'/g, "'\\''") + "'";
  const days = (value) => Math.min(365, Math.max(7, Math.round(Number(value) || 60)));

  const preamble = `emulate -L zsh
unsetopt ALIASES
cleaner_home="$HOME"
[[ "$cleaner_home" = /* && "$cleaner_home" != / && -d "$cleaner_home" && ! -L "$cleaner_home" ]] || { print -u2 'Cannot safely access your home folder.'; exit 1; }
typeset -a cleaner_items cleaner_chunk
integer cleaner_total=0 cleaner_count=0 cleaner_skipped=0 cleaner_protected=0 cleaner_bytes=0 cleaner_measured=0

# Reject symlinks at every component. Missing roots are normal; inaccessible roots count once.
cleaner_root() {
  local relative="$1" component cursor="$cleaner_home"
  for component in "\${(@s:/:)relative}"; do
    cursor="$cursor/$component"
    if [[ -L "$cursor" ]]; then (( cleaner_skipped++ )); return 1; fi
    [[ -e "$cursor" ]] || return 1
    if [[ ! -d "$cursor" || ! -r "$cursor" || ! -x "$cursor" ]]; then
      (( cleaner_skipped++, cleaner_protected++ )); return 1
    fi
  done
  # POSIX access checks can pass even when TCC refuses directory enumeration.
  if ! /bin/ls -A "$cursor" >/dev/null 2>&1; then
    (( cleaner_skipped++, cleaner_protected++ )); return 1
  fi
  cleaner_root_path="$cursor"
}

cleaner_collect() {
  local relative="$1" kind="$2" item modified
  cleaner_items=()
  cleaner_root "$relative" || return 0
  for item in "$cleaner_root_path"/*(DN); do
    if [[ "$kind" = caches ]]; then
      case "\${item:t}" in com.apple.*|Yarn|yarn|pip|CocoaPods|cocoapods|Homebrew|homebrew) continue ;; esac
    fi
    if [[ -L "$item" ]]; then (( cleaner_skipped++ )); continue; fi
    if [[ "$kind" = downloads ]]; then
      # Only immediate regular files, by modification time; never downloaded folders.
      [[ -f "$item" ]] || continue
      modified=$(/usr/bin/stat -f %m "$item" 2>/dev/null)
      if [[ "$modified" != <-> ]]; then (( cleaner_skipped++, cleaner_protected++ )); continue; fi
      (( modified < cleaner_cutoff )) || continue
    fi
    if [[ ! -r "$item" || ( -d "$item" && ! -x "$item" ) ]]; then
      (( cleaner_skipped++, cleaner_protected++ )); continue
    fi
    cleaner_items+=("$item")
  done
}

cleaner_measure() {
  local output last amount item
  integer offset
  cleaner_bytes=0 cleaner_measured=0
  # Fast path: bounded batches. If one item fails, retry separately and retain readable siblings.
  # A directory with unreadable descendants is left intact, rather than reporting a partial size.
  for (( offset=1; offset<=\${#cleaner_items}; offset+=64 )); do
    cleaner_chunk=("\${(@)cleaner_items[$offset,$((offset + 63))]}")
    if output=$(/usr/bin/du -skcP "\${cleaner_chunk[@]}" 2>/dev/null); then
      last="\${output##*$'\\n'}"
      amount="\${last%%$'\\t'*}"
      if [[ "$amount" = <-> ]]; then
        (( cleaner_bytes += amount * 1024, cleaner_measured += \${#cleaner_chunk} ))
        continue
      fi
    fi
    for item in "\${cleaner_chunk[@]}"; do
      if output=$(/usr/bin/du -skP "$item" 2>/dev/null); then
        amount="\${output%%$'\\t'*}"
        if [[ "$amount" = <-> ]]; then
          (( cleaner_bytes += amount * 1024, cleaner_measured++ )); continue
        fi
      fi
      (( cleaner_skipped++, cleaner_protected++ ))
    done
  done
  return 0
}
`;

  function scan(id, downloadsDays) {
    // Do not request Finder Automation or filesystem access just to scan Trash.
    // Finder can empty it even when TCC prevents reading its size.
    if (id === 'trash') return "printf 'UNKNOWN\\n'\n";
    const cutoff = `integer cleaner_cutoff=$(( $(/bin/date +%s) - ${days(downloadsDays)} * 86400 ))\n`;
    if (id === 'brew') {
      return preamble + `
if ! command -v brew >/dev/null 2>&1; then
  printf 'UNAVAILABLE\\tHomebrew is not installed\\n'
  exit 0
fi
cleaner_collect 'Library/Caches/Homebrew' 'brew'
cleaner_measure
printf 'TOTAL\\t%s\\t%s\\n' "$cleaner_bytes" "$cleaner_measured"
printf 'SKIPPED\\t%s\\t%s\\n' "$cleaner_skipped" "$cleaner_protected"
`;
    }
    if (!Object.hasOwn(roots, id)) throw new Error('Unknown cleanup category.');
    return preamble + cutoff + roots[id].map(([tag, relative]) => `
cleaner_collect ${quote(relative)} ${quote(id)}
cleaner_measure
printf 'PART\\t%s\\t%s\\t%s\\n' ${quote(tag)} "$cleaner_bytes" "$cleaner_measured"
(( cleaner_total += cleaner_bytes, cleaner_count += cleaner_measured ))
`).join('') + `printf 'TOTAL\\t%s\\t%s\\n' "$cleaner_total" "$cleaner_count"
printf 'SKIPPED\\t%s\\t%s\\n' "$cleaner_skipped" "$cleaner_protected"\n`;
  }

  function clean(id) {
    if (id === 'trash') {
      return `/usr/bin/osascript -e 'tell application "Finder" to empty trash' || exit 1
printf 'EMPTIED\\n'
`;
    }
    if (id === 'brew') {
      return `emulate -L zsh
command -v brew >/dev/null 2>&1 || { print -u2 'Homebrew is not installed.'; exit 1; }
command brew cleanup -s || exit 1
printf '\\nBREW_DONE\\n'
`;
    }
    throw new Error('Use nook.cleaner.clean to move eligible files to Trash.');
  }

  return { scan, clean, days };
})();
