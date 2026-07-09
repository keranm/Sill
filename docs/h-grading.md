# H1–H6 grading — 2026-07-10

The M7 sense-check grading, against the decision gates in
`docs/archive/Sill-PoC-PRD.md` §7 (H1–H5) and
`docs/archive/Sill-PoC-Evolution.md` §4.10 (H6). Evidence: the local metrics
ledger (`metric`/`pattern` tables, read 2026-07-10), the owner's direct
answers, and the milestone docs. Graded live with the owner.

| # | Hypothesis | Grade |
|---|-----------|-------|
| H1 | Detection | **PASS** (with a metric caveat) |
| H2 | Revelation | **INCONCLUSIVE** — population mismatch (revised same day from FAIL; see section) |
| H3 | Trust | **PASS** |
| H4 | Lightness | **NOT MEASURED** — benchmark never run |
| H5 | Drivability | **IN PROGRESS** — 7 of 14 days, on track |
| H6 | Agent legibility | **N/A** — MCP layer never built |

## H1 Detection — PASS, with eyes open

Gate: ≥50% of surfaced suggestions confirmed as real.
Ledger: 6 surfaced → 1 confirmed, 3 dismissed, 2 still pending.
Owner testimony: the 3 dismissed cards were **true observations of real
behaviour — just unwanted as workspaces**. So detection accuracy is 4/6
(67%) of surfaced cards real; the literal in-product confirm-click rate is
1/6 (17%).

**Finding inside the finding:** the confirm action conflates "is this
pattern real?" with "do I want a workspace for it?" — the product metric
measures desire, not detection. If a future phase needs the detection
number, the dismissal flow needs a "true, but no thanks" distinction.
The 2 pending cards should be resolved either way; they move this number.

## H2 Revelation — INCONCLUSIVE (population mismatch)

Gate: at least one suggestion genuinely surprises.
Raw result: "mildly interesting only — nothing I didn't already basically
know about myself." The surprised-me checkbox was never ticked in 6 cards;
the verbal answer matches the ledger. Graded FAIL at first pass.

**Revised the same day, on the owner's challenge to the test's validity,
not its result:** the owner no longer works a SaaS-dense job (no
Jira/Confluence/Slack all day, no fixed working hours) — they're a casual
home browser who occasionally works. The PoC's single test subject sits
outside the population whose behaviour holds revelation-grade patterns.

Precision matters here, because the data is subtler than "no patterns to
observe": the engine **did** find real patterns in casual browsing (H1's
4/6 — morning Google→Amazon, lunchtime Mail→News). What casual browsing
produced was patterns that are **real but banal** — visible to their owner
without help, so recognition lands and revelation can't. The learning:

> **The detectors are tuned for SaaS workers with repeatable work
> patterns; for casual/home browsing they surface truths, but not
> discoveries.** Revelation for a casual browser would need different
> detector types (e.g. cost/time-spent insights, drift-over-time) or a
> test subject with a dense work context.

So H2 is neither passed nor failed — it wasn't validly tested. §7's
automatic mapping ("H1 holds + H2 misses → recognition is a feature, not a
product") no longer fires mechanically, but a sharper version of the same
memo is still owed — see below.

## H3 Trust — PASS

Gate: reads as "my data, shown to me", never "something has been watching
me." Owner's answer: exactly the former, no reported unease across ~5 weeks
of consent-granted observation (including a real Safari history import).

## H4 Lightness — NOT MEASURED

Gate: a number, not a vibe. The harness has been ready since M2
(`scripts/benchmark.sh`, method documented in `docs/M2-workspaces.md`), but
the clean run — Safari quit, daily Sill quit, then sill/chrome/arc in
sequence — was never performed, so there are no numbers to grade.
**Action:** run it per the M2 method on a quiet machine; record all three
numbers in `docs/M2-workspaces.md` flattering or not, plus the
all-workspaces-active number that separates hibernation from the engine
advantage.

## H5 Drivability — IN PROGRESS (7/14)

Gate: two consecutive weeks as the real work browser, by choice.
`active_days = 7` (counter born ~Jul 3) and the owner confirms Sill has
been the primary browser by choice that whole stretch. Not gradeable as a
pass until ~**Jul 17**; nothing observed so far argues a fail. The
"annoyance" counter holds no entries, which weakly corroborates
frictionless daily use (or an undiscovered button — both worth knowing).

## H6 Agent legibility — N/A

The MCP server layer (read-only present-moment tools + one API-client
write path, all logged to the Learning page) was proposed in the Evolution
doc and never built. Nothing to grade. It remains the biggest unbuilt
roadmap item and the owner's stated dogfooding interest; a pass/fail here
would be evidence for/against the post-H6 "workspaces evolving around
agents" direction.

## What happens next

1. **The decision memo is still owed, with a sharper question.** Not §7's
   mechanical "recognition is a feature, not a product" — instead: **who is
   Sill for, and what should the engine detect for that person?** Live
   options: (a) accept the audience is casual/home browsers like the owner
   and retune detectors toward what would surprise *them* (cost/time
   insights, drift), (b) hold the SaaS-worker thesis and accept H2 can only
   be graded by a test subject inside that population, (c) let the engine
   stay a quiet workspace-suggester and shift identity toward what's
   demonstrably winning — the calm shell, workspaces, dev tools. No more
   learning-engine code before this memo exists.
2. **Run the H4 benchmark** — the only hypothesis that can still be graded
   with an afternoon's work.
3. **Re-grade H5 on ~Jul 17** — the streak completes itself or it doesn't.
4. H6 stays parked until the memo's identity decision; agents as the
   consumer of observations (instead of suggestion cards) is one of its
   live options.
