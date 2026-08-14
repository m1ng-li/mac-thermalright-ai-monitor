# MacTR — AI Agent & System Monitor for Thermalright LCD

[中文](README.md) · [English](README.en.md)

Turn the 1920×480 LCD on your Thermalright CPU cooler into a live dashboard that shows
your Mac's vitals **and what your AI coding agents are doing right now** — all native on
macOS, no Windows required.

![On real hardware](img/photo.jpg)

<sub>Running on a Thermalright Trofeo Vision 9.16 cooler.</sub>

![Dashboard](img/dashboard.gif)

<sub>Live demo (fake data). Both agents "working" → columns breathe, Bongo Cat types,
Pikachu hops and crackles with CPU load, clock ticks.</sub>

> Fork of [beret21/MacTR](https://github.com/beret21/MacTR), reworked around a central
> **AI Agents** panel that tracks [Claude Code](https://claude.com/claude-code),
> [Codex](https://openai.com/codex) and [Cursor](https://cursor.com) sessions in real time.
> Either column can be remapped in Settings.

## Highlights

### 🤖 AI Agents panel
Reads your **local** Claude Code / Codex / Cursor session logs (read-only, no network).
Defaults to Cursor on the left and Codex on the right; remap either column to Claude,
Codex or Cursor from the menu bar or **Settings → Agents**:

- **Current project** and the **last thing it said** — Markdown tables in the message are
  rendered as real aligned tables, not raw `| … |` text.
- **Plan / step progress** — `步骤 4/6` badge + a segmented progress bar, parsed from
  Codex `update_plan` and Claude / Cursor `TodoWrite`. Stale plans from a finished turn disappear.
- **Today's token usage** — total + In/Out, in a compact `万 / 亿` format (Cursor's local
  logs don't include usage, so that column shows "—").
- **Codex remaining quota** — % left + reset countdown, tracked across all recent sessions.
- **Live status** — the column **breathes** while an agent is working and **flashes** for
  ~10 s when it finishes a turn or needs your input.

### 🖥️ System panels
- **CPU** — usage arc gauge, per-core P/E bars, temperature (via IOHIDEventSystemClient,
  no sudo), load average.
- **Memory** — pressure-colored usage gauge, Active/Wired/Compressed/Available breakdown,
  a full-width clock, date, uptime and process count.

### 🐱⚡ Desk pets that react to activity
- A **Bongo Cat** taps its keyboard while your agents work (and dozes when idle).
- A **Pikachu** whose electricity crackles harder as CPU load rises, and who hops and
  turns while an agent is running.

### ⚙️ Under the hood
- **Adaptive frame rate** — the LCD runs at ~15 fps only while something is animating
  (agent working, heavy CPU); otherwise it idles at 2 fps to save power.
- **USB hotplug** — auto-reconnect on plug/unplug and sleep/wake.
- **On-Mac preview** — when no LCD is connected it renders to a window instead, so you can
  develop and see changes without the hardware.
- **Menu bar app** — runs in the background, no dock icon.

## Hardware

| | |
|---|---|
| **Product** | [Thermalright Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **Display** | 9.16" IPS, 1920 × 480 |
| **Connection** | USB Type-C (USB 2.0) |
| **Device** | `0416:5408` (LY Bulk protocol) |

## Requirements

- Apple Silicon Mac (M1–M5)
- macOS 15 (Sequoia) or newer

That's the whole list if you install the release build — libusb ships inside the app,
so Homebrew is not needed. `libusb` and a Swift 6.1+ toolchain are only required to
build from source.

## Install

Grab the `.dmg` from
[Releases](https://github.com/m1ng-li/mac-thermalright-ai-monitor/releases),
open it and drag **MacTR AI** into Applications.

> **Gatekeeper will block the first launch.** The app is ad-hoc signed only — there is
> no $99/year Apple Developer certificate behind it — so macOS reports an unverified
> developer. In Applications, **right-click the icon → Open**, then click Open again in
> the dialog. Once is enough.
>
> The command-line equivalent:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/MacTR AI.app"
> ```

Once installed, open Settings from the menu bar icon to enable launch at login.

## Build from source

```bash
brew install libusb pkg-config

git clone https://github.com/m1ng-li/mac-thermalright-ai-monitor.git
cd mac-thermalright-ai-monitor
swift build -c release

.build/release/MacTR          # menu-bar app; drives the LCD, or previews in a window
```

> If your Command Line Tools are broken and `swift build` fails on the package manifest,
> install the Homebrew Swift toolchain (`brew install swift`) and use
> `/opt/homebrew/opt/swift/bin/swift build -c release`, or pass
> `SWIFT=/opt/homebrew/opt/swift/bin/swift` to the packaging scripts below.

### Packaging it yourself

```bash
./packaging/build-app.sh      # → dist/MacTR AI.app (bundles libusb, ad-hoc signed)
./packaging/make-dmg.sh       # → dist/MacTR-AI-<version>-arm64.dmg
```

`build-app.sh` copies every non-system dylib the binary references into
`Contents/Frameworks`, rewrites the install names, and then asserts that no
build-machine paths survived into the bundle.

The git tag is the source of truth for the version: pushing a `v*` tag triggers the
[release workflow](.github/workflows/release.yml), which builds on CI and uploads the
DMG to a GitHub Release.

### Auto-start on login

Use the toggle in the app's Settings (backed by `SMAppService`).

If you also want the app relaunched after a crash, use the LaunchAgent instead:

```bash
cp packaging/com.m1ngli.MacTRAI.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.m1ngli.MacTRAI.plist
```

Pick one or the other — enabling both starts two instances that fight over the USB device.

## Modes

```bash
.build/release/MacTR                 # menu-bar app (LCD, or preview window if no LCD)
.build/release/MacTR --preview       # force the on-Mac preview window
.build/release/MacTR --demo          # drive the LCD with polished fake data (for photos)
.build/release/MacTR --snapshot x.png --cores 10   # render one demo frame to a PNG
.build/release/MacTR --gif x.gif --frames 48 --fps 12 --scale 2   # animated demo GIF
.build/release/MacTR --benchmark 120 # measure achievable LCD frame rate
```

For an installed copy the same entry point is
`/Applications/MacTR AI.app/Contents/MacOS/MacTR`.

Only one process can hold the USB device at a time — stop the running instance before
using `--demo` / `--benchmark`.

## How agent data is read

MacTR never talks to any network or API. It only reads local session transcripts that the
CLIs already write to disk:

| Agent | Source | What's parsed |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | assistant messages, `usage` tokens, `TodoWrite` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent messages, `token_count`, `rate_limits`, `update_plan` |
| Cursor | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` | assistant messages, `turn_ended`, `TodoWrite` (no token usage) |

Token totals are scoped to the local day; the panel gracefully shows the last session's
context when an agent hasn't run yet today.

## Privacy

Everything is local and read-only. No telemetry, no network calls, nothing leaves your Mac.

## Credits

- [beret21/MacTR](https://github.com/beret21/MacTR) — the original macOS driver this is built on
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) — LY Bulk protocol reverse engineering
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) — IOHIDEventSystemClient temperature reading
- [kuroni/bongocat-osu](https://github.com/kuroni/bongocat-osu) — Bongo Cat sprite
- Pikachu artwork via [PokeAPI/sprites](https://github.com/PokeAPI/sprites) — Pokémon is © Nintendo / Creatures / GAME FREAK; included here as a cosmetic homage only

> The Bongo Cat and Pikachu are purely decorative. If you redistribute builds, note that
> their artwork belongs to the respective owners — swap or remove the embedded
> `BongoCatAsset.swift` / `PikachuAsset.swift` if that matters for your use.

## License

MIT (inherited from the upstream project). Third-party assets remain under their own terms.

---

Built with Swift + libusb. Developed with [Claude Code](https://claude.com/claude-code).
