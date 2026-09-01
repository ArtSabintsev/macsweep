#!/usr/bin/env bash
# Fake-$HOME tests. Delegated host tools (brew/go/docker/simctl) are skipped
# automatically when HOME is not the login home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWEEP="$ROOT/macsweep.sh"
PASS=0
FAIL=0

ok()   { printf '  ok  %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$(( FAIL + 1 )); }

assert() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$name"
  else printf '  FAIL  %s\n    got:  %s\n    want: %s\n' "$name" "$got" "$want"; FAIL=$(( FAIL + 1 )); fi
}

assert_has()    { local n="$1" hay="$2" needle="$3"; printf '%s' "$hay" | grep -q -e "$needle" && ok "$n" || fail "$n"; }
assert_not_has(){ local n="$1" hay="$2" needle="$3"; printf '%s' "$hay" | grep -q -e "$needle" && fail "$n" || ok "$n"; }

code_of() { local c=0; "$@" >/dev/null 2>&1 || c=$?; printf '%s' "$c"; }

runf() { HOME="$FAKE" "$SWEEP" "$@"; }

# ---------------------------------------------------------------- cli

printf '%s\n' "cli"
out="$("$SWEEP" --list)"
assert_has "lists user-caches" "$out" user-caches
assert_has "lists deno"        "$out" deno
assert_has "lists playwright"  "$out" playwright
assert_has "lists browsers"    "$out" browsers
assert_has "lists vscode"      "$out" vscode
assert_has "lists jetbrains"   "$out" jetbrains
assert_has "lists gradle"      "$out" gradle
assert_has "lists maven"       "$out" maven
assert_has "lists ai"          "$out" ai
assert_has "lists snapshots"   "$out" snapshots
assert_has "lists dns"         "$out" dns
assert_has "lists backups"     "$out" backups
assert_has "lists installers"  "$out" installers
assert_has "lists state"       "$out" state
assert_not_has "does not list report" "$out" report

help="$("$SWEEP" --help)"
assert_has "help lists categories" "$help" user-caches
assert_has "help shows apply replay shape" "$help" --apply

ver="$("$SWEEP" --version)"
assert_has "version flag" "$ver" '^macsweep '
assert_eq "-V matches --version" "$("$SWEEP" -V)" "$ver"

assert_eq "--only without value exits 2" "$(code_of "$SWEEP" --only)" "2"
assert_eq "unknown category exits 2" "$(code_of "$SWEEP" --only not-a-category)" "2"
assert_eq "--only trash exits 0" "$(code_of "$SWEEP" --only trash)" "0"
assert_eq "positional trash exits 0" "$(code_of "$SWEEP" trash)" "0"
assert_eq "spaced csv is accepted" "$(code_of "$SWEEP" --only 'trash, logs')" "0"
assert_eq "-l lists" "$(code_of "$SWEEP" -l)" "0"

# ---------------------------------------------------------------- fake HOME

printf '%s\n' "apply (fake HOME)"
FAKE="$(mktemp -d "${TMPDIR:-/tmp}/macsweep-test.XXXXXX")"
trap 'rm -rf "$FAKE"' EXIT

seed() {
  local rel="$1" body="${2:-x}"
  mkdir -p "$FAKE/$(dirname "$rel")"
  printf '%s\n' "$body" > "$FAKE/$rel"
}

