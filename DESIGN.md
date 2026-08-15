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
Sources/ClawBar/
  App/
    ClawBarMain.swift          @main; also the --projection probe
    AppDelegate.swift          activation policy, Edit menu, windows, lifecycle
    AppModel.swift             display state and refresh
  StatusBar/
    StatusItemController.swift NSStatusItem ownership, change-gated updates
    BarRendering.swift         snapshot -> segments -> attributed string; symbol cache
  Data/
    AnthropicUsageClient.swift the one network call
    UsageSnapshot.swift        model, health bands, duration formatting
    PollScheduler.swift        the interval table in §2
    ActivityMonitor.swift      FSEvents on ~/.claude
    ProjectionHistory.swift    weekly projection (§10)
    UsageLog.swift             append-only JSONL diagnostic
    Notifier.swift             threshold alerts with hysteresis
  Security/
    TokenStore.swift           Keychain read/write
  Support/
    Preferences.swift          UserDefaults-backed settings
    HotKeyCenter.swift         Carbon global hotkey
    UpdaterController.swift    Sparkle
  UI/
    PopoverView.swift          the dropdown
    SettingsView.swift
    OnboardingView.swift       first-run token paste
    ShortcutRecorder.swift
Resources/Info.plist           LSUIElement = YES
```

Concurrency: everything user-facing is `@MainActor`; `AnthropicUsageClient` is a
stateless enum whose one `async` call hops off automatically. State is
`ObservableObject` rather than `@Observable` — the popover is rebuilt per open, so the
finer-grained invalidation `@Observable` buys would not pay for itself here.

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

### Removed: the "closest to limit" badge

One window used to be badged as the one nearest its ceiling. It went through two
definitions and neither survived.

First it was driven by `representative-claim`, labelled "binding". That header turned out
to mean nothing usable — `five_hour` in all 110 logged samples, including 52 where the
weekly window was the more consumed of the two (VERIFICATION.md).

It was then recomputed by comparing the two utilization figures and relabelled "closest to
limit". That is worse than redundant. Two adjacent, identically formatted numbers already
say which is larger — but the badge implies it is answering "what will stop you", and
percentage cannot answer that when the windows have wildly different lifespans:

```
845 readings
  badge sat on 'Current session' : 247  (29%)
  median time until that window vanished entirely : 1.6h
  time the weekly window it outranked had left    : 5.3 days
