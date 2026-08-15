# Backlog

Known gaps and open questions. Deliberate omissions are listed too, with the reasoning —
a backlog that only records intentions gets the same idea proposed twice a year.

---

## Small fixes

**A stray 500×500 offscreen window belongs to the process.** Noticed while checking window
layering; harmless and never on screen, but unexplained. Suspect an artefact of forcing
SwiftUI layout before the real window exists.

---

## Open questions

**What does `anthropic-ratelimit-unified-representative-claim` mean?** It read `five_hour`
in all 110 logged samples, including 52 where the weekly window was the more consumed of
the two — so it is not "the binding limit", which is what a badge was once built on. Still
parsed and written to the usage log in case a longer record clarifies it. Nothing in the
UI depends on it.

**Does a genuine plan-limit rejection return a bare 429?** Every 429 observed so far was
model gating, and carried no rate-limit headers at all. If quota exhaustion behaves the
same, ClawBar goes blind exactly when it matters most. The `limited` state already assumes
so and survives on cached values — but the assumption has never been tested against a real
exhausted window.

---

## Deliberately not done

**No per-model limits.** Claude's own Usage panel shows a separate weekly meter per model
(e.g. Fable). No header exposes it, and requesting a different model does not produce one.

**Pinned to `claude-haiku-4-5-20251001`.** Every other model returns 429 with a
subscription token, verified across eight. If that model is retired or gated the same way,
the data source stops. Mitigation is detection, not avoidance — the model id is a single
named constant.

**ClawBar does not install Claude Code for you.** It detects it and offers the right
command. Installing would require assuming a package manager that a Claude Desktop-only
user may not have, and turning a usage meter into a software installer is a trust
escalation it does not earn.

---

## Nice to have

**An issue template geared to header breakage.** The likeliest failure is Anthropic
changing the undocumented headers, and the most useful thing a reporter can provide is the
raw header dump plus `--projection` output. Without a template that becomes three rounds
of follow-up questions.

**A styled DMG.** Currently plain `hdiutil`. Siloquy uses `create-dmg` for background art
and icon positions; that needs a Homebrew formula installed.

**Verify the first run on a machine without Claude Code.** The Desktop-only onboarding was
checked by rendering it offscreen with `CLAWBAR_FAKE_NO_CLAUDE=1`, not by living through
it on a clean machine.
