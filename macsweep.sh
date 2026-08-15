#!/usr/bin/env bash
#
# macsweep — reclaim disk space on macOS.
#
# Dry-run by default. Nothing is deleted unless you pass --apply.
#
#   ./macsweep.sh                     # report only
#   ./macsweep.sh --apply             # delete the safe categories
#   ./macsweep.sh --only xcode,brew   # limit to specific categories
#   ./macsweep.sh --list              # show categories
#
set -uo pipefail

VERSION="0.2.0"

APPLY=0
ASSUME_YES=0
ONLY=""
SKIP=""
LIST=0
LARGE=0

TOTAL_KB=0
REPORT_KB=0

# ---------------------------------------------------------------- formatting

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_CYN=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_GRN=""; C_YLW=""; C_RED=""; C_CYN=""
fi

human_kb() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576)   printf "%.2f GB", k/1048576
    else if (k >= 1024) printf "%.1f MB", k/1024
    else                printf "%d KB",   k
  }'
}

info()  { printf '%s\n' "$*"; }
warn()  { printf '%s%s%s\n' "$C_YLW" "$*" "$C_RESET" >&2; }
err()   { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

# Headers are deferred so a category that finds nothing prints nothing at all.
PENDING_HEAD=""
head2() { PENDING_HEAD="$*"; }
flush_head() {
  [[ -n "$PENDING_HEAD" ]] || return 0
  printf '\n%s%s%s\n' "$C_BOLD" "$PENDING_HEAD" "$C_RESET"
  PENDING_HEAD=""
}

# Prints one aligned result row.
row() {
  local label="$1" kb="$2" note="${3:-}"
  flush_head
  printf '  %-34s %s%12s%s  %s%s%s\n' \
    "$label" "$C_CYN" "$(human_kb "$kb")" "$C_RESET" "$C_DIM" "$note" "$C_RESET"
}

# A row for an action whose reclaimed bytes cannot be measured up front.
action_row() {
  local label="$1" note="${2:-}"
  flush_head
  printf '  %-34s %12s  %s%s%s\n' "$label" "—" "$C_DIM" "$note" "$C_RESET"
}

# ---------------------------------------------------------------- safety

# $HOME may itself be a symlink (e.g. /Users/foo -> /Volumes/Data/foo).
# Compare resolved paths against this, not the lexical $HOME string.
HOME_REAL="$(realpath "$HOME" 2>/dev/null || printf '%s' "$HOME")"

_is_forbidden_root() {
  local p="$1" root="$2"
  case "$p" in
    "/"|"$root"|"$root/"|"$root/Library"|"$root/Documents"|"$root/Desktop") return 0 ;;
  esac
  return 1
}

# Only paths under $HOME are ever eligible for deletion, and never $HOME itself
# or a bare first-level Library / Documents / Desktop directory.
# A symlink is allowed only as a link to remove: its target must still resolve
# under $HOME, but purge_contents never walks through it.
is_safe_target() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" == *".."* ]] && return 1
  _is_forbidden_root "$p" "$HOME" && return 1
  [[ "$p" == "$HOME"/?* ]] || return 1

  if [[ -e "$p" || -L "$p" ]]; then
    local real
    real="$(realpath "$p" 2>/dev/null)" || return 1
    _is_forbidden_root "$real" "$HOME_REAL" && return 1
    [[ "$real" == "$HOME_REAL"/?* ]] || return 1
  fi
  return 0
}

# du prints nothing at all when a path is readable by stat(2) but not by
# readdir(2) — the shape of a TCC-blocked container. Validate rather than lean
# on `set -o pipefail` turning that into a non-zero status for an `|| echo 0`
# fallback to catch; this stays correct if pipefail is ever dropped.
size_kb() {
  local total=0 p sz
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    sz="$(du -sk "$p" 2>/dev/null | awk 'END{print $1}')"
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    total=$(( total + sz ))
  done
  printf '%d' "$total"
}

