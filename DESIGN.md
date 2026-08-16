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

### A pending timer must not be re-armed

`reschedule()` runs on every filesystem event, and FSEvents delivers one roughly every
five seconds while Claude Code is running. The first version cancelled and re-armed
unconditionally, so each event restarted the sixty-second countdown and **the timer never
reached zero** — a poll only happened once activity stopped for a full minute.

The effect was exactly inverted from the intent: the harder you worked, the less often it
refreshed, and hard work is when usage moves fastest. It looked like the app quietly
getting lazier as sessions got busier.

`reschedule()` now returns early when a timer is already pending at the wanted interval,
re-arming only when the tier genuinely changes. The timer is cleared inside its own
handler before polling, so the reschedule that follows a firing does re-arm rather than
seeing a stale non-nil timer.

Measured under continuous Claude Code activity, with `CLAWBAR_DEBUG=1` logging each poll:

```
poll at 21:39:28   poll at 21:40:43   poll at 21:41:48   poll at 21:43:03
gaps: 75, 65, 75 seconds        (60s target, leeway 15s)
```

The lesson generalises: any timer re-armed from a high-frequency event source will starve.
Treat "already scheduled correctly" as the common case.

---

## 3. Architecture

```
Sources/ClawBar/
  App/
    ClawBarMain.swift          @main; also every diagnostic flag (§10)
    AppDelegate.swift          activation policy, main menu, windows, lifecycle
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
    ClaudeCode.swift           locates the CLI; PATH is empty in a GUI process
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
⟨clock⟩ 7% · 28m
```

Written `⟨clock⟩` rather than `🕐` deliberately. The glyph is an SF Symbol tinted to the
current severity colour; the emoji is a fixed colour clock face showing half past two, and
renders differently on every platform that reads this file. An earlier draft of both this
document and the README used the emoji, which meant the one picture of the product was
wrong everywhere it appeared.

`--render-menubar` draws the real item — through `barSegments` and `attributedBar`, the
same functions the live app calls — to [docs/menubar-dark.png](docs/menubar-dark.png) and
its light counterpart. That is what the README shows. Regenerate them when this changes.

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

Severity: normal < 80%, warning 80–94%, critical ≥ 95%, applied to glyph and text
together. Normal uses `labelColor` so it follows light/dark; warning and critical use
`systemOrange` / `systemRed`, which read correctly against both menu bar appearances.

### Switching between the two windows

Three modes, chosen by a segmented control at the bottom of the popover — visible where
you are already looking at both numbers, so the choice is made in context rather than
hunted for in a settings pane:

| Mode | Bar |
|---|---|
| Session | `⟨clock⟩ 7% · 28m` |
| Weekly | `⟨calendar⟩ 20% · 6d 4h` |
| Both | `⟨clock⟩ 7%  ⟨calendar⟩ 20%` |

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

| State | Bar | Colour | Trigger |
|---|---|---|---|
| `ok` | `⟨clock⟩ 7% · 28m` | by severity | 200 with headers |
| `stale` | same + ` *`, tooltip names the cause and age | by severity | network failure; last good retained |
| `limited` | same + ` !`, tooltip "showing last known reading" | by severity | 429; back off |
| `loading` | `…` | normal | first poll in flight |
| `noToken` | `Set up` | warning | first run |
| `needsAuth` | `auth` | critical | 401 `authentication_error` |
| `failed` | `—`, tooltip carries the reason | warning | anything else |

The degraded states are **words, not symbols**. `⚠︎` and a key glyph were tried first and
both failed the same test: a lone symbol in a menu bar says something is wrong without
saying what, and there is no room for a legend. "Set up" and "auth" are each short enough
to fit and specific enough to act on, and both status items are clickable straight through
to the thing that fixes them.

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

One `WindowRow` per window: bar, percentage, status, reset.

- **5h** — "Current session", "resets 10:00 pm · in 2h 18m".
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

### Where the colours change

| Range | State | Colour | Also happens here |
|---|---|---|---|
| 0–79% | normal | `labelColor` — follows light/dark | — |
| 80–94% | warning | `systemOrange` | notification; poll interval floors at 60s |
| 95–100% | critical | `systemRed` | notification |

