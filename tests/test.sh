#!/usr/bin/env bash
# Self-contained tests for macsweep. Uses a fake $HOME so --apply never
# touches the real machine. Delegated tools (brew/go/docker/simctl) are
# excluded from apply tests for the same reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$ROOT/macsweep.sh"
PASS=0
FAIL=0

assert() {
  local name="$1"; shift
  if "$@"; then
    printf '  ok  %s\n' "$name"
    PASS=$(( PASS + 1 ))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok  %s\n' "$name"
    PASS=$(( PASS + 1 ))
  else
    printf '  FAIL  %s\n    got:  %s\n    want: %s\n' "$name" "$got" "$want"
    FAIL=$(( FAIL + 1 ))
  fi
}

# ---------------------------------------------------------------- cli

printf '%s\n' "cli"
out="$("$SWEEP" --list)"
assert "lists user-caches" bash -c 'printf %s "$0" | grep -q user-caches' "$out"

code=0
"$SWEEP" --only >/dev/null 2>&1 || code=$?
assert_eq "--only without value exits 2" "$code" "2"

code=0
"$SWEEP" --only not-a-category >/dev/null 2>&1 || code=$?
assert_eq "unknown category exits 2" "$code" "2"

code=0
"$SWEEP" --only trash >/dev/null || code=$?
assert_eq "--only trash exits 0" "$code" "0"

# ---------------------------------------------------------------- fake HOME apply

printf '%s\n' "apply (fake HOME)"
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-test.XXXXXX")"
cleanup() { rm -rf "$FAKE"; }
trap cleanup EXIT

mkdir -p \
  "$FAKE/.Trash/old" \
  "$FAKE/Library/Caches/com.example.app/sub" \
  "$FAKE/Library/Caches/Yarn/v6" \
  "$FAKE/Library/Caches/pnpm/store" \
  "$FAKE/Library/Caches/pip/http" \
  "$FAKE/Library/Caches/go-build/aa" \
  "$FAKE/Library/Caches/Homebrew/downloads" \
  "$FAKE/Library/Logs/DiagnosticReports" \
  "$FAKE/Library/Caches/com.apple.HomeKit/keep" \
  "$FAKE/Documents" \
  "$FAKE/Downloads"
printf 'trash\n' > "$FAKE/.Trash/old/file"
printf 'cache\n' > "$FAKE/Library/Caches/com.example.app/sub/a"
printf 'yarn\n'  > "$FAKE/Library/Caches/Yarn/v6/pkg"
printf 'pnpm\n'  > "$FAKE/Library/Caches/pnpm/store/p"
printf 'pip\n'   > "$FAKE/Library/Caches/pip/http/w"
printf 'go\n'    > "$FAKE/Library/Caches/go-build/aa/o"
printf 'brew\n'  > "$FAKE/Library/Caches/Homebrew/downloads/t"
printf 'log\n'   > "$FAKE/Library/Logs/DiagnosticReports/crash.ips"
printf 'hk\n'    > "$FAKE/Library/Caches/com.apple.HomeKit/keep/x"
printf 'doc\n'   > "$FAKE/Documents/secret.txt"
printf 'dl\n'    > "$FAKE/Downloads/keep-me"
ln -s "$FAKE/Documents/secret.txt" "$FAKE/Library/Caches/evil-link"

# Dry-run must not delete.
HOME="$FAKE" "$SWEEP" --only trash,user-caches,logs,node,python,report >/dev/null
assert "dry-run leaves trash"     test -f "$FAKE/.Trash/old/file"
assert "dry-run leaves cache"     test -f "$FAKE/Library/Caches/com.example.app/sub/a"
assert "dry-run leaves downloads" test -f "$FAKE/Downloads/keep-me"

# Apply: only path-based categories, never brew/go/docker/simctl.
HOME="$FAKE" "$SWEEP" --apply -y \
  --only trash,user-caches,logs,node,python,report >/dev/null

assert "trash contents gone"          test ! -e "$FAKE/.Trash/old"
assert "trash dir remains"            test -d "$FAKE/.Trash"
assert "example cache contents gone"  test ! -e "$FAKE/Library/Caches/com.example.app/sub/a"
assert "example cache dir remains"    test -d "$FAKE/Library/Caches/com.example.app"
assert "logs emptied"                 test ! -e "$FAKE/Library/Logs/DiagnosticReports/crash.ips"
assert "logs dir remains"             test -d "$FAKE/Library/Logs"
assert "yarn swept via node"          test ! -e "$FAKE/Library/Caches/Yarn/v6/pkg"
assert "yarn dir remains"             test -d "$FAKE/Library/Caches/Yarn"
assert "pnpm swept via node"          test ! -e "$FAKE/Library/Caches/pnpm/store/p"
assert "pip swept via python"         test ! -e "$FAKE/Library/Caches/pip/http/w"
assert "HomeKit keep-list survives"   test -f "$FAKE/Library/Caches/com.apple.HomeKit/keep/x"
assert "Homebrew keep-list survives"  test -f "$FAKE/Library/Caches/Homebrew/downloads/t"
assert "go-build keep-list survives"  test -f "$FAKE/Library/Caches/go-build/aa/o"
assert "symlink not followed"         test -f "$FAKE/Documents/secret.txt"
assert "cache symlink removed"        test ! -e "$FAKE/Library/Caches/evil-link"
assert "report-only leaves Downloads" test -f "$FAKE/Downloads/keep-me"

# --skip node must not let user-caches eat the Yarn/pnpm trees.
mkdir -p "$FAKE/Library/Caches/Yarn/v6" "$FAKE/Library/Caches/pnpm/store"
printf 'yarn2\n' > "$FAKE/Library/Caches/Yarn/v6/pkg"
printf 'pnpm2\n' > "$FAKE/Library/Caches/pnpm/store/p"
HOME="$FAKE" "$SWEEP" --apply -y --only user-caches --skip node >/dev/null
assert "--skip node keeps Yarn" test -f "$FAKE/Library/Caches/Yarn/v6/pkg"
assert "--skip node keeps pnpm" test -f "$FAKE/Library/Caches/pnpm/store/p"

# Dry-run totals: Yarn must not be counted twice (user-caches + node).
# Rebuild a known-size Yarn cache and compare --only user-caches vs --only node.
printf '%s\n' "totals"
mkdir -p "$FAKE/Library/Caches/Yarn/v6"
# 100KB payload so du has something bigger than filesystem rounding.
dd if=/dev/zero of="$FAKE/Library/Caches/Yarn/v6/pkg" bs=1024 count=100 2>/dev/null
user_out="$(HOME="$FAKE" "$SWEEP" --only user-caches)"
node_out="$(HOME="$FAKE" "$SWEEP" --only node)"
both_out="$(HOME="$FAKE" "$SWEEP" --only user-caches,node)"
assert "user-caches does not list Yarn" bash -c '! printf %s "$0" | grep -q Yarn' "$user_out"
assert "node lists yarn cache"          bash -c 'printf %s "$0" | grep -q "yarn cache"' "$node_out"
assert "combined run does not double-count Yarn" bash -c '
  printf %s "$0" | grep -q "yarn cache" || exit 1
  printf %s "$1" | grep -q "yarn cache" && exit 1
  exit 0
' "$node_out" "$user_out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
