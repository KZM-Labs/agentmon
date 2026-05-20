# Agentmon

Live menu bar view of Claude Code activity — what's running, where, and how recently.

Built by Mastascusa Holdings LLC. Brand-neutral; foldable into Cedrum if it ships as a product.

## What it does

Watches `~/.claude/projects/*/*.jsonl` and shows every active Claude Code session in your menu bar.

- **Green dot** — session activity in the last 30 seconds
- **Yellow dot** — idle (30s–5min)
- **Gray dot** — stale (>5min, shown under "Recent" for 24h)
- Click any session → opens Terminal with `claude --resume <id>` in the right directory

## Quick start

```bash
cd ~/Projects/agentmon
./build.sh --run
```

This builds a release `.app` bundle at `build/Agentmon.app` and launches it. Look in your menu bar for the circle icon.

To rebuild without launching: `./build.sh`. Debug build: `./build.sh --debug`.

## How it works

```
~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl
        │
        │  appended to by the Claude Code harness
        ▼
SessionStore (polls every 2s, tracks per-file offset)
        │
        ▼
@Published sessions → SwiftUI MenuView in NSPopover
```

- **Polling cadence:** every 2 seconds. Each project dir's most recent JSONL is checked; only new bytes since the last offset are read. CPU cost is negligible — a 6 MB session file adds maybe 30 KB per active second.
- **Stale filter:** files not touched in 24h are skipped during scan.
- **Resume path:** uses AppleScript to launch Terminal with `cd <cwd> && claude --resume <id>`.

## Architecture

| File | Role |
|---|---|
| `Sources/Agentmon/main.swift` | Entry point — sets activation policy to accessory |
| `Sources/Agentmon/AppDelegate.swift` | NSStatusItem + popover wiring, 1s tick for relative times |
| `Sources/Agentmon/SessionStore.swift` | Polls JSONLs, parses appended lines, publishes sessions |
| `Sources/Agentmon/Models.swift` | `Session`, `JSONLine`, state machine (active/idle/stale) |
| `Sources/Agentmon/MenuView.swift` | SwiftUI dropdown — active section, recent section, footer |
| `Sources/Agentmon/HookInstaller.swift` | Scaffolding for v0.2 hook-driven push events |
| `Resources/Info.plist` | `LSUIElement=true` makes it a menu bar accessory |
| `build.sh` | `swift build` → assemble `.app` bundle → ad-hoc codesign |

## v0.1 scope (shipped)

- [x] Menu bar icon with active count
- [x] Sectioned dropdown: ACTIVE / RECENT
- [x] Per-session metadata: model, cwd, git branch, last activity
- [x] Click to resume in Terminal
- [x] Self-contained `.app` bundle, ad-hoc signed

## v0.2+ roadmap

- [ ] Hook-driven push events (replace 2s poll for near-instant updates) — `HookInstaller.swift` is the entry point
- [ ] Notifications on long-idle sessions ("session idle 30 min — kill?")
- [ ] Token/cost rollups from `usage` blocks
- [ ] Per-project filtering toggles in Preferences
- [ ] Astro companion dashboard for big-screen view (same data source)
- [ ] Spotlight integration for session search
- [ ] Focus mode — auto-pause notifications for non-active projects

## Requirements

- macOS 13+
- Swift 6.0+ (Xcode 16+ Command Line Tools)
- Claude Code installed and writing to `~/.claude/projects/`

## Uninstall

```bash
pkill -x Agentmon
rm -rf ~/Projects/agentmon/build/Agentmon.app
```

If you installed hooks (v0.2+): `HookInstaller.uninstall()` removes them from `~/.claude/settings.json` and restores `.agentmon.bak`.