# Delete a file, a symlink (the link only), or the *contents* of a directory.
# Never follow a symlink: `rm -rf link/` would walk the target; we refuse that.
purge_contents() {
  local d="$1"
  is_safe_target "$d" || { err "refusing unsafe path: $d"; return 1; }
  if [[ -L "$d" || -f "$d" ]]; then
    rm -f -- "$d" 2>/dev/null
    return 0
  fi
  [[ -d "$d" ]] || return 0
  find -P "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
}

# ---------------------------------------------------------------- categories

# Registry: name|description. Order here is the order they run in.
CATEGORIES=(
  "trash|Trash"
  "user-caches|~/Library/Caches (app caches)"
  "logs|~/Library/Logs"
  "xcode|Xcode DerivedData, device support, caches"
  "simulators|Unavailable simulators + simulator caches"
  "swiftpm|Swift Package Manager cache"
  "cocoapods|CocoaPods + Carthage caches"
  "brew|Homebrew downloads and old versions"
  "node|npm / yarn / pnpm / bun caches"
  "python|pip cache"
  "rust|cargo registry cache"
  "go|Go module cache + build cache (slow to rebuild)"
  "docker|Docker unused images, containers, build cache"
  "report|Report-only: things you should decide on yourself"
)

category_enabled() {
  local name="$1"
  if [[ -n "$ONLY" ]]; then
    [[ ",$ONLY," == *",$name,"* ]] || return 1
  fi
  if [[ -n "$SKIP" ]]; then
    [[ ",$SKIP," == *",$name,"* ]] && return 1
  fi
  return 0
}

# sweep <label> <path>...   — measure, report, and delete contents under --apply
sweep() {
  local label="$1"; shift
  local kb; kb=$(size_kb "$@")
  (( kb == 0 )) && return 0
  row "$label" "$kb"
  TOTAL_KB=$(( TOTAL_KB + kb ))
  if (( APPLY )); then
    local p
    for p in "$@"; do purge_contents "$p"; done
  fi
}

# sweep_cmd <label> <probe-binary> <command...>  — delegate to a tool's own GC.
# The freed bytes are not attributable to a path, so these never touch TOTAL_KB
# and print no size rather than a misleading "0 KB".
sweep_cmd() {
  local label="$1" probe="$2"; shift 2
  command -v "$probe" >/dev/null 2>&1 || return 0
  if (( APPLY )); then
    action_row "$label" "running: $*"
    "$@" >/dev/null 2>&1 || warn "    (\"$*\" exited non-zero)"
  else
    action_row "$label" "would run: $*"
  fi
}

# note <label> <path>...  — measure and report, never delete.
# A TCC-blocked path exists but measures 0, which is indistinguishable from
# "not there" unless we say so; otherwise Mail and Messages quietly vanish from
# the report on every machine without Full Disk Access.
note() {
  local label="$1"; shift
  local kb; kb=$(size_kb "$@")
  if (( kb == 0 )); then
    local p
    for p in "$@"; do
      if [[ -e "$p" ]] && ! du -sk "$p" >/dev/null 2>&1; then
        row "$label" 0 "unreadable — grant Full Disk Access"
        return 0
      fi
    done
    return 0
  fi
  row "$label" "$kb" "review manually"
  REPORT_KB=$(( REPORT_KB + kb ))
}

run_trash() {
  head2 "Trash"
  sweep "~/.Trash" "$HOME/.Trash"
}

