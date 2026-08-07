# ClawBar — Design

macOS menu bar app showing Claude subscription usage. Swift + SwiftUI, no dock icon,
minimal footprint.

Data source: **Route 2** — `POST api.anthropic.com/v1/messages`, reading the
`anthropic-ratelimit-unified-*` response headers. See VERIFICATION.md for the observed
header set. Route 1 (`claude.ai/api/oauth/usage`) is unreachable: Cloudflare challenges
every claude.ai path pre-auth.

---

## 1. The constraint that shapes everything

**Every poll is a real inference request, and therefore creates usage.**

There is no free probe — `count_tokens`, `/v1/models`, and 400/404 validation errors all
return zero rate-limit headers (verified). Only a successful `/v1/messages` call carries
them.

The consequence is not cost. A minimal Haiku poll is 8 input + 1 output token, and three
consecutive polls moved utilization by 0.00 at the reported resolution. The consequence is
**window anchoring**: the 5-hour session window appears to start on first use. A naive
60s poller would perpetually start and extend 5h windows even when the user is doing
nothing — the app would manufacture the number it exists to report.

So ClawBar polls on evidence of existing activity, not on a wall clock. This is the
central design decision, and it also happens to be the single biggest win for CPU and
battery.

---

## 2. Poll policy

An `ActivityMonitor` watches **`~/.claude`** with an `FSEventStream` (5s latency,
coalescing — effectively free, no polling of the filesystem). Any write updates
`lastActivity`.

On launch there is no event history, so `lastActivity` is seeded from file mtimes. Which
paths matter is not obvious: **a directory's mtime only changes when entries are added,
removed or renamed — not when a file inside it is written.** On this machine
`~/.claude/projects` and `history.jsonl` were observed 3–4 hours stale during continuous
Claude Code use, while `sessions/`, `backups/`, `shell-snapshots/` and `tasks/` tracked it
closely. Seeding from the first pair made a fresh launch conclude the user had been idle
for hours. The seed now takes the newest mtime across all of them.

| Condition | Interval |
|---|---|
| Activity < 5 min ago | 60s |
| Activity < 30 min ago | 5 min |
| Idle | Heartbeat only (default 15 min, configurable, can be Off) |
| Popover opened | Immediate, always |
| Wake from sleep | Immediate |
| Manual refresh | Immediate |
| Any window ≥ 80% | Floor of 60s regardless of activity |

The idle heartbeat exists because `~/.claude` only reflects Claude **Code**. Usage from
claude.ai or the desktop app is invisible to the monitor, so a slow heartbeat keeps the
display honest. It is a genuine trade-off — it keeps session windows alive — so it is
exposed as a setting with that explained in plain words, not buried.

Timers use `DispatchSourceTimer` with generous leeway (`interval / 4`) so the OS coalesces
wakeups with other timers. No `Timer.scheduledTimer` on the main runloop. Suspend on
`NSWorkspace.willSleepNotification`, resume + immediate poll on `didWakeNotification`.

---

## 3. Architecture

```
ClawBar/
  ClawBarApp.swift            @main, AppDelegate wiring
  App/
    AppDelegate.swift         activation policy, minimal main menu, lifecycle
    AppModel.swift            @Observable display state (main actor)
  StatusBar/
    StatusItemController.swift NSStatusItem ownership, change-gated updates
    GaugeRenderer.swift        ring image, cached by (percent, severity)
    BarDisplay.swift           snapshot+state -> rendered string/image
  Data/
    AnthropicUsageClient.swift actor; the one network call
    UsageSnapshot.swift        model
    HeaderParser.swift         header -> Window
    PollScheduler.swift        the table in §2
    ActivityMonitor.swift      FSEvents on ~/.claude/projects
    UsageLog.swift             append-only JSONL
  Security/
    TokenStore.swift           Keychain read/write
  UI/
    PopoverView.swift          SwiftUI dropdown
    WindowGaugeRow.swift       one row per window
    SettingsView.swift
    OnboardingView.swift       first-run token paste
  Info.plist                   LSUIElement = YES
```

Concurrency: `actor AnthropicUsageClient` owns the network; `@MainActor @Observable
final class AppModel` owns display state. `@Observable` (macOS 14+) rather than
`ObservableObject` — no Combine, no publisher graph, fewer allocations.

**Minimum target: macOS 14.** Buys `@Observable`, mature `SMAppService`, and current
`MenuBarExtra` behaviour.

---

## 4. The menu bar item

### Why AppKit for this one piece

SwiftUI's `MenuBarExtra` label renders as a template image. It flattens colour. Since
severity colour is the mechanism that makes the number "immediately obvious", the status
item is `NSStatusItem` and the dropdown is an `NSPopover` hosting SwiftUI via
`NSHostingController`. SwiftUI everywhere the user actually reads content; AppKit only for
the ~80 lines of status-item plumbing.

