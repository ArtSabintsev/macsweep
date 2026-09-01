# macsweep

A single bash script that reclaims disk space on macOS. Dry-run by default.

```sh
curl -fsSL https://raw.githubusercontent.com/ArtSabintsev/macsweep/main/macsweep.sh -o macsweep
chmod +x macsweep
./macsweep                     # what could be freed
./macsweep --apply             # delete (prompts)
```

Or clone it:

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
| `state` | `~/Library/Saved Application State` |
| `browsers` | Chrome / Arc / Brave / Edge / Firefox / Safari *caches* (not cookies, history, or logins) |
| `xcode` | DerivedData, *DeviceSupport, Device Logs, Xcode caches, Previews, docs cache |
| `simulators` | `simctl delete unavailable`, CoreSimulator caches |
| `swiftpm` | SwiftPM package cache |
| `cocoapods` | CocoaPods + Carthage caches |
| `brew` | download cache; `brew cleanup -s --prune=all` when brew is available |
| `node` | npm `_cacache` + `_npx`, Yarn (incl. Berry), pnpm cache + store, bun, node-gyp |
| `deno` | Deno module cache |
| `python` | pip + uv + poetry caches |
| `rust` | cargo registry + git caches |
| `go` | module cache + `GOCACHE` |
| `gradle` | `~/.gradle/caches`, daemon logs, `~/.android/cache` |
| `maven` | `~/.m2/repository` |
| `docker` | `docker system prune -af` (named volumes are **not** touched) |
| `playwright` | downloaded Chromium / Firefox / WebKit binaries (`~/Library/Caches/ms-playwright`) |
| `vscode` | VS Code / Cursor / VSCodium / Windsurf caches (not `User/` settings or `extensions/`) |
| `jetbrains` | `~/Library/Caches/JetBrains` (not Application Support settings) |
| `ai` | Hugging Face, torch, whisper caches. Ollama models are listed, never deleted. |
| `snapshots` | `tmutil thinlocalsnapshots` — reclaims space APFS still pins after deletes |
| `dns` | `sudo dscacheutil -flushcache` + `sudo killall -HUP mDNSResponder` (sudo on `--apply` only) |
| `backups` | iOS device backups + software updates — **listed, never deleted** |
| `installers` | `*.dmg` / `*.pkg` / `*.iso` in Downloads and Desktop — **listed, never deleted** |

## What it deliberately does not do

- **Xcode Archives** — shown as kept, never deleted. They hold dSYMs for shipped-app crashes.
- **Docker named volumes** — that is where data lives.
- **Mail, Messages, Downloads contents** — user data, not caches. DMGs in Downloads/Desktop are listed under `installers` and left alone.
- **iOS backups** — listed under `backups`, never deleted.
- **Ollama / local LLM model files** — listed under `ai`, never deleted.
- **Browser profiles** — cookies, history, logins, Local Storage stay. Only cache directories go.
- **App uninstall / leftover hunting** — guessing by bundle ID deletes the wrong things.
- **Universal-binary stripping** — breaks code signatures on modern macOS.
- **Running as root.** The script refuses. `dns --apply` is the only path that *invokes* sudo, and only for the two flush commands.

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
