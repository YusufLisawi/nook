/* Fixed cleanup roots. No stored values or filenames are interpolated into commands. */
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
    trash: [['trash', '.Trash']],
  };
  const quote = (value) => "'" + String(value).replace(/'/g, "'\\''") + "'";
  const days = (value) => Math.min(365, Math.max(7, Math.round(Number(value) || 60)));

  const preamble = `emulate -L zsh
unsetopt ALIASES
setopt PIPE_FAIL
cleaner_home="$HOME"
[[ "$cleaner_home" = /* && "$cleaner_home" != / && -d "$cleaner_home" && ! -L "$cleaner_home" ]] || { print -u2 'Cannot safely access your home folder.'; exit 1; }
typeset -a cleaner_items cleaner_chunk
integer cleaner_total=0 cleaner_count=0 cleaner_moved=0 cleaner_failed=0 cleaner_bytes=0

# Reject symlinks at every component so an allowed root cannot lead elsewhere.
cleaner_root() {
  local relative="$1" component cursor="$cleaner_home"
  for component in "\${(@s:/:)relative}"; do
    cursor="$cursor/$component"
    [[ ! -L "$cursor" ]] || { print -u2 "Skipped symlink folder: $cursor"; return 1; }
    [[ -e "$cursor" ]] || return 2
    [[ -d "$cursor" && -r "$cursor" && -x "$cursor" ]] || { print -u2 "Cannot read folder: $cursor"; return 1; }
  done
  cleaner_root_path="$cursor"
}

cleaner_collect() {
  local relative="$1" kind="$2" item modified
  integer root_code
  cleaner_items=()
  cleaner_root "$relative"
  root_code=$?
  (( root_code == 2 )) && return 0
  (( root_code == 0 )) || return 1
  for item in "$cleaner_root_path"/*(DN); do
    if [[ "$kind" = caches ]]; then
      # These are owned by the Package caches / Homebrew rows.
      case "\${item:t}" in com.apple.*|Yarn|yarn|pip|CocoaPods|cocoapods|Homebrew|homebrew) continue ;; esac
    fi
    if [[ "$kind" = downloads ]]; then
      # Only immediate regular files, by modification time; never downloaded folders.
      [[ -f "$item" && ! -L "$item" ]] || continue
      modified=$(/usr/bin/stat -f %m "$item") || return 1
      [[ "$modified" = <-> ]] || return 1
      (( modified < cleaner_cutoff )) || continue
    fi
    cleaner_items+=("$item")
  done
}

cleaner_measure() {
  local output last amount
  integer offset
  cleaner_bytes=0
  # Bounded argument lists, one du process at a time. -P never follows symlinks.
  for (( offset=1; offset<=\${#cleaner_items}; offset+=64 )); do
    cleaner_chunk=("\${(@)cleaner_items[$offset,$((offset + 63))]}")
    output=$(/usr/bin/du -skcP "\${cleaner_chunk[@]}") || return 1
    last="\${output##*$'\\n'}"
    amount="\${last%%$'\\t'*}"
    [[ "$amount" = <-> ]] || { print -u2 'Could not read a folder size.'; return 1; }
    (( cleaner_bytes += amount * 1024 ))
  done
  return 0
}
`;

  function scan(id, downloadsDays) {
    const cutoff = `integer cleaner_cutoff=$(( $(/bin/date +%s) - ${days(downloadsDays)} * 86400 ))\n`;
    if (id === 'brew') {
      return preamble + `
if ! command -v brew >/dev/null 2>&1; then
  printf 'UNAVAILABLE\\tHomebrew is not installed\\n'
  exit 0
fi
cleaner_brew_cache=$(command brew --cache) || exit 1
[[ "$cleaner_brew_cache" = /* ]] || { print -u2 'Homebrew returned an invalid cache path.'; exit 1; }
if [[ -d "$cleaner_brew_cache" && ! -L "$cleaner_brew_cache" ]]; then
  cleaner_items=("$cleaner_brew_cache")
  cleaner_measure || exit 1
fi
printf 'TOTAL\\t%s\\t0\\n' "$cleaner_bytes"
`;
    }
    if (!roots[id]) throw new Error('Unknown cleanup category.');
    return preamble + cutoff + roots[id].map(([tag, relative]) => `
cleaner_collect ${quote(relative)} ${quote(id)} || exit 1
cleaner_measure || exit 1
printf 'PART\\t%s\\t%s\\t%s\\n' ${quote(tag)} "$cleaner_bytes" "\${#cleaner_items}"
(( cleaner_total += cleaner_bytes, cleaner_count += \${#cleaner_items} ))
`).join('') + `printf 'TOTAL\\t%s\\t%s\\n' "$cleaner_total" "$cleaner_count"\n`;
  }

  const moveFunctions = `
cleaner_prepare_trash() {
  cleaner_root '.Trash'
  local trash_code=$?
  if (( trash_code == 2 )); then
    /bin/mkdir -m 700 "$cleaner_home/.Trash" || return 1
    cleaner_root '.Trash' || return 1
  elif (( trash_code != 0 )); then
    return 1
  fi
  [[ -w "$cleaner_home/.Trash" ]] || { print -u2 'Cannot write to Trash.'; return 1; }
}

cleaner_move() {
  local relative="$1" kind="$2" item suffix destination output amount modified
  typeset -a pending
  cleaner_collect "$relative" "$kind" || return 1
  pending=("\${cleaner_items[@]}")
  for item in "\${pending[@]}"; do
    # Recheck the root and destination immediately before each move.
    cleaner_root "$relative" || return 1
    cleaner_root '.Trash' || return 1
    [[ -e "$item" || -L "$item" ]] || continue
    if [[ "$kind" = downloads ]]; then
      [[ -f "$item" && ! -L "$item" ]] || continue
      modified=$(/usr/bin/stat -f %m "$item") || { (( cleaner_failed++ )); continue; }
      [[ "$modified" = <-> ]] || { (( cleaner_failed++ )); continue; }
      (( modified < cleaner_cutoff )) || continue
    fi
    cleaner_items=("$item")
    if ! cleaner_measure; then (( cleaner_failed++ )); continue; fi
    amount=$cleaner_bytes
    suffix=$(/usr/bin/uuidgen) || return 1
    # Shorten only the destination name to leave room for the unique suffix.
    destination="$cleaner_home/.Trash/\${\${item:t}[1,48]}-nook-$suffix"
    [[ ! -e "$destination" && ! -L "$destination" ]] || { (( cleaner_failed++ )); continue; }
    if /bin/mv -n "$item" "$destination"; then
      if [[ ! -e "$item" && ! -L "$item" && ( -e "$destination" || -L "$destination" ) ]]; then
        (( cleaner_total += amount, cleaner_moved++ ))
      else
        print -u2 "Could not verify move: $item"
        (( cleaner_failed++ ))
      fi
    else
      (( cleaner_failed++ ))
    fi
  done
  return 0
}
`;

  function clean(id, downloadsDays) {
    if (id === 'trash') {
      return preamble + `
cleaner_root '.Trash'
cleaner_root_code=$?
if (( cleaner_root_code == 2 )); then printf 'EMPTIED\\n'; exit 0; fi
(( cleaner_root_code == 0 )) || exit 1
/usr/bin/osascript -e 'tell application "Finder" to empty trash' || exit 1
printf 'EMPTIED\\n'
`;
    }
    if (id === 'brew') {
      return preamble + `
command -v brew >/dev/null 2>&1 || { print -u2 'Homebrew is not installed.'; exit 1; }
command brew cleanup -s || exit 1
printf '\\nBREW_DONE\\n'
`;
    }
    if (!roots[id]) throw new Error('Unknown cleanup category.');
    return preamble + `integer cleaner_cutoff=$(( $(/bin/date +%s) - ${days(downloadsDays)} * 86400 ))\n` + moveFunctions + `
cleaner_prepare_trash || exit 1
` + roots[id].map(([, relative]) => `
if ! cleaner_move ${quote(relative)} ${quote(id)}; then (( cleaner_failed++ )); fi
`).join('') + `printf 'MOVED\\t%s\\t%s\\t%s\\n' "$cleaner_total" "$cleaner_moved" "$cleaner_failed"\n`;
  }

  return { scan, clean, days };
})();
