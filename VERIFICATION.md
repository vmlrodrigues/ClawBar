# Route verification — observed, 2026-08-05

Everything here was measured, not read in docs. Neither route is documented; both can
break without notice.

Account under test: `subscriptionType: max`, `rateLimitTier: default_claude_max_20x`.

---

## Route 1 — `GET claude.ai/api/oauth/usage` — UNREACHABLE

```
HTTP/2 403
content-type: text/html; charset=UTF-8
cf-mitigated: challenge
```

Body is the Cloudflare `Just a moment` / `challenge-platform` interstitial.

- Fires **pre-auth** — an unauthenticated request returns a byte-identical 403, so the
  token is never evaluated and scopes are irrelevant.
- **Site-wide** — `/api/oauth/usage`, `/api/organizations`, `/api/bootstrap`, `/login`
  and `/` all return the same HTML 403.
- Not a User-Agent sniff — default curl UA and a custom UA behave identically.

Not usable as a primary source or a fallback. Getting past it would mean browser
impersonation (TLS fingerprinting, executing the Turnstile challenge), which breaks
silently whenever Cloudflare retunes and is the kind of traffic that gets accounts
flagged.

---

## Route 2 — `POST api.anthropic.com/v1/messages` — WORKS

`HTTP 200`, warm latency ~0.8s (first/cold call was 6.1s).

### Full header set

```
anthropic-ratelimit-unified-status:                allowed
anthropic-ratelimit-unified-5h-status:             allowed
anthropic-ratelimit-unified-5h-utilization:        0.03
anthropic-ratelimit-unified-5h-reset:              1785931200
anthropic-ratelimit-unified-7d-status:             allowed
anthropic-ratelimit-unified-7d-utilization:        0.2
anthropic-ratelimit-unified-7d-reset:              1785956400
anthropic-ratelimit-unified-overage-status:        allowed
anthropic-ratelimit-unified-overage-utilization:   0.0
anthropic-ratelimit-unified-overage-reset:         1785922800
anthropic-ratelimit-unified-representative-claim:  five_hour
anthropic-ratelimit-unified-fallback-percentage:   0.5
anthropic-ratelimit-unified-reset:                 1785931200
anthropic-organization-id:                         672fbfc5-…   (present on individual accounts)
```

Utilization is a 0–1 float at 2dp. Resets are Unix seconds.

`representative-claim` names the currently binding window — the server tells you which
number matters, so the UI does not have to guess.

`fallback-percentage: 0.5` is unexplained. Most plausibly the Opus→Sonnet auto-downgrade
threshold. Inference, not observation.

### Confirmed against the official Usage UI

Settings → Usage screenshot taken ~2 min before a header read (48 min vs 46 min to session
reset). The mapping is exact:

| Official UI | Header prefix | UI value | Header value |
|---|---|---|---|
| **Current session** | `unified-5h-*` | 6% | `0.06` |
| **All models** (weekly) | `unified-7d-*` | 21% | `0.20` |
| **Usage credits** (toggle on) | `unified-overage-*` | — | `0.00` |
| **Fable** (weekly, per-model) | *nothing* | 3% | **not exposed** |

Reset times line up too: UI "resets in 7 hr 48 min" against a measured `7d-reset` of
19:00 UTC. **This also settles open question 1 below** — the 7d window is a fixed weekly
window, and the earlier 9-hour figure was simply this week's window nearing its end.

Two caveats:

- **Precision.** The header carries 2dp and appears to floor; the UI reads up to one point
  higher. Display `floor(util * 100)` and accept being ≤1 point under the official figure.
  Rounding up to chase it would invent precision the header does not carry.
- **No per-model window.** The UI's separate Fable weekly meter has no header equivalent,
  and requesting a different model does not produce one (see below). Route 2 can show
  Current session and All models; it cannot show per-model weekly limits.

### Model gating — only Haiku 4.5 works

Every other model returns `429 rate_limit_error` at 6% session / 20% weekly utilization,
so this is a token restriction rather than a genuine limit. Adding
`anthropic-beta: oauth-2025-04-20` does not help.

