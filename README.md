# macsweep

A single bash script that reclaims disk space on macOS. Dry-run by default.

```sh
./macsweep.sh                     # what could be freed
./macsweep.sh xcode brew          # just those categories
./macsweep.sh --apply             # delete (prompts)
./macsweep.sh --apply -y xcode    # delete those, no prompt
./macsweep.sh --large             # also list the 20 biggest things in $HOME
./macsweep.sh --list              # categories
./tests/test.sh                   # fake-$HOME regression tests
```

Put it on your `PATH` if you want `macsweep` instead of `./macsweep.sh`:

```sh
ln -sf "$(pwd)/macsweep.sh" /usr/local/bin/macsweep
```

## What it cleans

| Category | What it removes |
|---|---|
| `trash` | `~/.Trash` |
| `user-caches` | `~/Library/Caches/*`, minus a keep-list |
| `logs` | `~/Library/Logs` (includes DiagnosticReports) |
| `xcode` | DerivedData, *DeviceSupport, Device Logs, Xcode caches, Previews, docs cache |
| `simulators` | `simctl delete unavailable`, CoreSimulator caches |
| `swiftpm` | SwiftPM package cache |
| `cocoapods` | CocoaPods + Carthage caches |
| `brew` | download cache; `brew cleanup -s --prune=all` when brew is available |
| `node` | npm `_cacache` + `_npx`, Yarn (incl. Berry), pnpm cache + store, bun, node-gyp |
| `deno` | Deno module cache |
| `python` | pip + uv caches |
| `rust` | cargo registry + git caches |
| `go` | module cache + `GOCACHE` |
| `docker` | `docker system prune -af` (named volumes are **not** touched) |
| `report` | measures only: iOS backups, Downloads, Mail/Messages, Playwright, TM snapshots |

## What it deliberately does not do

- **Xcode Archives** — reported, never deleted. They hold dSYMs for shipped-app crashes.
- **Docker named volumes** — that is where data lives.
- **App uninstall / leftover hunting** — guessing by bundle ID deletes the wrong things.
- **Universal-binary stripping** — breaks code signatures on modern macOS.
- **Anything requiring `sudo`.** The script refuses to run as root.

## Safety

- Dry-run unless `--apply`. `--apply` prompts unless `-y`.
- Deletes only under `$HOME`, never `$HOME` itself or a bare `Library`/`Documents`/`Desktop`.
- Empties directories; leaves the directories. Unlinks symlinks, never follows them.
- Tool-reported paths (`go env`, `brew --cache`, …) are used only when they resolve under `$HOME`. A redirected `$HOME` never drives brew/docker/simctl against the login home.
- Leftovers are still path-swept when the matching tool is uninstalled.
- macOS-only, never as root.

## Full Disk Access

Mail, Messages, and some Containers are TCC-gated. Without Full Disk Access they exist but `du` as 0, which looks like “not there”. The script labels those rows `unreadable — grant Full Disk Access`. Grant it under **System Settings → Privacy & Security → Full Disk Access**.

## Cron

```sh
0 9 * * 1  macsweep --apply -y >> /tmp/macsweep.log 2>&1
```
