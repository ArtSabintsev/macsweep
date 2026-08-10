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

VERSION="0.1.0"

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

# ---------------------------------------------------------------- safety

# Only paths under $HOME are ever eligible for deletion, and never $HOME itself
# or a bare first-level Library directory we did not explicitly name.
is_safe_target() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  case "$p" in
    "/"|"$HOME"|"$HOME/"|"$HOME/Library"|"$HOME/Documents"|"$HOME/Desktop") return 1 ;;
  esac
  [[ "$p" == "$HOME"/?* ]] || return 1
  [[ "$p" == *".."* ]] && return 1
  return 0
}

size_kb() {
  local total=0 p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    total=$(( total + $(du -sk "$p" 2>/dev/null | awk '{print $1}' || echo 0) ))
  done
  printf '%d' "$total"
}

# Delete the *contents* of a directory, leaving the directory itself in place.
purge_contents() {
  local d="$1"
  is_safe_target "$d" || { err "refusing unsafe path: $d"; return 1; }
  [[ -d "$d" ]] || return 0
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
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
  "node|npm / yarn / pnpm caches"
  "python|pip cache"
  "rust|cargo registry cache"
  "go|Go module cache (slow to rebuild)"
  "docker|Docker dangling images, containers, build cache"
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

# sweep_cmd <label> <probe-binary> <command...>  — delegate to a tool's own GC
sweep_cmd() {
  local label="$1" probe="$2"; shift 2
  command -v "$probe" >/dev/null 2>&1 || return 0
  if (( APPLY )); then
    row "$label" 0 "running: $*"
    "$@" >/dev/null 2>&1 || warn "    (\"$*\" exited non-zero)"
  else
    row "$label" 0 "would run: $*"
  fi
}

# note <label> <path>...  — measure and report, never delete
note() {
  local label="$1"; shift
  local kb; kb=$(size_kb "$@")
  (( kb == 0 )) && return 0
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
  # A few entries are excluded because emptying them logs you out or is
  # handled by a dedicated category below.
  local excl=(
    "com.apple.containermanagerd"
    "com.apple.HomeKit"
    "CloudKit"
    "org.swift.swiftpm"
    "CocoaPods"
    "Homebrew"
  )
  local kb=0 keep entry name skipit
  local victims=()
  for entry in "$HOME/Library/Caches"/*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    skipit=0
    for keep in "${excl[@]}"; do
      [[ "$name" == "$keep" ]] && skipit=1 && break
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
    for v in "${victims[@]}"; do
      is_safe_target "$v" && rm -rf -- "$v" 2>/dev/null
    done
  fi
}

run_logs() {
  head2 "Logs"
  sweep "~/Library/Logs" "$HOME/Library/Logs"
  sweep "DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports"
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
  local kb; kb=$(size_kb "$dev/CoreSimulator/Devices")
  row "CoreSimulator/Devices" "$kb" "pruned via simctl, not rm"
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
  local gomod; gomod="$(go env GOMODCACHE 2>/dev/null)"
  [[ -n "$gomod" && -d "$gomod" ]] || return 0
  local kb; kb=$(size_kb "$gomod")
  row "module cache" "$kb" "re-downloads on next build"
  TOTAL_KB=$(( TOTAL_KB + kb ))
  if (( APPLY )); then go clean -modcache >/dev/null 2>&1; fi
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
  du -sk "$HOME"/* "$HOME"/.[!.]* 2>/dev/null \
    | sort -rn | head -20 \
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

while (( $# )); do
  case "$1" in
    --apply)       APPLY=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --only)        ONLY="${2:-}"; shift ;;
    --skip)        SKIP="${2:-}"; shift ;;
    --large)       LARGE=1 ;;
    --list)        LIST=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

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
  printf '%sThis will permanently delete caches and derived data. Continue? [y/N] %s' \
    "$C_YLW" "$C_RESET"
  read -r reply
  [[ "$reply" == [yY]* ]] || { info "Aborted."; exit 0; }
fi

before_kb="$(df -k / | awk 'NR==2{print $4}')"

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

after_kb="$(df -k / | awk 'NR==2{print $4}')"

head2 "Summary"
if (( APPLY )); then
  reclaimed=$(( after_kb - before_kb ))
  (( reclaimed < 0 )) && reclaimed=0
  row "Actually reclaimed (df delta)" "$reclaimed"
  row "Free space now" "$after_kb"
else
  row "Reclaimable (measured)" "$TOTAL_KB"
  row "Free space now" "$after_kb"
  printf '  %s(plus whatever brew/docker/simctl free — not counted above)%s\n' "$C_DIM" "$C_RESET"
fi
(( REPORT_KB > 0 )) && row "Flagged for manual review" "$REPORT_KB"