These were 50 and 80. Half a window used is unremarkable — nothing needs doing — and a
colour that fires when nothing needs doing is a colour you stop reading. 80 is the first
point where the end is genuinely in sight; 95 is "about to be blocked".

Moving them also removed a mismatch. Notifications fired at 50/80/95 against colour bands
at 50/80, so 95 alerted while nothing on screen changed. The two now share thresholds
exactly, and the 50% notification is gone for the same reason the 50% colour band is: a
notification is a *more* intrusive way to say nothing than a colour is.

The projection's colours are a separate system and deliberately do not use these bands —
they are keyed to crossing 100%, not to being at 80. See §10.

Notifications via `UNUserNotificationCenter` at 80/95% per window, latched so each
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

It was added to answer two questions that could not be settled by inspection. Both are now
settled, and the answers are recorded here because the log is the only evidence for them.

**The weekly window is fixed, not rolling.** The first observation had `7d-reset` nine
hours out rather than seven days, which is consistent with either a fixed window anchored
to first use or a rolling one whose timestamp marks when the oldest usage ages out. The
distinction mattered: a rolling window steps *down* gradually, and a countdown label
against it would be a lie. Logged resets land a clean `+7.000 days` apart and utilisation
drops straight to zero rather than decaying, so it is fixed. The 7d row shows a countdown
on that basis (VERIFICATION.md).

**ClawBar's own polls do anchor a 5-hour session window.** `r5` advances during periods of
pure idle heartbeat, so the assumption in §1 is correct and the activity gating is load-
bearing rather than merely a battery optimisation. The anchoring costs no measurable
utilisation — the window starts, but reads 0% — which is why the idle heartbeat is offered
at all rather than removed. Users who care are given the Off switch and the reason.

A third use emerged that was not planned: it is the only source of history long enough to
backtest against, and every calibrated number in §10 — the estimator choice, the 1.5
points/day error growth, the 60% session threshold — was fitted to it. Turning it off
costs those, which is why projection history lives in its own file (§10) and does not
depend on this one.

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
`NSApp.setActivationPolicy(.accessory)` in `applicationDidFinishLaunching`.

**An accessory app must activate itself to show a window — with `NSApp.activate()`, not
`activate(ignoringOtherApps:)`.** The latter is deprecated on macOS 14 and does nothing.
Since an accessory app has no dock icon for the system to activate it through, a window
ordered front without activation is created, sized and laid out entirely correctly, and
never appears. It looks exactly like a rendering bug, and the onboarding window — the
first thing a new user must see — was invisible for precisely this reason.

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

### Why the session window projects too — but usually says nothing

The session window was originally left unprojected on the grounds that five hours is too
short and bursty to fit a rate to. Backtesting says that was wrong on the facts:

```
554 predictions across 42 session windows
  mean absolute error : 4.3 pts
  median              : 1.7 pts
```

Comparable to the weekly estimator's 1.4–6.3. Accuracy was never the problem. Two other
things are:

**It over-predicts.** 78% of predictions came in high, mean +3.1 points. Session usage is
front-loaded — a burst at the start, then a taper — so rate-since-start extrapolates a
pace that does not hold.

**It has nothing to say.** Across 41 logged windows the median peak was 8%, the highest
ever 45%, and not one passed 50%. "Projected 9%" every time is furniture.

So it is computed but suppressed below a projected 60%. Below that there is no decision to
make and the over-prediction bias would only cry wolf; above it, being blocked mid-task
for up to five hours is worth a warning. A user who works the session window harder gets
the projection; one who never approaches it never sees it.

### Reset labels name the day

`resets 5:00 am · in 4d 8h` is ambiguous — which 5:00 am? The label now scales with distance
(rendered here in en_AU):

| Distance | Rendered |
|---|---|
| Today | `resets 10:30 pm` |
| Tomorrow | `resets tomorrow 4:23 am` |
| Within a week | `resets Thu 5:00 am` |
| Beyond | `resets Mon, 24 Aug 8:23 pm` |