### Default rendering

```
🕐 7% · 28m
```

- **Glyph carries window identity** — SF Symbol `clock` for the session window,
  `calendar` for the weekly one, rendered as an inline `NSTextAttachment` so both can
  appear in one status item.

  **Never a text prefix.** An earlier draft used `5h 7%` / `7d 20%`, meaning "the
  five-hour window, 7% used". It was misread immediately and correctly as "5 hours
  remaining" — next to a number in a menu bar, a duration-shaped token reads as a
  countdown. A glyph cannot be misread as a number.

- **Text carries the numbers** — percentage and/or time-to-reset, in
  `NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)`. Monospaced digits
  matter: without them the item resizes on every digit change, jittering neighbouring
  menu bar items and forcing relayout.

- **The countdown is half the value.** Percentage alone tells you headroom but not how
  long until relief; the two together are what makes the bar actionable without a click.
  A 20s display timer ticks it between polls — no network, and the change-gate means at
  most one attributed-string assignment per minute.

Severity: normal < 50%, warning 50–79%, critical ≥ 80%, applied to glyph and text
together. Normal uses `labelColor` so it follows light/dark; warning and critical use
`systemOrange` / `systemRed`, which read correctly against both menu bar appearances.

### Switching between the two windows

Three modes, chosen by a segmented control at the bottom of the popover — visible where
you are already looking at both numbers, so the choice is made in context rather than
hunted for in a settings pane:

| Mode | Bar |
|---|---|
| Session | `🕐 7% · 28m` |
| Weekly | `📅 20% · 7h 26m` |
| Both | `🕐 7%  📅 20%` |

Both-mode drops the countdowns — carrying two would roughly double the width — and each
glyph keeps its own severity colour, so whichever window is closer to its limit escalates
independently.

### Switching without clicking

A **global keyboard shortcut** cycles session → weekly → both, default **⌃⌥⌘U**.

Implemented with Carbon's `RegisterEventHotKey`, not
`NSEvent.addGlobalMonitorForEvents`. That choice is deliberate: the NSEvent route needs
Accessibility permission, which is a heavy and alarming prompt for a menu bar utility
that only wants to toggle a label. Carbon hotkeys need no permission, are not deprecated,
and still work on macOS 26.

The shortcut is rebindable. Recording uses a *local* NSEvent monitor — only live while
ClawBar's own Settings window is key — so even configuring it needs no permission. A bare
key with no modifier is refused, since it would swallow ordinary typing system-wide, and
a registration failure (another app already owns the combination) is surfaced in Settings
rather than failing silently.

Right-click was considered and rejected: it costs the same click it was meant to save.

A third axis, **Format**, controls the text half: `7%`, `7% · 28m`, `28m · 7%`, or `28m`.
Ordering is a genuine preference rather than a correctness question, so it is a setting
rather than a decision made for the user, and the picker labels itself with live values so
each option can be seen before it is chosen.

Default is Session at `percent · time` — the session window moves on a timescale you can
act on — it is the one whose number can change within a working session. Both
settings persist in `UserDefaults`.

### Degradation states

Per the verified error shapes:

| State | Bar | Trigger |
|---|---|---|
| `ok` | `◔ 5h 47%` | 200 with headers |
| `stale` | same, dimmed + tooltip "as of 12m ago" | network failure, last good retained |
| `needsAuth` | `⚠︎` | 401 `authentication_error` |
| `limited` | cached value + `!` suffix | 429; back off |
| `noToken` | key glyph | first run |

A missing header renders `—`, **never** `0`. Zero is a real and reassuring value; absence
is not.

**The 429 case is the sharp edge.** A 429 returns *no* rate-limit headers at all
(verified). If plan exhaustion behaves like the model-gating 429s did, the app loses its
data source at exactly the moment it matters most. So `limited` must retain the last good
snapshot **including its reset timestamp**, and keep the countdown running from cached
state. Never clear to zero, never clear to unknown. This is the one state worth writing a
test for.

### Model pinning — an accepted risk

Only `claude-haiku-4-5-20251001` works with a Claude subscription token; every other model
returns 429 (verified). The app is pinned to a single model it does not control, and if
that model is retired or gated the data source stops. Mitigation is detection, not
avoidance: on a persistent 429 across *all* polls, surface "usage data unavailable"
rather than a stale number wearing a fresh face. Keep the model ID in a constant so it is
a one-line change.

---

## 5. Popover content

One `WindowGaugeRow` per window: bar, percentage, status, reset.

- **5h** — "Current session", "resets 22:00 · in 2h 18m".
- **7d** — "All models", same treatment. The countdown is safe: comparison against the
  official Usage panel confirmed a fixed weekly window (VERIFICATION.md).
