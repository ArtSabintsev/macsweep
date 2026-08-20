#!/usr/bin/env bash
#
# macsweep — reclaim disk space on macOS. Dry-run unless --apply.
#
set -uo pipefail

VERSION="0.4.0"
INVOKED="$0"
SELF="$(basename "$0")"

APPLY=0
ASSUME_YES=0
ONLY=""
SKIP=""
LIST=0
LARGE=0

TOTAL_KB=0
REPORT_KB=0

LCACHE="$HOME/Library/Caches"
LDEV="$HOME/Library/Developer"

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

warn() { printf '%s%s%s\n' "$C_YLW" "$*" "$C_RESET" >&2; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Headers are deferred so a category that finds nothing prints nothing.
PENDING_HEAD=""
head2() { PENDING_HEAD="$*"; }
flush_head() {
  [[ -n "$PENDING_HEAD" ]] || return 0
  printf '\n%s%s%s\n' "$C_BOLD" "$PENDING_HEAD" "$C_RESET"
  PENDING_HEAD=""
}

row() {
  local label="$1" kb="$2" note="${3:-}"
  flush_head
  printf '  %-34s %s%12s%s  %s%s%s\n' \
    "$label" "$C_CYN" "$(human_kb "$kb")" "$C_RESET" "$C_DIM" "$note" "$C_RESET"
}

action_row() {
  local label="$1" note="${2:-}"
  flush_head
  printf '  %-34s %12s  %s%s%s\n' "$label" "—" "$C_DIM" "$note" "$C_RESET"
}

# ---------------------------------------------------------------- safety

# realpath(1) is macOS 13+; python3 / cd -P cover older hosts.
resolved() {
  local p="$1" r dir base
  r="$(realpath "$p" 2>/dev/null)" && [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  if have python3; then
    r="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" \
      && [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  fi
  if [[ -d "$p" ]]; then
    r="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
    [[ -n "$r" ]] || return 1
    printf '%s' "$r"
    return 0
  elif [[ -e "$p" || -L "$p" ]]; then
    dir="$(CDPATH= cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename -- "$p")"
    printf '%s/%s' "$dir" "$base"
    return 0
  fi
  return 1
}

# $HOME may be a symlink. Compare resolved paths, not the lexical string.
HOME_REAL="$(resolved "$HOME" 2>/dev/null || printf '%s' "$HOME")"

# ~user reads passwd, not $HOME. A redirected HOME (tests, or HOME=/tmp)
# must not drive brew/docker/simctl against the login machine.
LOGIN_HOME="$(eval printf '%s' "~$(id -un)")"
LOGIN_HOME_REAL="$(resolved "$LOGIN_HOME" 2>/dev/null || printf '%s' "$LOGIN_HOME")"

host_tools_allowed() { [[ "$HOME_REAL" == "$LOGIN_HOME_REAL" ]]; }

_is_forbidden_root() {
  local p="$1" root="$2"
  case "$p" in
    "/"|"$root"|"$root/"|"$root/Library"|"$root/Documents"|"$root/Desktop") return 0 ;;
  esac
  return 1
}

# Deletion is $HOME-only, never $HOME itself or a bare Library/Documents/Desktop.
# Symlinks may be unlinked; purge_contents never walks through them.
is_safe_target() {
  local p="${1:-}" real
  [[ -n "$p" ]] || return 1
  [[ "$p" == *".."* ]] && return 1
  _is_forbidden_root "$p" "$HOME" && return 1
  [[ "$p" == "$HOME"/?* ]] || return 1
  if [[ -e "$p" || -L "$p" ]]; then
    real="$(resolved "$p")" || return 1
    _is_forbidden_root "$real" "$HOME_REAL" && return 1
    [[ "$real" == "$HOME_REAL"/?* ]] || return 1
  fi
  return 0
}

# Prefer a tool-reported cache dir when it lives under $HOME; else $fallback.
# Stops `go env` under a fake $HOME from pointing at the login home.
cmd_home_path() {
  local fallback="$1" bin="$2"; shift 2
  if host_tools_allowed && have "$bin" && (( $# )); then
    local got
    got="$("$@" 2>/dev/null)" || got=""
    got="${got%%$'\n'*}"; got="${got%$'\r'}"
    if [[ -n "$got" && "$got" != "undefined" && "$got" != "null" ]] \
      && is_safe_target "$got"; then
      printf '%s' "$got"
      return 0
    fi
  fi
  printf '%s' "$fallback"
}

# du prints nothing when stat(2) works but readdir(2) is TCC-blocked.
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

# Unlink a file/symlink; empty a directory (leave the directory).
# `rm -rf link/` would walk the target — we never do that.
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

# Fill _PATHS with unique args, dropping any path nested under another
# (`.../store` + `.../store/v10` counts once and deletes once).
_PATHS=()
_collect_paths() {
  _PATHS=()
  local raw=() out=() p q dup nest
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    case "$p" in undefined|null) continue ;; esac
    dup=0
    if (( ${#raw[@]} > 0 )); then
      for q in "${raw[@]}"; do
        [[ "$p" == "$q" ]] && { dup=1; break; }
      done
    fi
    (( dup )) && continue
    raw+=("$p")
  done
  (( ${#raw[@]} == 0 )) && return 0
  for p in "${raw[@]}"; do
    nest=0
    for q in "${raw[@]}"; do
      [[ "$p" == "$q"/* ]] && { nest=1; break; }
    done
    (( nest )) && continue
    out+=("$p")
  done
  (( ${#out[@]} == 0 )) && return 0
  _PATHS=("${out[@]}")
}

# ---------------------------------------------------------------- sweep

# sweep [--note TEXT] LABEL [--note TEXT] PATH...
sweep() {
  local note="" label p kb
  [[ "${1:-}" == --note ]] && { note="$2"; shift 2; }
  label="$1"; shift
  [[ "${1:-}" == --note ]] && { note="$2"; shift 2; }
  _collect_paths "$@"
  (( ${#_PATHS[@]} == 0 )) && return 0
  kb=$(size_kb "${_PATHS[@]}")
  (( kb == 0 )) && return 0
  row "$label" "$kb" "$note"
  TOTAL_KB=$(( TOTAL_KB + kb ))
  if (( APPLY )); then
    for p in "${_PATHS[@]}"; do purge_contents "$p"; done
  fi
}

sweep_glob() {
  local p
  for p in "$@"; do
    [[ -e "$p" || -L "$p" ]] || continue
    sweep "$(basename "$p")" "$p"
  done
}

# First word of the command is the probe binary. No-op if $HOME is redirected
# so fake-HOME tests cannot brew-cleanup the login machine.
sweep_cmd() {
  local label="$1"; shift
  have "$1" || return 0
  host_tools_allowed || return 0
  if (( APPLY )); then
    action_row "$label" "running: $*"
    "$@" >/dev/null 2>&1 || warn "    (\"$*\" exited non-zero)"
  else
    action_row "$label" "would run: $*"
  fi
}

# Measure, never delete. TCC-blocked paths exist but du as 0 — say so.
note() {
  local label="$1"; shift
  local kb p
  kb=$(size_kb "$@")
  if (( kb == 0 )); then
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

# ---------------------------------------------------------------- categories
# id|header|blurb. Order is run order. Dispatch is run_${id//-/_}.

CATEGORIES=(
  "trash|Trash|~/.Trash"
  "user-caches|User caches|~/Library/Caches, minus a keep-list"
  "logs|Logs|~/Library/Logs"
  "xcode|Xcode|DerivedData, DeviceSupport, caches, Previews"
  "simulators|Simulators|unavailable simulators + CoreSimulator caches"
  "swiftpm|Swift Package Manager|SwiftPM package cache"
  "cocoapods|CocoaPods / Carthage|CocoaPods + Carthage caches"
  "brew|Homebrew|downloads + brew cleanup"
  "node|Node|npm, yarn, pnpm, bun, node-gyp"
  "deno|Deno|Deno module cache"
  "python|Python|pip + uv caches"
  "rust|Rust|cargo registry + git caches"
  "go|Go|module cache + build cache"
  "docker|Docker|unused images, containers, build cache"
  "report|Report only|measured, never deleted"
)

# Apple/account state, or report-only (Playwright — slow to restore).
CACHE_KEEP=(
  com.apple.containermanagerd
  com.apple.HomeKit
  com.apple.homed
  com.apple.accountsd
  com.apple.appleaccountd
  com.apple.amsaccountsd
  com.apple.passd
  CloudKit
  FamilyCircle
  familycircled
  PassKit
  ms-playwright
)

# ~/Library/Caches entries a dedicated category already sweeps.
# Skip them here so --skip X works and dry-run totals do not double-count.
CACHE_OWNED=(
  org.swift.swiftpm
  CocoaPods
  Homebrew
  com.apple.dt.Xcode
  org.carthage.CarthageKit
  Yarn
  pnpm
  bun
  deno
  node-gyp
  pip
  uv
  go-build
)

_cache_kept() {
  local name="$1" k
  for k in "${CACHE_KEEP[@]}" "${CACHE_OWNED[@]}"; do
    [[ "$name" == "$k" || "$name" == "$k".* ]] && return 0
  done
  return 1
}

category_enabled() {
  local name="$1"
  [[ -n "$ONLY" && ",$ONLY," != *",$name,"* ]] && return 1
  [[ -n "$SKIP" && ",$SKIP," == *",$name,"* ]] && return 1
  return 0
}

run_trash()       { sweep "~/.Trash" "$HOME/.Trash"; }

run_user_caches() {
  local victims=() entry
  for entry in "$LCACHE"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    _cache_kept "$(basename "$entry")" && continue
    victims+=("$entry")
  done
  (( ${#victims[@]} == 0 )) && return 0
  sweep "~/Library/Caches" --note "${#victims[@]} entries" "${victims[@]}"
}

run_logs() { sweep "~/Library/Logs" "$HOME/Library/Logs"; }

run_xcode() {
  [[ -d "$LDEV" ]] || return 0
  sweep "DerivedData"          "$LDEV/Xcode/DerivedData"
  sweep_glob                   "$LDEV/Xcode/"*DeviceSupport
  sweep "Xcode caches"         "$LCACHE/com.apple.dt.Xcode"
  sweep "Previews cache"       "$LDEV/Xcode/UserData/Previews"
  sweep_glob                   "$LDEV/Xcode/"*"Device Logs"
  sweep "Documentation cache"  "$LDEV/Xcode/DocumentationCache" "$LDEV/Xcode/DocumentationIndex"
  note  "Xcode Archives (KEEP)" "$LDEV/Xcode/Archives"
}

run_simulators() {
  [[ -d "$LDEV/CoreSimulator" ]] || return 0
  sweep "CoreSimulator caches" "$LDEV/CoreSimulator/Caches"
  sweep_cmd "delete unavailable simulators" xcrun simctl delete unavailable
}

run_swiftpm() {
  sweep "SwiftPM cache" "$LCACHE/org.swift.swiftpm" "$HOME/Library/org.swift.swiftpm/cache"
}

run_cocoapods() {
  sweep "CocoaPods cache" "$LCACHE/CocoaPods"
  sweep "Carthage cache"  "$LCACHE/org.carthage.CarthageKit"
}

run_brew() {
  sweep "Homebrew cache" "$(cmd_home_path "$LCACHE/Homebrew" brew brew --cache)"
  sweep_cmd "brew cleanup" brew cleanup -s --prune=all
}

run_node() {
  local npm_root yarn_cache
  npm_root="$(cmd_home_path "$HOME/.npm" npm npm config get cache)"
  yarn_cache="$(cmd_home_path "$LCACHE/Yarn" yarn yarn cache dir)"
  sweep "npm _cacache" "$npm_root/_cacache"
  sweep "npm _npx"     "$npm_root/_npx"
  sweep "yarn cache" \
    "$yarn_cache" "$LCACHE/Yarn" "$HOME/.yarn/cache" \
    "$HOME/.yarn/berry/cache" "$HOME/.cache/yarn"
  sweep "pnpm cache" "$LCACHE/pnpm"
  sweep "pnpm store" \
    "$(cmd_home_path "$HOME/Library/pnpm/store" pnpm pnpm store path)" \
    "$HOME/Library/pnpm/store" "$HOME/.local/share/pnpm/store" "$HOME/.pnpm-store"
  sweep "bun cache"      "$HOME/.bun/install/cache" "$LCACHE/bun"
  sweep "node-gyp cache" "$LCACHE/node-gyp"
}

run_deno() {
  local d="$LCACHE/deno"
  [[ -n "${DENO_DIR:-}" ]] && is_safe_target "$DENO_DIR" && d="$DENO_DIR"
  sweep "deno cache" "$d" "$LCACHE/deno" "$HOME/.cache/deno"
}

run_python() {
  sweep "pip cache" "$LCACHE/pip" "$HOME/.cache/pip"
  sweep "uv cache" \
    "$(cmd_home_path "$HOME/.cache/uv" uv uv cache dir)" \
    "$HOME/.cache/uv" "$LCACHE/uv"
}

run_rust() {
  [[ -d "$HOME/.cargo" ]] || return 0
  sweep "cargo registry cache" "$HOME/.cargo/registry/cache"
  sweep "cargo registry src"   "$HOME/.cargo/registry/src"
  sweep "cargo git db"         "$HOME/.cargo/git/db"
  sweep "cargo git checkouts"  "$HOME/.cargo/git/checkouts"
}

run_go() {
  sweep "module cache" --note "re-downloads on next build" \
    "$(cmd_home_path "$HOME/go/pkg/mod" go go env GOMODCACHE)"
  sweep "build cache" \
    "$(cmd_home_path "$LCACHE/go-build" go go env GOCACHE)"
}

run_docker() {
  have docker || return 0
  host_tools_allowed || return 0
  if ! docker info >/dev/null 2>&1; then
    row "Docker" 0 "daemon not running"
    return 0
  fi
  # Named volumes are the data; -af does not include --volumes.
  sweep_cmd "docker system prune" docker system prune -af
}

run_report() {
  note "iOS device backups"   "$HOME/Library/Application Support/MobileSync/Backup"
  note "Downloads"            "$HOME/Downloads"
  note "Mail downloads"       "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
  note "Messages attachments" "$HOME/Library/Messages/Attachments"
  note "Playwright browsers"  "$LCACHE/ms-playwright"
  local snaps
  snaps="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)"
  if [[ "${snaps:-0}" -gt 0 ]]; then
    row "Time Machine local snapshots" 0 "$snaps found — 'tmutil deletelocalsnapshots <date>'"
  fi
}

run_large() {
  local kb path
  while read -r kb path; do
    [[ -n "${path:-}" ]] || continue
    row "$(basename "$path")" "$kb" "$path"
  done < <(
    shopt -s nullglob
    set -- "$HOME"/* "$HOME"/.[!.]*
    (( $# )) || exit 0
    du -sk "$@" 2>/dev/null | sort -rn | { head -20 || true; }
  )
}

# ---------------------------------------------------------------- cli

list_categories() {
  local entry
  printf '%sCategories%s\n' "$C_BOLD" "$C_RESET"
  for entry in "${CATEGORIES[@]}"; do
    printf '  %-14s %s\n' "${entry%%|*}" "${entry##*|}"
  done
}

usage() {
  cat <<EOF
macsweep $VERSION — reclaim disk space on macOS

USAGE
  $SELF                     dry-run every category
  $SELF --apply             delete (prompts unless -y)
  $SELF xcode brew          dry-run some categories
  $SELF --apply xcode brew  delete those
  $SELF --skip docker,go    everything except these

OPTIONS
  -a, --apply       Delete. Without this, nothing is removed.
  -y, --yes         Skip the --apply confirmation prompt.
  --only a,b,c      Same as passing a b c as arguments.
  --skip a,b,c      Run everything except these.
  --large           Also list the 20 largest items in \$HOME.
  -l, --list        List categories and exit.
  -V, --version     Print the version and exit.
  -h, --help        This.

NOTES
  Grant the terminal Full Disk Access (System Settings > Privacy & Security)
  or Mail / Messages / some Containers will read as 0.
EOF
}

need_arg() {
  [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || { err "option $1 requires a value"; exit 2; }
}

# Collapse "xcode, brew" / "xcode brew" / repeats into xcode,brew.
normalize_csv() {
  local in="$1" out="" name
  local IFS=', '
  for name in $in; do
    [[ -n "$name" ]] || continue
    out="${out:+$out,}$name"
  done
  printf '%s' "$out"
}

append_only() { ONLY="${ONLY:+$ONLY,}$1"; }

while (( $# )); do
  case "$1" in
    -a|--apply)    APPLY=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --only)        need_arg "$1" "${2:-}"; append_only "$2"; shift ;;
    --skip)        need_arg "$1" "${2:-}"; SKIP="${SKIP:+$SKIP,}$2"; shift ;;
    --large)       LARGE=1 ;;
    -l|--list)     LIST=1 ;;
    -V|--version)  printf 'macsweep %s\n' "$VERSION"; exit 0 ;;
    -h|--help)     usage; echo; list_categories; exit 0 ;;
    --)            shift
                   while (( $# )); do append_only "$1"; shift; done
                   break ;;
    -*)            err "unknown option: $1"; usage; exit 2 ;;
    *)             append_only "$1" ;;
  esac
  shift
done

ONLY="$(normalize_csv "$ONLY")"
SKIP="$(normalize_csv "$SKIP")"

is_category() {
  local want="$1" entry
  for entry in "${CATEGORIES[@]}"; do
    [[ "${entry%%|*}" == "$want" ]] && return 0
  done
  return 1
}

validate_names() {
  local flag="$1" list="$2" name
  [[ -n "$list" ]] || return 0
  local IFS=','
  for name in $list; do
    is_category "$name" || { err "$flag: unknown category '$name' (see --list)"; exit 2; }
  done
}
validate_names --only "$ONLY"
validate_names --skip "$SKIP"

if (( LIST )); then list_categories; exit 0; fi

[[ "$(uname -s)" == "Darwin" ]] || { err "macsweep is macOS-only."; exit 1; }
[[ "$(id -u)" == "0" ]] && { err "Do not run macsweep as root."; exit 1; }

if (( APPLY )) && ! (( ASSUME_YES )); then
  [[ -t 0 ]] || { err "--apply needs a tty to confirm; pass -y for unattended runs."; exit 2; }
  reply=""
  printf '%sThis will permanently delete caches and derived data. Continue? [y/N] %s' \
    "$C_YLW" "$C_RESET"
  read -r reply || reply=""
  [[ "$reply" == [yY]* ]] || { printf 'Aborted.\n'; exit 0; }
fi

df_free_kb() { df -k "$HOME" | awk 'NR==2{print $4}'; }
before_kb="$(df_free_kb)"

if (( APPLY )); then
  printf '%sMode: APPLY — deleting%s\n' "$C_RED$C_BOLD" "$C_RESET"
else
  printf '%sMode: DRY RUN — nothing will be deleted%s\n' "$C_GRN$C_BOLD" "$C_RESET"
fi

for entry in "${CATEGORIES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  header="${rest%%|*}"
  category_enabled "$name" || continue
  fn="run_${name//-/_}"
  declare -f "$fn" >/dev/null || { err "internal: missing $fn"; continue; }
  head2 "$header"
  "$fn"
done

if (( LARGE )); then
  head2 "Largest items in \$HOME (top 20)"
  run_large
fi

after_kb="$(df_free_kb)"

head2 "Summary"
row "Measured on disk" "$TOTAL_KB"
if (( APPLY )); then
  reclaimed=$(( after_kb - before_kb ))
  (( reclaimed < 0 )) && reclaimed=0
  row "Free space delta (df)" "$reclaimed"
  # APFS local snapshots pin deleted blocks; df can lag a large sweep.
  if (( reclaimed * 2 < TOTAL_KB )); then
    printf '  %sdf lags the deletes — usually APFS local snapshots still pinning the blocks.%s\n' \
      "$C_DIM" "$C_RESET"
  fi
fi
row "Free space now" "$after_kb"
(( REPORT_KB > 0 )) && row "Flagged for manual review" "$REPORT_KB"
printf '  %s(brew/docker/simctl free additional space not counted above)%s\n' "$C_DIM" "$C_RESET"

if ! (( APPLY )); then
  replay="$INVOKED --apply"
  [[ -n "$ONLY" ]] && replay="$replay ${ONLY//,/ }"
  [[ -n "$SKIP" ]] && replay="$replay --skip $SKIP"
  (( LARGE )) && replay="$replay --large"
  printf '  %sNothing deleted. To remove the items above: %s%s\n' "$C_DIM" "$replay" "$C_RESET"
fi

exit 0