Relative wording near at hand because "tomorrow" reads faster than a weekday name;
absolute beyond a week, where a bare weekday becomes ambiguous again. The countdown stays
alongside: the named time answers "when can I plan for this", the duration answers "how
long must I wait", and neither substitutes for the other. `--dates` exercises every
branch, since only one is reachable at any given moment.

### Nothing here picks a clock or a date order

Every user-facing time comes from `clockTime`, which uses `timeStyle = .short`, and every
date from a template passed to `DateFormatter.dateFormat(fromTemplate:options:locale:)`.
Neither names a pattern. This is not stylistic tidiness — it is the fix for a real bug.

`clockTime` was `HH:mm`, which renders 24-hour for everyone. That is wrong in most locales,
and it ignored the explicit 12/24-hour switch in System Settings, so a user who had stated a
preference was overruled by a string literal. It was also wrong on the machine this was
written on: **en_AU defaults to am/pm**, so ClawBar disagreed with the menu bar clock beside
it for every release up to 0.5.3.

The date patterns failed the same way and one step further. `EEE d MMM` fixes
day-before-month, which is wrong in the United States; and `'at'` in
`EEE d MMM 'at' HH:mm` stays English in every locale. A template cannot express those
mistakes — it names the fields wanted and lets the locale order them, supply separators, and
choose a connector. Some locales need shapes a reordering could never produce: ja_JP renders
`8月16日(日)`, which is a different construction, not a permutation of the same tokens.

Verified against an explicit hour cycle rather than by changing system settings:
`en_AU@hours=h23` renders `17:50` and `en_GB@hours=h12` renders `5:50 pm`, so the override is
honoured in both directions. `--dates` accepts `-AppleLocale <id>` for spot checks, since
NSUserDefaults takes an argument domain. Note that `-AppleICUForce24HourTime` does *not* work
that way — it reaches `UserDefaults` but never `Locale.current`, so it looks like the fix has
failed when it has not.

The one deliberate exception is the `CLAWBAR_DEBUG` poll stamp, which stays `HH:mm:ss`: it
goes to stderr for comparing poll gaps, where am/pm makes spans across noon harder to read
and locale-dependence makes logs from two machines incomparable.

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

### Past 100%, the bar runs out of room

A fill clamped at the bar's width saturates: a projection of 105% and one of 200% drew an
identical bar, so the graphic stopped carrying information exactly where the difference
matters most — scraping past the limit versus blowing through it twice over call for
different responses.

Chevrons sit **outside** the right edge, in the popover's padding: `›` for 100–124%, `››`
for 125–174%, `›››` beyond. They read as "off the end of the scale", and cost the bar no
width, so a full bar always means the same quantity. Rescaling the bar to fit 200% was
rejected for exactly that reason — the same visual would represent different amounts
depending on the projection, and the current-usage fill would move for reasons unrelated
to usage.

**Above 100% the caret is dropped.** The first attempt kept it, and it pointed at the
clamped position — indicating 100% while the label read 200%, which is the original bug
relocated rather than fixed. It also sat immediately beside the chevrons: two different
red marks meaning different things in the same place, the same error as the old
fallback-percentage tick. A pointer that cannot reach its target should not pretend to, so
the chevrons carry the meaning and the label right-aligns beneath them.

One soft spot worth naming: the 25%- and 75%-over boundaries between one, two and three
chevrons are judgement, not measurement. Everything else in the projection — the estimator,
the confidence margin, the session display threshold — comes from backtesting. These do
not, because there is nothing to calibrate against.

Five other treatments were built and rendered before this one was chosen — a faint tick, a
plain ghost fill, a dashed outline, and two variants putting "20% → 61%" in the header.
`--render-states` remains, since usage cannot be driven to 90% on demand to check the UI.

### Diagnostics — run them from the signed bundle

All of them run from `dist/ClawBar.app/Contents/MacOS/ClawBar` and exit without launching
the app.