- **overage** — "Usage credits", hidden when utilization is 0 and status is `allowed`.

Naming follows the official UI exactly — Current session / All models / Usage credits — so
the two never appear to disagree.

**Not available:** the official panel shows a separate per-model weekly meter ("Fable").
No header exposes it, and requesting a different model does not produce one. ClawBar
cannot show per-model limits, and should not imply completeness it does not have.

Whichever window is **nearer its ceiling** is visually emphasised and badged "closest to
limit" — computed by comparing the two utilization figures, not taken from
`representative-claim` (see VERIFICATION.md; that header never varied across 110 samples,
including 52 where it disagreed with the numbers). The badge previously read "binding",
which was both jargon and a claim the data did not support.

A `fallback-percentage` marker is drawn
on the 5h track (observed `0.5`) behind an off-by-default setting labelled as a guess —
it most likely marks the Opus→Sonnet auto-downgrade point, but that is inference, not
observation.

Footer: last-updated age, Refresh, Settings, Quit.

Notifications via `UNUserNotificationCenter` at 50/80/95% per window, latched so each
threshold fires once per crossing, released on window reset or a 5-point drop below the
threshold (hysteresis).

---

## 6. Token handling

The **setup-token** from `claude setup-token`, not the Claude Code keychain entry — that
one's access token is a ~6 hour lease and would leave the app blind whenever the CLI
hadn't refreshed recently.

Stored in the app's own Keychain item, service `com.<owner>.ClawBar`, account
`setup-token`, `kSecAttrAccessibleWhenUnlocked`. Entered by the user in the app's own
onboarding window via `SecureField`. Never logged, never written to disk, never included
in the usage log.

Request shape, minimised against what was verified:

```
POST https://api.anthropic.com/v1/messages
Authorization: Bearer <setup-token>      # Bearer only — x-api-key returns 401
anthropic-version: 2023-06-01
content-type: application/json

{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}
```

`anthropic-beta: oauth-2025-04-20` is **omitted** — verified unnecessary, and dropping it
removes one undocumented dependency. The body is a precomputed `static let Data`; no
encoder runs per poll.

---

## 7. Usage log

Append-only JSONL at
`~/Library/Application Support/ClawBar/usage-log.jsonl`, one line per poll **where a value
changed**:

```json
{"t":1785931200,"u5":0.03,"r5":1785931200,"u7":0.2,"r7":1785956400,"uo":0.0,"claim":"five_hour"}
```

Rotates at 5 MB. Contains no token and no message content.

Its first job is to settle the open question from verification: the observed `7d-reset`
was 9 hours out, not 7 days. Either it is a fixed 7-day window anchored to first use
(started Jul 29 19:00 UTC, resets Aug 5 19:00 UTC — consistent with both timestamps
landing on clean hour boundaries), or it is a rolling window whose timestamp marks when
the oldest usage ages out, in which case utilization steps *down* rather than zeroing and
a countdown label would be a lie. A few days of log data distinguishes these. Until then
the 7d row shows an absolute time and no countdown.

Its second job is to confirm or refute the assumption in §1 — whether ClawBar's own polls
anchor a 5h window. Watch whether `r5` advances during a period of pure idle heartbeat.

---

## 8. Footprint

Tactics, in rough order of effect:

- Activity-gated polling (§2) — the app is genuinely idle most of the time.
- `DispatchSourceTimer` with leeway; suspended across sleep.
- FSEvents instead of directory polling.
- Status item touched **only** when the rendered output changes:
  `guard newDisplay != lastDisplay else { return }`. At most one image render per poll,
  and gauge images are cached by `(intPercent, severity)`.
- Popover's `NSHostingController` built lazily on first open.
- `URLSessionConfiguration.ephemeral`, `urlCache = nil`,
  `httpMaximumConnectionsPerHost = 1`, 15s timeout, `waitsForConnectivity = false`.
- No Combine. No animation on the status item. App Nap left enabled — no
  `beginActivity` call.

### Measure `phys_footprint`, not RSS

RSS counts shared framework pages — AppKit, SwiftUI, CoreGraphics — that are mapped into
every app on the machine and cost the system nothing extra. Chasing it wastes effort on a
number that is not real. `footprint -p <pid>` reports `phys_footprint`, which is what
Activity Monitor calls "Memory" and what actually counts.

For ClawBar the two differ by roughly 5×: **73 MB RSS against 14 MB footprint.**

### Measured

| State | phys_footprint |
|---|---|
| Launched, popover never opened | **14 MB** |
| After use, popover closed | ~34 MB |
| Popover on screen | ~40 MB |

CPU sits at 0.0% between polls.

For context, on the same machine: Grammarly 10 MB, HazeOver 26 MB, Ivory 69 MB,
Bartender 156 MB.

### What the popover actually costs