mkdir -p "$FAKE/Documents" "$FAKE/Downloads"
seed ".Trash/old/file" trash
seed "Library/Caches/com.example.app/sub/a" cache
seed "Library/Caches/Yarn/v6/pkg" yarn
seed "Library/Caches/pnpm/store/p" pnpm
seed "Library/pnpm/store/v10/h" store
seed "Library/Caches/pip/http/w" pip
seed ".cache/pip/http/w" pip2
seed "Library/Caches/go-build/aa/o" go
seed "go/pkg/mod/example.com/m" mod
seed "Library/Caches/Homebrew/downloads/t" brew
seed "Library/Caches/deno/remote/m" deno
seed "Library/Caches/ms-playwright/chromium/b" pw
seed "Library/Logs/DiagnosticReports/crash.ips" log
seed "Library/Caches/com.apple.HomeKit/keep/x" hk
seed "Library/Developer/Xcode/DerivedData/proj/o" dd
seed "Library/Developer/Xcode/visionOS DeviceSupport/X/s" vos
seed "Library/Developer/Xcode/iOS Device Logs/Y/l" idl
seed "Library/Developer/CoreSimulator/Caches/dyld/c" sim
seed ".npm/_cacache/content/x" npm
seed ".npm/_npx/pkg/x" npx
seed ".yarn/berry/cache/y" berry
seed ".cargo/registry/cache/c/r" crate
seed ".cargo/git/db/g/d" git
printf 'doc\n' > "$FAKE/Documents/secret.txt"
printf 'dl\n'  > "$FAKE/Downloads/keep-me"
ln -s "$FAKE/Documents/secret.txt" "$FAKE/Library/Caches/evil-link"

runf trash user-caches logs node python playwright >/dev/null
assert "dry-run leaves trash"     test -f "$FAKE/.Trash/old/file"
assert "dry-run leaves cache"     test -f "$FAKE/Library/Caches/com.example.app/sub/a"
assert "dry-run leaves downloads" test -f "$FAKE/Downloads/keep-me"
assert "dry-run leaves npx"       test -f "$FAKE/.npm/_npx/pkg/x"

host_out="$(runf brew go docker simulators dns snapshots)"
assert_not_has "redirected HOME skips brew cleanup" "$host_out" "would run: brew cleanup"
assert_not_has "redirected HOME skips simctl"       "$host_out" "simctl delete"
assert_not_has "redirected HOME skips DNS flush"    "$host_out" "dscacheutil"
assert_not_has "redirected HOME skips tmutil"       "$host_out" "tmutil"
assert_has "dry-run prints replay line"             "$host_out" "Nothing deleted"

# -a -y is --apply --yes. Positionals instead of --only.
runf -a -y trash user-caches logs node python playwright >/dev/null

gone() { assert "$1" test ! -e "$FAKE/$2"; }
kept() { assert "$1" test -e "$FAKE/$2"; }

gone "trash contents gone"          .Trash/old
kept "trash dir remains"            .Trash
gone "example cache contents gone"  Library/Caches/com.example.app/sub/a
kept "example cache dir remains"    Library/Caches/com.example.app
gone "logs emptied"                 Library/Logs/DiagnosticReports/crash.ips
kept "logs dir remains"             Library/Logs
gone "yarn swept via node"          Library/Caches/Yarn/v6/pkg
kept "yarn dir remains"             Library/Caches/Yarn
gone "pnpm swept via node"          Library/Caches/pnpm/store/p
gone "pnpm store swept"             Library/pnpm/store/v10/h
gone "pip swept via python"         Library/Caches/pip/http/w
gone "pip ~/.cache swept"           .cache/pip/http/w
gone "npm _cacache swept"           .npm/_cacache/content/x
gone "npm _npx swept"               .npm/_npx/pkg/x
gone "yarn berry swept"             .yarn/berry/cache/y
kept "HomeKit keep-list survives"   Library/Caches/com.apple.HomeKit/keep/x
kept "Homebrew keep-list survives"  Library/Caches/Homebrew/downloads/t
kept "go-build keep-list survives"  Library/Caches/go-build/aa/o
kept "deno keep-list survives"      Library/Caches/deno/remote/m
gone "playwright browsers swept"    Library/Caches/ms-playwright/chromium/b
kept "playwright dir remains"       Library/Caches/ms-playwright
assert "symlink not followed"       test -f "$FAKE/Documents/secret.txt"
assert "cache symlink removed"      test ! -e "$FAKE/Library/Caches/evil-link"
kept "Downloads left alone"         Downloads/keep-me

