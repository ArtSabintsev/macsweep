# macsweep

A single bash script that reclaims disk space on macOS. Dry-run by default.

```sh
./macsweep.sh                    # report what could be freed
./macsweep.sh --apply            # free it
./macsweep.sh --only xcode,brew --apply
./macsweep.sh --large            # also list the 20 biggest things in $HOME
./macsweep.sh --list             # show categories
```

## What it cleans

| Category | What it removes |
|---|---|
| `trash` | `~/.Trash` |
| `user-caches` | `~/Library/Caches/*`, minus a small keep-list |
| `logs` | `~/Library/Logs`, `DiagnosticReports` |
| `xcode` | DerivedData, iOS/watchOS/tvOS DeviceSupport, Xcode caches, Previews |
| `simulators` | `simctl delete unavailable`, CoreSimulator caches |
| `swiftpm` | SwiftPM package cache |
| `cocoapods` | CocoaPods + Carthage caches |
| `brew` | `brew cleanup -s --prune=all` and the download cache |
| `node` | npm `_cacache`, Yarn cache, `pnpm store prune` |
| `python` | pip and uv caches |
| `rust` | cargo registry cache + src |
| `go` | `go clean -modcache` |
| `docker` | `docker system prune -af` (named volumes are **not** touched) |
| `report` | measures but never deletes: iOS backups, Downloads, Mail/Messages attachments, Time Machine local snapshots |

## What it deliberately does not do

- **Xcode Archives** are reported, never deleted. They hold the dSYMs you need
  to symbolicate crash reports from shipped builds.
- **Docker named volumes** are excluded from the prune. That is where data lives.
- **App uninstall + leftover hunting.** Correctly mapping an app bundle to its
  containers, prefs, launch agents, and privileged helpers needs a per-app
  database. Guessing by bundle ID deletes the wrong things.
- **Language file / universal binary stripping.** It breaks code signatures on
  modern macOS. Cleaner apps abandoned this years ago.
- **Anything requiring `sudo`.** The script refuses to run as root.

## Safety model

- Dry run unless `--apply`, and `--apply` prompts unless `-y`.
- Every deletion path is checked by `is_safe_target`: it must live under
  `$HOME`, must not be `$HOME` itself or a bare `Library`/`Documents`/`Desktop`,
  and must not contain `..`.
- Directory *contents* are removed, not the directories, so apps that assume
  their cache dir exists keep working.
- Refuses to run as root, and refuses to run off macOS.

## Full Disk Access

Some paths (Mail, Messages, Safari) are gated by TCC. Without Full Disk Access
granted to your terminal these exist but cannot be read, so they measure as 0 —
which is indistinguishable from "not there". The script detects this case and
labels the row `unreadable — grant Full Disk Access` rather than omitting it.
Grant access under **System Settings → Privacy & Security → Full Disk Access**.

## Optional: run it on a schedule

```sh
# ~/Library/LaunchAgents/com.user.macsweep.plist runs it weekly; or simply:
0 9 * * 1 /Users/you/Developer/macsweep/macsweep.sh --apply -y >> /tmp/macsweep.log 2>&1
```