```

Nearly a third of the time it pointed at a window with about ninety minutes to live while
dismissing one with five days to accumulate. The consequences are asymmetric too: hitting
the session limit costs hours, hitting the weekly costs days, so equal percentages are not
equally important.

The only version that would earn the space is "runs out first", computed from rate and
time remaining — which needs a session projection, and a five-hour window is far too
bursty to fit a rate to. So the badge is gone, along with the title emphasis it drove.

The `fallback-percentage` marker was removed for a related reason: it drew a tick visually
identical to the projection marker while meaning something entirely different, and was
unlabelled guesswork from an undocumented header.

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

## 10. Weekly projection

The popover projects where the weekly window will land. Three decisions, each taken from
measurement rather than taste.

### Which rate

Two candidates were backtested against 828 logged readings, measuring how well each
predicted actual utilisation some hours later. Horizons straddling a reset were excluded,
since nothing can predict those.

| Horizon | since reset | last 24h | blend |
|---|---|---|---|
| 24h | **2.0 pts** | 3.1 | 2.5 |
| 48h | **1.4 pts** | 2.6 | 1.8 |
| 72h | **3.4 pts** | 4.0 | 3.5 |
| 96h | **6.3 pts** | 7.5 | 6.9 |

Mean absolute error. **Since-reset wins at every horizon**, by roughly a third. The
24-hour rate loses because it is noisier, and that costs more than the staleness the
longer average suffers. Blending the two is worse than the better one alone, so the
24-hour rate is not shown at all — two competing figures would advertise indecision, not
uncertainty.

### The baseline is the last zeroing, not the window start

Anthropic zeroes the weekly counter mid-window from time to time — observed going
29% → 0% on 11 Aug 2026 with the reset timestamp unchanged. This is deliberate on their
part and recurring, not an anomaly.

Anchoring the rate to the most recent zeroing rather than the nominal window start makes
that a non-event: the reset simply becomes the new starting line. No special-casing.

### Confidence comes from the horizon

Error grows about 1.5 points per day projected, per the table above. That, not a round
number, sizes the verdict band:

```
margin  = max(3, 1.5 × daysRemaining)
onTrack     projected + margin < 100
willRunOut  projected − margin > 100
mayRunOut   otherwise
```

So the same 95% projection reads "may run out" four days ahead and "will run out" four
hours ahead, which is the honest difference.

Nothing is shown until a full day has passed since the baseline — below that the estimator
swung 17 points inside two and a half days in backtest. It therefore also goes quiet for a
day after each Anthropic reset, which is correct: at that point the new rate is genuinely
unknown.

History lives in its own `projection-history.json`, **not** the usage log, so that turning
off an optional diagnostic cannot silently break a feature.

### How it is drawn

A translucent extension of the progress bar reaching the projected point, with a solid
cap at its end, and a caret directly beneath carrying "projected 61%".

Two details that only became obvious once the thing was rendered:

**The caret is positioned exactly; the label moves.** An earlier version clamped the whole
group to keep the text on screen, which at 90% slid the caret some 70pt away from the
point it exists to indicate. A pointer that does not point is worse than no pointer, so
the label now flips to the caret's left near the right edge.

**The projection is coloured by its outlook, not by current health.** The solid fill says
where you are; the ghost says where you are going, and those disagree exactly when it
matters. At 45% heading to 90% the bar was drawing a calm grey extension under an amber
label. The ghost now goes amber, then red, so the bar tells the story before the number
is read.

Known limitation: the bar cannot depict overflow, so a projection of 105% and one of 200%
fill it identically and only the figure distinguishes them.

Five other treatments were built and rendered before this one was chosen — a faint tick, a
plain ghost fill, a dashed outline, and two variants putting "20% → 61%" in the header.
`--render-states` remains, since usage cannot be driven to 90% on demand to check the UI.

### Diagnostics — run them from the signed bundle

```
dist/ClawBar.app/Contents/MacOS/ClawBar --projection
dist/ClawBar.app/Contents/MacOS/ClawBar --render-popover /tmp/p.png [--dark]
dist/ClawBar.app/Contents/MacOS/ClawBar --render-states /tmp/s.png
dist/ClawBar.app/Contents/MacOS/ClawBar --test-notifications
```

`--test-notifications` drives the real `Notifier` through a scripted sequence of
utilisations and asserts what fired at each step. Threshold alerts are otherwise
effectively untestable — you cannot burn to 50% of a weekly window on demand, and waiting
for it exercises one path, once. The script covers first crossing, the latch, hysteresis
release, re-firing after release, the higher thresholds, and the window change that clears
the latches. It also prints live authorisation status, since a denied app fails silently.

Verified end to end: 9/9 assertions, and the four expected alerts confirmed present in
Notification Centre's own database rather than merely reported as sent.

`--projection` prints what the popover would show, exercising the real code path.
`--render-popover` draws the popover offscreen, so UI can be checked without Screen
Recording permission. (Its `ImageRenderer` cannot draw AppKit-backed Pickers — they come
out as yellow placeholders. That is the renderer, not the app.)

**Never run these from `.build/release/ClawBar`.** That binary is ad-hoc signed: no team
identifier, a different bundle identifier, and *no designated requirement at all*. The
Keychain therefore identifies it by exact code hash, so every rebuild is an unrecognised
new client asking for the token — and "Always Allow" cannot stick, because it was granted
to a hash that no longer exists. The result is an endless stream of Keychain prompts.

`dist/ClawBar.app` carries a designated requirement identical to the installed copy's, so
it inherits the trust already granted and prompts for nothing.

## 11. Sparkle

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

## 12. Build order

1. `AnthropicUsageClient` + `HeaderParser` + `UsageSnapshot`, with a fixture-backed test
   using the captured headers.
2. `TokenStore` + onboarding — including the Edit menu, or you cannot paste the token.
3. `StatusItemController` + `GaugeRenderer` against a stubbed snapshot.
4. `PollScheduler` + `ActivityMonitor`.
5. `UsageLog` — early, so the 7d question starts collecting data while the UI is built.
6. Popover UI, then settings, then notifications.
7. `SMAppService.mainApp.register()` for launch at login.