runf --apply -y brew go deno xcode simulators rust >/dev/null
gone "brew leftovers swept without host brew"   Library/Caches/Homebrew/downloads/t
kept "brew dir remains"                         Library/Caches/Homebrew
gone "go-build leftovers swept without host go" Library/Caches/go-build/aa/o
gone "go module leftovers swept"                go/pkg/mod/example.com/m
gone "deno cache swept"                         Library/Caches/deno/remote/m
kept "deno dir remains"                         Library/Caches/deno
gone "DerivedData swept"                        Library/Developer/Xcode/DerivedData/proj/o
gone "visionOS DeviceSupport swept"             "Library/Developer/Xcode/visionOS DeviceSupport/X/s"
gone "iOS Device Logs swept"                    "Library/Developer/Xcode/iOS Device Logs/Y/l"
gone "CoreSimulator caches swept"               Library/Developer/CoreSimulator/Caches/dyld/c
gone "cargo registry swept"                     .cargo/registry/cache/c/r
gone "cargo git swept"                          .cargo/git/db/g/d

seed "Library/Caches/Yarn/v6/pkg" yarn2
seed "Library/Caches/pnpm/store/p" pnpm2
runf --apply -y --only user-caches --skip node >/dev/null
kept "--skip node keeps Yarn" Library/Caches/Yarn/v6/pkg
kept "--skip node keeps pnpm" Library/Caches/pnpm/store/p

seed "Library/Caches/deno/remote/m" deno2
runf --apply -y user-caches --skip deno >/dev/null
kept "--skip deno keeps deno cache" Library/Caches/deno/remote/m

seed "Library/Application Support/Google/Chrome/Default/Cache/f" chrome-cache
seed "Library/Application Support/Google/Chrome/Default/Cookies" chrome-cookies
seed "Library/Application Support/Google/Chrome/Default/History" chrome-history
seed "Library/Safari/Webpage Previews/p" safari-preview
seed "Library/Application Support/Firefox/Profiles/abcd.default/cache2/e" ff-cache
seed "Library/Application Support/Firefox/Profiles/abcd.default/places.sqlite" ff-places
seed "Library/Application Support/Code/Cache/c" vscode-cache
seed "Library/Application Support/Code/User/settings.json" vscode-settings
seed "Library/Application Support/Cursor/Cache/c" cursor-cache
seed "Library/Caches/JetBrains/IntelliJIdea2024.1/caches/x" jb-cache
seed "Library/Application Support/JetBrains/IntelliJIdea2024.1/options/foo.xml" jb-settings
seed ".gradle/caches/modules-2/files/x" gradle-cache
seed ".gradle/gradle.properties" gradle-props
seed ".m2/repository/com/example/a.jar" maven-jar
seed ".m2/settings.xml" maven-settings
seed ".cache/huggingface/hub/m" hf
seed ".cache/torch/hub/t" torch
seed ".ollama/models/blobs/b" ollama
seed "Library/Saved Application State/com.example.savedState/windows.plist" saved-state
seed "Library/Application Support/MobileSync/Backup/uuid/Info.plist" ios-backup
seed "Library/Caches/pypoetry/art/p" poetry
printf 'iso\n' > "$FAKE/Downloads/Installer.dmg"
mkdir -p "$FAKE/Desktop"
printf 'pkg\n' > "$FAKE/Desktop/App.pkg"

runf --apply -y browsers vscode jetbrains gradle maven ai state python backups installers >/dev/null

