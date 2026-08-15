# ClawBar

A macOS menu bar app showing your Claude subscription usage at a glance — the 5-hour
session window and the weekly limit, with reset countdowns and warnings as you approach
them.

No dock icon. Sits at about 14 MB and 0% CPU between polls.

```
🕐 7% · 28m
```

The glyph says which window (clock = session, calendar = weekly), the text says how much
is used and how long until it resets. A global shortcut — ⌃⌥⌘U by default — cycles
session → weekly → both without touching the mouse.

---

## Requirements

- macOS 14 or later
- A Claude Pro or Max subscription
- Claude Code installed, to mint a token (`claude setup-token`)

## Install

Download the latest DMG from [Releases](https://github.com/vmlrodrigues/ClawBar/releases),
drag ClawBar to Applications, and launch it. It is signed with a Developer ID and
notarised by Apple, so Gatekeeper will not complain.

On first run it asks for a token. In a terminal:

```bash
claude setup-token
```

Paste the result into the window. It is stored in your login Keychain and sent only to
`api.anthropic.com`.

## How it works, and why that matters

There is no public API for subscription usage. Every documented usage endpoint — Admin
Usage & Cost, Claude Code Analytics, Enterprise Analytics — is gated behind a Console
organisation, which individual Pro and Max accounts do not have.

ClawBar instead makes one minimal inference request to `/v1/messages` and reads the
`anthropic-ratelimit-unified-*` **response headers**, which carry your session and weekly
utilisation. The message body is discarded; the headers are the payload.

Two consequences worth understanding before you rely on this:

**These headers are undocumented.** They are not in Anthropic's published response-header
table. They can change shape or disappear without notice, and if they do, ClawBar breaks.
[VERIFICATION.md](VERIFICATION.md) records exactly what was observed, when, and how it was
checked, so a future failure can be diagnosed rather than guessed at.

**The number can read one point below Claude's own panel.** The header carries only two
decimal places, and the server floors to them — `0.28` means anywhere in 28.00–28.99%.
Claude's Usage panel has the full-precision figure and rounds it, so it can legitimately
show 29% for the same instant. No arithmetic here can recover the missing precision, so
ClawBar shows what it was given.

**Polling costs a request.** It is tiny — 8 input and 1 output token on Haiku, which did
not move reported utilisation at all across 110 logged samples — but it is a real
inference call, and it appears to anchor a 5-hour session window. So ClawBar polls on
evidence that you are *already* using Claude Code (an FSEvents watch on `~/.claude`)
rather than on a fixed timer. Settings → Background refresh controls what happens once you
stop; set it to Off if you want your session window aligned strictly to your own first
request.

## Privacy

- Your token lives in the login Keychain, never on disk in plain text and never in logs.
- The only network destination is `api.anthropic.com`. There is no telemetry, no
  analytics, and no update ping other than Sparkle's appcast fetch from this repository.
- The optional usage log at
  `~/Library/Application Support/ClawBar/usage-log.jsonl` records only utilisation
  percentages and reset timestamps. No token, no prompts, no conversation content. Turn it
  off in Settings.

## Building from source

```bash
swift package resolve
./Scripts/build.sh            # SIGN=0 to skip code signing
```

The version comes from the `VERSION` file and changes only when a release is cut; the
build number is the git commit count, derived automatically. Sparkle compares the build
number, so it must always increase — deriving it removes the chance of a duplicate, which
would silently break updates for anyone already on that build. Settings shows both, e.g.
`ClawBar 0.4.2 (14)`, since two builds can share a version.

`Scripts/build.sh` assembles the `.app` bundle, embeds Sparkle, and signs everything. It
picks up the first Developer ID Application identity in your Keychain; override with
`IDENTITY=`.

Releasing additionally needs an App Store Connect API key — copy `.env.example` to `.env`
and fill it in — then:

```bash
./Scripts/notarize.sh         # notarise app + DMG, staple both
./Scripts/appcast.sh          # sign for Sparkle, update appcast.xml
```

The app icon is generated, not drawn by hand:

```bash
swift Scripts/make-icon.swift
iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns
```

[Scripts/icon-options.swift](Scripts/icon-options.swift) renders the alternatives that
were considered, if you want a different one.

## Design notes

[DESIGN.md](DESIGN.md) covers the architecture and the reasoning behind the less obvious
choices — why polling is gated on filesystem activity, why the status item is AppKit while
everything else is SwiftUI, and why the menu bar never labels a window with a
duration-shaped string.

## Not affiliated with Anthropic

ClawBar is an independent, unofficial tool. It is not made, endorsed, or supported by
Anthropic. "Claude" and "Anthropic" are trademarks of Anthropic PBC, used here only to
describe what the app does. It relies on undocumented behaviour and may stop working at
any time — use it accordingly.

## Licence

MIT — see [LICENSE](LICENSE).

Sparkle is used under the MIT licence, © Sparkle Project contributors.
