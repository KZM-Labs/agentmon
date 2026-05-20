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

## v0.2 scope (shipped)

- [x] Hook-driven push events — `HookServer` on `127.0.0.1:7842`, loopback-only with origin check, ~50ms perceived latency
- [x] `HookInstaller` wired to Preferences pane (Install / Uninstall buttons, `.bak` backup of `settings.json`)
- [x] Idle-session notifications via `UNUserNotificationCenter`, deduped per session, threshold configurable 5–120 min
- [x] Token & cost rollups — parses `usage` blocks, displays per-session and total in footer
- [x] Preferences pane — `UserDefaults`-backed, idle threshold slider, notifications toggle, cost-display toggle

### Security model

The hook server binds to all interfaces because `NWListener` doesn't expose a bind-address parameter. We compensate with a **per-connection origin check** in `HookServer.handle()` — non-loopback peers are rejected before any data is read. Payloads are validated as JSON and only `hook_event_name` / `session_id` / `transcript_path` / `cwd` / `message` are extracted — no commands are executed, no files are read based on payload contents beyond the existing `~/.claude/projects/` scan.

## v0.3 scope (shipped)

- [x] State persistence — `~/Library/Application Support/Agentmon/state.json` written on rescan, restored on startup
- [x] Per-project filtering toggles — UserDefaults-backed mute set; filters menu, recent list, and notifications

## v0.4 scope (shipped)

- [x] **"Waiting on you" state** — when the assistant has finished and the last typed turn is theirs, the session flips to blue. Floats to the top of ACTIVE. Status bar icon turns blue if any session is waiting.
- [x] **"Forget projects idle >7d"** — one-click in Preferences to drop stale sessions and clean up the mute list.

## State machine

| State | Color | Meaning |
|---|---|---|
| `active` | green | recent activity, assistant is working |
| `waiting` | blue | assistant finished; you need to type next |
| `idle` | yellow | 30s–5min with no clear waiting signal |
| `stale` | gray | >5min, listed under RECENT for 24h |

Status bar icon priority: `waiting` > `active` > `idle`. The blue dot is the "you have work to do" signal.

## v0.5+ roadmap

- [ ] Show current tool name (parse `tool_use` block from last assistant message)
- [ ] Cross-project daily budget alert ("$20 spent today across all sessions")
- [ ] Astro companion dashboard for big-screen view (same data source over `:7842`)
- [ ] Spotlight integration for session search
- [ ] Activity sparkline per session
- [ ] Detect "stuck on tool" — assistant called a tool that's never returned

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