| Flag | What it does |
|---|---|
| `--version` | The exact string Settings shows, version and build |
| `--projection` | What the popover would show, via the real code path |
| `--dates` | Every branch of the reset label; only one is reachable at a time |
| `--test-notifications` | Drives the real `Notifier` through a scripted sequence and asserts |
| `--test-escape` | Proves `EscapeClosableWindow` closes and a plain `NSWindow` does not |
| `--render-menubar <png> [--dark]` | The status item in every mode and severity |
| `--render-windows <png> [--dark]` | The two popover rows as a user sees them |
| `--render-popover <png> [--dark]` | The whole popover, offscreen |
| `--render-states <png>` | The projection across its range, including past 100% |
| `--render-bands <png>` | The health bands at their boundaries |
| `--render-onboarding <png>` | First run; pair with `CLAWBAR_FAKE_NO_CLAUDE=1` |

`CLAWBAR_DEBUG=1` logs each poll with its interval — the only way the scheduler starvation
in §2 was visible. `CLAWBAR_DUMP_MENU=1` dumps the installed main menu.

The `--render-*` flags exist because the alternative is Screen Recording permission, which
a build machine does not have and a reviewer should not need to grant. They also reach
states real data will not produce on demand: usage cannot be driven to 96% to check a
colour.

`--test-notifications` drives the real `Notifier` through a scripted sequence of
utilisations and asserts what fired at each step. Threshold alerts are otherwise
effectively untestable — you cannot burn to 80% of a weekly window on demand, and waiting
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

A **signed** `dist/ClawBar.app` carries a designated requirement identical to the installed
copy's, so it inherits the trust already granted and prompts for nothing.

The word *signed* is load-bearing. `SIGN=0 ./Scripts/build.sh` ad-hoc signs the bundle
too — `codesign -dv` reports `Signature=adhoc` and `TeamIdentifier=not set` — which puts it
in exactly the same position as `.build/release/ClawBar` despite living at the path this
section recommends. Any flag that reaches the Keychain (`--projection` and
`--render-popover` both do, via `AppModel`) will then block on a prompt, and under a shell
redirect that looks like a hang rather than a question. Check with:

```bash
codesign -dv dist/ClawBar.app 2>&1 | grep -E 'Signature|TeamIdentifier'
```

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

A ClawBar-specific EdDSA key, generated with `generate_keys --account ClawBar`. Sparkle
stores keys as separate accounts under one Keychain service, so an existing key belonging
to another app is untouched — one key per app, so a compromise of one does not authorise
updates for the other.

**The private key exists only in the login Keychain.** Lose it and no already-installed
copy can ever be updated again, because the public key is baked into every shipped
Info.plist. Back it up.

### The update path, verified

Exercised properly once: 0.4.3 was published while the installed copy was deliberately
left on 0.4.2, and the update ran unattended.

```
before   ClawBar 0.4.2 (15)
after    ClawBar 0.4.3 (18)

signature: valid          staple: worked
spctl: accepted, source=Notarized Developer ID
Sparkle.framework present
```

The signature and notarisation checks are the point. Sparkle replaces the whole bundle,
and an update that lands unsigned or unstapled would fail Gatekeeper on next launch — for
everyone at once, discovered only by them.

**The appcast is CDN-cached for five minutes.** `raw.githubusercontent.com` sends
`cache-control: max-age=300`, so a freshly pushed appcast is not visible immediately —
measured at 226s, 246s, 266s, 286s stale, then refreshing at exactly 300s. Nothing to fix,
but publish and then testing straight away shows the old feed, which looks like a broken
release when it is not.

Triggering a check without touching the installed build: back-date `SULastCheckTime` in
the app's defaults and relaunch. Sparkle checks on launch once the interval has elapsed.

```bash
defaults write com.victorrodrigues.ClawBar SULastCheckTime -date "2026-01-01 00:00:00 +0000"
```

### Publishing

`appcast.xml` is committed to this repository and served from `raw.githubusercontent.com`.
The DMGs are **GitHub release assets**, not committed files — a binary per release would
grow the git history permanently, and history is the one thing that cannot be pruned later
without rewriting every clone.