Showing it allocates ~165 MB of `owned unmapped (graphics)` — GPU compositing surfaces,
not heap. That is **fully released about 24 seconds after close**, and it barely moves
`phys_footprint` because it is not dirty heap. It is macOS compositing a layer-backed
window, not something the app allocates, so there is little to optimise there beyond not
keeping the popover on screen.

Two fixes did matter:

- **Glyph images are cached** by (symbol, severity) — six combinations total. They were
  previously re-rendered on every countdown tick. The cache is dropped on a light/dark
  switch, which also fixes a real bug: `labelColor` is baked in at draw time, so the
  glyph used to keep its old-theme colour after switching.
- **The popover is held warm for 60 seconds after close**, then torn down with
  `malloc_zone_pressure_relief` to hand freed pages back. Rebuilding it on *every* open
  fixed the detached-popover bug but churned a fresh SwiftUI view graph each time;
  re-measuring `contentSize` immediately before each show fixes the position without the
  churn.

Verify with Instruments (Allocations + Time Profiler) and `powermetrics` for wakeups
before calling it done.

---

## 9. Two gotchas worth writing down

**Dock icon.** `LSUIElement = YES` in Info.plist, plus
`NSApp.setActivationPolicy(.accessory)` in `applicationDidFinishLaunching`. Settings and
onboarding windows need `NSApp.activate(ignoringOtherApps: true)` to come forward.

**Cmd+V will not work in the token field.** An `LSUIElement` app has no main menu, and
without an Edit menu the standard editing commands never reach the responder chain — so
the user cannot paste the token into the one field that exists to receive it. Fix by
installing a minimal main menu at launch:

```swift
let main = NSMenu()
let editItem = NSMenuItem()
main.addItem(editItem)
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),        keyEquivalent: "x")
edit.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),       keyEquivalent: "c")
edit.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),      keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),  keyEquivalent: "a")
editItem.submenu = edit
NSApp.mainMenu = main
```

---

## 10. Sparkle

Sparkle 2.9.5 via SPM. Three things are specific to this app.

**Framework embedding is manual.** SPM has no notion of an `.app` bundle, so
`Scripts/build.sh` copies `Sparkle.framework` into `Contents/Frameworks` itself, and
`Package.swift` adds `-rpath @executable_path/../Frameworks` so the executable can find
it. Verified: `otool -L` shows `@rpath/Sparkle.framework/Versions/B/Sparkle` and nothing
else resolving through rpath.

**Nested code must be signed innermost first.** The framework contains two XPC services,
a helper app and the Autoupdate binary, each needing its own signature. A signature covers
everything beneath it, so signing the framework before its XPC services immediately
invalidates it. Order: `Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app`,
`Sparkle.framework`, then the app. The XPC services need
`--preserve-metadata=entitlements`; re-signing without it silently drops their
entitlements.

**An accessory app cannot raise its own windows.** Same problem the onboarding window had.
`UpdaterUIDelegate.standardUserDriverWillShowModalAlert()` activates the app before any
Sparkle prompt appears, and `supportsGentleScheduledUpdateReminders` tells Sparkle there
is no dock icon to bounce, so a scheduled reminder should not be assumed seen.

### Signing key

A ClawBar-specific EdDSA key, generated with `generate_keys --account ClawBar`. Budgetry's
key is a separate item under the same Keychain service and is untouched — one key per app,
so a compromise of one does not authorise updates for the other.

**The private key exists only in the login Keychain.** Lose it and no already-installed
copy can ever be updated again, because the public key is baked into every shipped
Info.plist. Back it up.

### Publishing

`Scripts/appcast.sh` stages the notarised DMG into a checkout of a **public** releases
repo and runs Sparkle's own `generate_appcast`. It refuses to publish a DMG without a
stapled notarisation ticket.

DMGs are committed to that repo rather than attached as GitHub release assets, because a
release asset's URL contains its tag — every version would need a different
`--download-url-prefix`, and `generate_appcast` takes one for the whole folder. Committing
keeps the prefix constant and lets the stock tool do the whole job. Cost is repo size,
roughly 5 MB per release, so prune old DMGs periodically. Budgetry solves the same problem
with a custom `appcast-add.py`; that is the alternative if the repo grows awkward.

## 11. Build order

1. `AnthropicUsageClient` + `HeaderParser` + `UsageSnapshot`, with a fixture-backed test
   using the captured headers.
2. `TokenStore` + onboarding — including the Edit menu, or you cannot paste the token.
3. `StatusItemController` + `GaugeRenderer` against a stubbed snapshot.
4. `PollScheduler` + `ActivityMonitor`.
5. `UsageLog` — early, so the 7d question starts collecting data while the UI is built.
6. Popover UI, then settings, then notifications.
7. `SMAppService.mainApp.register()` for launch at login.