| Model | Result |
|---|---|
| `claude-haiku-4-5-20251001` | **200**, 13 unified headers |
| `claude-sonnet-4-5-20250929` | 429 `rate_limit_error`, 0 headers |
| `claude-opus-4-5-20251101` | 429 `rate_limit_error`, 0 headers |
| `claude-sonnet-4-6` | 429 `rate_limit_error`, 0 headers |
| `claude-opus-4-8` | 429 `rate_limit_error`, 0 headers |
| `claude-fable-5` / `claude-opus-5` / `claude-sonnet-5` | 429 `rate_limit_error`, 0 headers |

The app is therefore pinned to one model it does not control. If Haiku 4.5 is ever
retired or gated the same way, the data source stops entirely.

### A 429 carries no rate-limit headers at all

```
HTTP/2 429
x-should-retry: true
request-id: req_…
anthropic-organization-id: …
```

No `anthropic-ratelimit-unified-*` of any kind. Operationally this is the sharpest edge in
route 2: **if hitting the plan limit also returns 429, the app goes blind at exactly the
moment it matters most.** The design must retain the last good snapshot — including its
reset timestamp — and keep counting down through a 429 rather than clearing to zero or
unknown.

### Request shape — what is actually required

| | |
|---|---|
| `Authorization: Bearer <token>` | **Required.** `x-api-key` with the same token → `401 invalid x-api-key` |
| `anthropic-beta: oauth-2025-04-20` | **Not required.** Omitting it still returns all 13 unified headers |
| `anthropic-version: 2023-06-01` | Standard |

### No free probe exists

The unified headers appear only on a successful inference call. Verified negatives:

| Endpoint | Result | Unified headers |
|---|---|---|
| `/v1/messages/count_tokens` | 200 | none |
| `/v1/messages`, bad model | 404 | none |
| `/v1/messages`, malformed body | 400 | none |
| `/v1/models` | 200 | none |

Validation errors short-circuit before the quota layer.

### Poll cost

Three consecutive minimal Haiku polls (8 input + 1 output tokens each) moved utilization
by **0.00** — below the 2dp reporting resolution. Cost is not the constraint; window
anchoring is (see DESIGN.md §1).

### Error shapes for fallback handling

```
401  {"type":"error","error":{"type":"authentication_error",
      "message":"OAuth access token is invalid."},"request_id":null}
```

Clean JSON, easy to discriminate from network failure.

---

## Token sources

**Claude Code keychain** (`security find-generic-password -s "Claude Code-credentials"`)
— JSON under `claudeAiOauth`:

```
accessToken           sk-ant-oat01-…   expires in ~6 HOURS
refreshToken          sk-ant-ort01-…   expires in ~27 days
scopes                user:file_upload user:inference user:mcp_servers
                      user:profile user:sessions:claude_code
```

Five scopes, not one — `user:inference` means this token *does* work for Route 2. But the
~6 hour access-token lease disqualifies it for an always-on app: it would go blind
whenever the CLI had not refreshed recently. Refreshing it independently would rotate the
token underneath a running CLI session.

**Setup token** (`claude setup-token`) — ~1 year. This is what ClawBar uses.

---

## Open questions

1. ~~**7d window semantics.**~~ **Settled** by the UI comparison above — it is a fixed
   weekly window, labelled "All models", and the official UI shows a plain countdown to it.
   The 9-hour figure was this week's window nearing its end, not a rolling edge. A
   countdown label is safe.

2. **Do ClawBar's own polls anchor a 5h window?** Still open, and still drives the whole
   poll policy. Confirm by watching whether `5h-reset` advances during a period of pure
   idle heartbeat with no Claude Code use.

3. **Does a genuine plan-limit rejection also return a bare 429?** The observed 429s were
   model gating. If quota exhaustion behaves the same, the app must survive on cached
   state at the limit. Assume yes until observed otherwise — it is the safe assumption.

### Timestamps as decoded (now = 2026-08-05 09:41 UTC)

```
5h-reset       2026-08-05 12:00:00 UTC   in 2h 18m
7d-reset       2026-08-05 19:00:00 UTC   in 9h 18m    <- not 7 days
overage-reset  2026-08-05 09:40:00 UTC   current minute, rolls continuously
```

---

## Rejected local source

`~/.claude/stats-cache.json` holds only `messageCount` / `sessionCount` / `toolCallCount`
by date, and its `lastComputedDate` was ~6 months stale. No quota data.