run_user_caches() {
  head2 "User caches"
  # Deleted wholesale; every app here regenerates its cache on next launch.
  # Two kinds of entry are excluded: ones where emptying the cache loses real
  # state, and ones owned by a dedicated category below. Without the second
  # group these subtrees get measured twice in the dry-run total, and `--skip
  # node` would still lose the Yarn cache to this category.
  local excl=(
    "com.apple.containermanagerd"
    "com.apple.HomeKit"
    "com.apple.homed"
    "com.apple.accountsd"
    "com.apple.appleaccountd"
    "com.apple.amsaccountsd"
    "com.apple.passd"
    "CloudKit"
    "FamilyCircle"
    "familycircled"
    "PassKit"
    "org.swift.swiftpm"
    "CocoaPods"
    "Homebrew"
    "com.apple.dt.Xcode"
    "org.carthage.CarthageKit"
    "Yarn"
    "pnpm"
    "bun"
    "deno"
    "node-gyp"
    "pip"
    "go-build"
  )
  local kb=0 keep entry name skipit
  local victims=()
  for entry in "$HOME/Library/Caches"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    skipit=0
    for keep in "${excl[@]}"; do
      if [[ "$name" == "$keep" || "$name" == "$keep".* ]]; then
        skipit=1
        break
      fi
    done
    (( skipit )) && continue
    victims+=("$entry")
  done
  (( ${#victims[@]} == 0 )) && return 0
  kb=$(size_kb "${victims[@]}")
  row "~/Library/Caches" "$kb" "${#victims[@]} entries"
  TOTAL_KB=$(( TOTAL_KB + kb ))
  if (( APPLY )); then
    local v
    for v in "${victims[@]}"; do purge_contents "$v"; done
  fi
}

run_logs() {
  head2 "Logs"
  # DiagnosticReports lives inside ~/Library/Logs; sweeping it separately would
  # count the same bytes twice in the dry-run total.
  sweep "~/Library/Logs" "$HOME/Library/Logs"
}

run_xcode() {
  local dev="$HOME/Library/Developer"
  [[ -d "$dev" ]] || return 0
  head2 "Xcode"
  sweep "DerivedData"            "$dev/Xcode/DerivedData"
  sweep "iOS DeviceSupport"      "$dev/Xcode/iOS DeviceSupport"
  sweep "watchOS DeviceSupport"  "$dev/Xcode/watchOS DeviceSupport"
  sweep "tvOS DeviceSupport"     "$dev/Xcode/tvOS DeviceSupport"
  sweep "Xcode caches"           "$HOME/Library/Caches/com.apple.dt.Xcode"
  sweep "Previews cache"         "$dev/Xcode/UserData/Previews"
  # Archives hold the dSYMs you need to symbolicate shipped-app crashes.
  note  "Xcode Archives (KEEP)"  "$dev/Xcode/Archives"
}

run_simulators() {
  local dev="$HOME/Library/Developer"
  [[ -d "$dev/CoreSimulator" ]] || return 0
  head2 "Simulators"
  sweep "CoreSimulator caches" "$dev/CoreSimulator/Caches"
  # Unavailable devices only — the Devices tree as a whole is not deleted.
  sweep_cmd "delete unavailable simulators" xcrun xcrun simctl delete unavailable
}

run_swiftpm() {
  head2 "Swift Package Manager"
  sweep "SwiftPM cache" \
    "$HOME/Library/Caches/org.swift.swiftpm" \
    "$HOME/Library/org.swift.swiftpm/cache"
}

run_cocoapods() {
  head2 "CocoaPods / Carthage"
  sweep "CocoaPods cache"  "$HOME/Library/Caches/CocoaPods"
  sweep "Carthage cache"   "$HOME/Library/Caches/org.carthage.CarthageKit"
}

run_brew() {
  command -v brew >/dev/null 2>&1 || return 0
  head2 "Homebrew"
  local cache; cache="$(brew --cache 2>/dev/null)"
  if [[ -n "$cache" && -d "$cache" ]]; then
    local kb; kb=$(size_kb "$cache")
    row "brew cache" "$kb"
    TOTAL_KB=$(( TOTAL_KB + kb ))
  fi
  sweep_cmd "brew cleanup" brew brew cleanup -s --prune=all
}

run_node() {
  head2 "Node"
  sweep "npm _cacache"   "$HOME/.npm/_cacache"
  sweep "yarn cache"     "$HOME/Library/Caches/Yarn"
  sweep "pnpm cache"     "$HOME/Library/Caches/pnpm"
  sweep "bun cache"      "$HOME/.bun/install/cache"
  sweep "node-gyp cache" "$HOME/Library/Caches/node-gyp"
  sweep_cmd "pnpm store prune" pnpm pnpm store prune
}

run_python() {
  head2 "Python"
  sweep "pip cache" "$HOME/Library/Caches/pip"
  sweep "uv cache"  "$HOME/.cache/uv"
}

run_rust() {
  [[ -d "$HOME/.cargo" ]] || return 0
  head2 "Rust"
  sweep "cargo registry cache" "$HOME/.cargo/registry/cache"
  sweep "cargo registry src"   "$HOME/.cargo/registry/src"
}

run_go() {
  command -v go >/dev/null 2>&1 || return 0
  head2 "Go"
  local gomod gocache
  gomod="$(go env GOMODCACHE 2>/dev/null)"
  gocache="$(go env GOCACHE 2>/dev/null)"
  if [[ -n "$gomod" && -d "$gomod" ]]; then
    local kb; kb=$(size_kb "$gomod")
    row "module cache" "$kb" "re-downloads on next build"
    TOTAL_KB=$(( TOTAL_KB + kb ))
    if (( APPLY )); then
      if is_safe_target "$gomod"; then
        go clean -modcache >/dev/null 2>&1
      else
        err "refusing go modcache outside home: $gomod"
      fi
    fi
  fi
  # go-build lives in ~/Library/Caches; excluded from user-caches so --skip go
  # actually preserves it.
  [[ -n "$gocache" && -d "$gocache" ]] && sweep "build cache" "$gocache"
}

run_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || { head2 "Docker"; row "Docker" 0 "daemon not running"; return 0; }
  head2 "Docker"
  # Named volumes are excluded on purpose — that is where your data lives.
  sweep_cmd "docker system prune" docker docker system prune -af
}

run_report() {
  head2 "Report only — decide for yourself"
  note "iOS device backups"   "$HOME/Library/Application Support/MobileSync/Backup"
  note "Downloads"            "$HOME/Downloads"
  note "Mail downloads"       "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  note "Messages attachments" "$HOME/Library/Messages/Attachments"

  local snaps
  snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)"
  if [[ "${snaps:-0}" -gt 0 ]]; then
    row "Time Machine local snapshots" 0 "$snaps found — 'tmutil deletelocalsnapshots <date>'"
  fi
}

run_large() {
  head2 "Largest items in \$HOME (top 20)"
  # head closes the pipe early; without the `|| true`, pipefail would surface
  # SIGPIPE from sort/du as a failed category.
  du -sk "$HOME"/* "$HOME"/.[!.]* 2>/dev/null \
    | sort -rn | { head -20 || true; } \
    | while read -r kb path; do row "$(basename "$path")" "$kb" "$path"; done
}

# ---------------------------------------------------------------- cli

usage() {
  cat <<EOF
macsweep $VERSION — reclaim disk space on macOS

USAGE
  ./macsweep.sh [options]

OPTIONS
  --apply           Actually delete. Without this, everything is a dry run.
  -y, --yes         Skip the confirmation prompt when using --apply.
  --only  a,b,c     Run only these categories.
  --skip  a,b,c     Run everything except these categories.
  --large           Also list the 20 largest items in \$HOME.
  --list            List categories and exit.
  -h, --help        This.

NOTES
  Terminal needs Full Disk Access (System Settings > Privacy & Security)
  to read or remove some paths under ~/Library/Containers.
EOF
}

# `--only` with a missing value used to leave ONLY empty, which means "no
# filter" — so a typo'd restricted run silently swept everything.
need_arg() {
  [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || { err "option $1 requires a value"; exit 2; }
}

while (( $# )); do
  case "$1" in
    --apply)       APPLY=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --only)        need_arg "$1" "${2:-}"; ONLY="$2"; shift ;;
    --skip)        need_arg "$1" "${2:-}"; SKIP="$2"; shift ;;
    --large)       LARGE=1 ;;
    --list)        LIST=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

# A misspelled category is silent otherwise: it just matches nothing.
validate_names() {
  local flag="$1" list="$2" name found entry
  [[ -n "$list" ]] || return 0
  local IFS=','
  for name in $list; do
    found=0
    for entry in "${CATEGORIES[@]}"; do
      [[ "${entry%%|*}" == "$name" ]] && found=1 && break
    done
    (( found )) || { err "$flag: unknown category '$name' (see --list)"; exit 2; }
  done
}
validate_names --only "$ONLY"
validate_names --skip "$SKIP"

if (( LIST )); then
  printf '%sCategories%s\n' "$C_BOLD" "$C_RESET"
  for entry in "${CATEGORIES[@]}"; do
    printf '  %-14s %s\n' "${entry%%|*}" "${entry#*|}"
  done
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || { err "macsweep is macOS-only."; exit 1; }
[[ "$(id -u)" == "0" ]] && { err "Do not run macsweep as root."; exit 1; }

if (( APPLY )) && ! (( ASSUME_YES )); then
  # Without a tty there is nobody to answer, and `read` would leave $reply
  # unset — fatal under `set -u`. Refuse rather than guess.
  [[ -t 0 ]] || { err "--apply needs a tty to confirm; pass -y for unattended runs."; exit 2; }
  reply=""
  printf '%sThis will permanently delete caches and derived data. Continue? [y/N] %s' \
    "$C_YLW" "$C_RESET"
  read -r reply || reply=""
  [[ "$reply" == [yY]* ]] || { info "Aborted."; exit 0; }
fi

before_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"

if (( APPLY )); then
  printf '%sMode: APPLY — deleting%s\n' "$C_RED$C_BOLD" "$C_RESET"
else
  printf '%sMode: DRY RUN — nothing will be deleted (pass --apply to act)%s\n' \
    "$C_GRN$C_BOLD" "$C_RESET"
fi

for entry in "${CATEGORIES[@]}"; do
  name="${entry%%|*}"
  category_enabled "$name" || continue
  case "$name" in
    trash)       run_trash ;;
    user-caches) run_user_caches ;;
    logs)        run_logs ;;
    xcode)       run_xcode ;;
    simulators)  run_simulators ;;
    swiftpm)     run_swiftpm ;;
    cocoapods)   run_cocoapods ;;
    brew)        run_brew ;;
    node)        run_node ;;
    python)      run_python ;;
    rust)        run_rust ;;
    go)          run_go ;;
    docker)      run_docker ;;
    report)      run_report ;;
  esac
done

(( LARGE )) && run_large

after_kb="$(df -k "$HOME" | awk 'NR==2{print $4}')"

head2 "Summary"
row "Measured on disk" "$TOTAL_KB"
if (( APPLY )); then
  reclaimed=$(( after_kb - before_kb ))
  (( reclaimed < 0 )) && reclaimed=0
  row "Free space delta (df)" "$reclaimed"
  # APFS keeps deleted blocks pinned while a Time Machine local snapshot still
  # references them, so df can report a near-zero delta after a large sweep.
  # "Measured on disk" is the honest number; this one is the observable one.
  if (( reclaimed * 2 < TOTAL_KB )); then
    printf '  %sdf lags the deletes — usually APFS local snapshots still pinning the blocks.%s\n' \
      "$C_DIM" "$C_RESET"
  fi
fi
row "Free space now" "$after_kb"
(( REPORT_KB > 0 )) && row "Flagged for manual review" "$REPORT_KB"
printf '  %s(brew/docker/simctl free additional space not counted above)%s\n' "$C_DIM" "$C_RESET"

# Guard the exit status: the last command above is a conditional that returns 1
# whenever REPORT_KB is zero, which made successful runs look like failures.
exit 0