gone "chrome cache swept"           "Library/Application Support/Google/Chrome/Default/Cache/f"
kept "chrome cookies kept"          "Library/Application Support/Google/Chrome/Default/Cookies"
kept "chrome history kept"          "Library/Application Support/Google/Chrome/Default/History"
gone "safari previews swept"        "Library/Safari/Webpage Previews/p"
gone "firefox cache2 swept"         "Library/Application Support/Firefox/Profiles/abcd.default/cache2/e"
kept "firefox places kept"          "Library/Application Support/Firefox/Profiles/abcd.default/places.sqlite"
gone "vscode cache swept"           "Library/Application Support/Code/Cache/c"
kept "vscode settings kept"         "Library/Application Support/Code/User/settings.json"
gone "cursor cache swept"           "Library/Application Support/Cursor/Cache/c"
gone "jetbrains caches swept"       "Library/Caches/JetBrains/IntelliJIdea2024.1/caches/x"
kept "jetbrains settings kept"      "Library/Application Support/JetBrains/IntelliJIdea2024.1/options/foo.xml"
gone "gradle caches swept"          ".gradle/caches/modules-2/files/x"
kept "gradle.properties kept"       ".gradle/gradle.properties"
gone "maven repo swept"             ".m2/repository/com/example/a.jar"
kept "maven settings kept"          ".m2/settings.xml"
gone "huggingface cache swept"      ".cache/huggingface/hub/m"
gone "torch cache swept"            ".cache/torch/hub/t"
kept "ollama models kept"           ".ollama/models/blobs/b"
gone "saved state swept"            "Library/Saved Application State/com.example.savedState/windows.plist"
kept "iOS backup kept"              "Library/Application Support/MobileSync/Backup/uuid/Info.plist"
gone "poetry cache swept via python" "Library/Caches/pypoetry/art/p"
kept "Downloads dmg kept"           "Downloads/Installer.dmg"
kept "Desktop pkg kept"             "Desktop/App.pkg"

seed "Library/Caches/JetBrains/IntelliJIdea2024.1/caches/x" jb2
seed "Library/Caches/pypoetry/art/p" poetry2
runf --apply -y --only user-caches >/dev/null
kept "user-caches leaves JetBrains" Library/Caches/JetBrains/IntelliJIdea2024.1/caches/x
kept "user-caches leaves pypoetry"  Library/Caches/pypoetry/art/p
jb_out="$(runf jetbrains)"
assert_has "jetbrains lists caches" "$jb_out" "JetBrains caches"
py_out="$(runf python)"
assert_has "python lists poetry cache" "$py_out" "poetry cache"
runf --apply -y jetbrains python >/dev/null
gone "jetbrains category sweeps JetBrains" Library/Caches/JetBrains/IntelliJIdea2024.1/caches/x
gone "python category sweeps pypoetry"    Library/Caches/pypoetry/art/p

backup_out="$(runf backups)"
assert_has "backups listed as kept" "$backup_out" "iOS backups"
assert_has "backups marked kept"    "$backup_out" "kept"
inst_out="$(runf installers)"
assert_has "installers listed as kept" "$inst_out" "Disk images"
assert_has "installers marked kept"    "$inst_out" "kept"

printf '%s\n' "totals"
mkdir -p "$FAKE/Library/Caches/Yarn/v6"
dd if=/dev/zero of="$FAKE/Library/Caches/Yarn/v6/pkg" bs=1024 count=100 2>/dev/null
user_out="$(runf --only user-caches)"
node_out="$(runf node)"
assert_not_has "user-caches does not list Yarn" "$user_out" Yarn
assert_has     "node lists yarn cache"          "$node_out" "yarn cache"
assert_not_has "user-caches does not list yarn cache" "$user_out" "yarn cache"

seed "Library/Caches/ms-playwright/chromium/b" pw2
pw_out="$(runf playwright)"
assert_has "playwright category names browsers" "$pw_out" Playwright

user_skip_pw="$(runf --only user-caches)"
assert_not_has "user-caches does not list playwright" "$user_skip_pw" "Playwright"

large_out="$(runf --large trash)"
assert_has "--large lists Documents" "$large_out" Documents
assert_has "replay keeps the original argv0" "$large_out" "$SWEEP --apply"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
