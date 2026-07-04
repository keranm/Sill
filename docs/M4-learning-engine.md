# M4 — Learning engine (PRD §4.5)

**Status: built; harness gate PASSED (4 July 2026): 4/4 planted routines found,
1 false positive (gate: ≥3/4, ≤2 FP). Remaining owner gate: import real history,
then review `Sill --run-engine` output together before any card exists.**

## Architecture

Deterministic, no LLM, no mining library (PRD §3.6): n-gram counting and
circular statistics over the `event` ledger, in `LearningEngine.swift`.
Sessions are computed from timestamps (25-minute gap rule) so imported history
sessionizes identically to live browsing. Detected patterns upsert into the
`pattern` table — state (`noticed`/later `suggested`/`dismissed`…) survives
re-runs, because dismissals must be honoured forever. Runs 10 s after launch
and every 12 h thereafter, only while observing.

## Detectors and thresholds (floors — tune upward only)

- **Sequences** (ordered domain runs, length 2–5, within sessions): settled at
  ≥5 occurrences across ≥3 days; grams made entirely of the global top-5
  domains are noise; shorter grams are dropped when a longer gram with
  comparable support subsumes them; consecutive repeats collapse; no A>B>A.
- **Rituals** (consistent time-of-day, with day-of-week conditioning): groups
  = daily / weekdays / weekend / each weekday. Multi-day groups: ≥10 visits
  over ≥6 days in 30, circular resultant ≥0.7. Single-day groups (Sunday
  evenings can only happen ~4×/month): present on all-but-one possible day,
  ≥1.5 visits per occurrence, resultant ≥0.62. A settled sequence subsumes
  member rituals in the same window — one habit, one pattern.
- **Co-occurrence** (tab-set snapshots ride live visit events): pairs
  co-present on ≥60% of snapshot-active days spanning 2+ weeks, clustered by
  connected components. Domains in >85% of snapshots are ambient (the pinned
  inbox) and never pair. Live data only — imports carry no tab sets.
- **Application promotion**: visited on ≥18 of 30 days with typed-address
  share ≥40%.
- **Confidence staging**: every detector emits settled or settling; only
  settled patterns may generate suggestions (M5); settling appears on the
  Learning page as "recent, still settling".

## Cost accountant (D3, load-bearing)

`CostAccountant` produces every evidence line: "about a dozen", "the past
three weeks", "Most Sundays for the past month" — aggressive rounding, no raw
counts, no timestamps. The selftest asserts an evidence line can never carry
its raw count.

## Harness (PRD §4.9: the seed generator *is* the test)

`DemoSeed.generateVisits` builds a deterministic 30-day synthetic history
(SplitMix64, seed 42): four planted routines — weekday-morning
Mail→Calendar→Figma, Sunday-evening allrecipes, a Linear/GitHub/staging
co-occurrence cluster, typed-daily notion.so — plus ~35 noise domains and five
heavy hitters that own the top-5 slots. `--selftest` asserts ≥3/4 found and
≤2 false positives; currently 4/4 and 1 (a chance-but-genuine lunchtime
cluster the generator produced — the honest kind).

Tuning history: initial run 4/4 with 2 FPs → tightened single-day rituals
(repeat engagement per occurrence) and multi-day resultant 0.55→0.7; a top-5
exclusion briefly applied to rituals/promotions cost the planted promotion its
detection and was rolled back to sequences only, where the PRD put it.

## Dev flags

- `Sill --run-engine` — run detectors against the real ledger, print raw
  patterns (the M4 review step; no cards exist yet).
- `Sill --demo-seed` — separate `sill-demo.sqlite` (wiped each launch, never
  mixed with real data), seeded and analysed at startup: M5's end-to-end
  card→confirm→workspace sense-check rig.

## Owner gate

1. Import Safari history (Learning menu → Import Browsing History…; needs the
   Full Disk Access grant).
2. `.build/release/Sill --run-engine` — we review the raw output together
   before any card exists. Expect noise on first contact with real data;
   thresholds only ever move up.