That choice costs the stock tooling. Sparkle's `generate_appcast` takes one
`--download-url-prefix` for a whole folder, but a release asset's URL embeds its tag, so
every version needs a different prefix. `Scripts/appcast-add.py` replaces it: it signs with
`sign_update` and adds or replaces exactly one `<item>`, leaving the rest of the feed alone.

**Each release attaches the DMG twice.** Once version-stamped (`ClawBar-0.5.2.dmg`), which
is what the appcast enclosure points at — Sparkle needs a distinct URL per version. Once as
plain `ClawBar.dmg`, because the README's download button uses
`releases/latest/download/ClawBar.dmg`, which resolves only against an asset of exactly that
name. Publishing only the stamped one leaves the button 404ing, which is invisible to anyone
who tests updates but not the front page. The duplication is a few megabytes per release.

### The binary must correspond to a commit

`gh release create` tags whatever the **remote's** HEAD is. Publish before the release's own
work is committed and pushed, and the tag lands on the previous release's commit — so the
published source contradicts the published binary, and `CFBundleVersion`, being the commit
count, names source that was never built.

Four tags reached the public repo this way (v0.4.3, v0.4.4, v0.4.5, v0.5.2) before being
moved by hand. v0.5.2 was the clearest: the DMG reported `0.5.2 (38)` while commit 38 had
`VERSION` 0.5.1, because the bump was still sitting unstaged.

`Scripts/appcast.sh` now refuses to proceed unless all of:

| Guard | Catches |
|---|---|
| working tree clean | building from uncommitted work |
| `HEAD:VERSION` == built version | the v0.5.2 failure exactly |
| build number == commit count at HEAD | publishing a stale build |
| HEAD is an ancestor of `origin/<branch>` | committed but not pushed |

The fourth exists because the first three do not cover the case that matters. They all
interrogate the *local* repository, and `gh release create` acts on the remote — so v0.5.3
went out tagged on the wrong commit anyway, minutes after the other three were written to
prevent that. Local correctness is not the property being asserted.

It also still refuses if a tag for the current `VERSION` already exists, or if the DMG
carries no stapled notarisation ticket.

## 12. Versioning

**`CFBundleShortVersionString` changes only when a release is cut.** It lives in the
`VERSION` file at the repo root; `Scripts/build.sh` reads it and never invents one.

**`CFBundleVersion` is the git commit count**, derived at build time. Monotonic,
reproducible from any checkout, and nothing to maintain by hand — which matters because
Sparkle compares *this*, not the version string, to decide whether an update exists. A
hand-kept counter is exactly the sort of thing that gets duplicated or skipped, and a
duplicate silently breaks updates for everyone already on that build.

This rule exists because the opposite was done first: the version was bumped on every
build, producing eight versions of which two were ever published. The number tracked
whoever was iterating rather than anything a user would recognise.

Two builds can therefore legitimately report the same version, so Settings shows both —
`ClawBar 0.4.2 (14)`.

Cutting a release: edit `VERSION`, then build → notarise → appcast → `gh release create`.
`Scripts/appcast.sh` refuses to publish if a tag for the current `VERSION` already exists,
since that would overwrite a live appcast entry and point it at different bits.

## 13. Build order

Written before any code existed, and kept because the ordering rationale outlived the plan.
Two of its names never materialised: header parsing folded into `AnthropicUsageClient`
rather than becoming a `HeaderParser`, and `GaugeRenderer` became `BarRendering`.

1. `AnthropicUsageClient` + `UsageSnapshot`, against the captured header fixtures.
2. `TokenStore` + onboarding — including the main menu, or the token cannot be pasted into
   the one field that exists to receive it (§9).
3. `StatusItemController` + `BarRendering`, against a stubbed snapshot.
4. `PollScheduler` + `ActivityMonitor`.
5. `UsageLog` early, so history accumulates while the UI is still being built.
6. Popover UI, then settings, then notifications.

Step 5 mattered far more than it looked. Every calibrated number in §10 — the estimator
choice, the error growth, the session threshold — was fitted to data the log had already
been quietly collecting for weeks by the time the projection was designed. Had it been
built last, the projection would have shipped on guesswork or waited a month.
7. `SMAppService.mainApp.register()` for launch at login.
