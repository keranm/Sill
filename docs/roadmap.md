# Sill — roadmap

**Status: 2026-07-07.** Sill is a real, if still early, macOS browser — not
disposable PoC code. `docs/archive/Sill-PoC-PRD.md` and
`docs/archive/Sill-PoC-Evolution.md` are kept as the historical record of how
it got here (the five/six hypotheses, the milestone structure, the design
deviations) but are no longer being updated. This doc is the live one: what's
shipped, what's next, pulled forward from whichever parts of those two docs
never got built.

Shipped: shell, workspaces + hibernation, consent + cross-browser history
import, the deterministic learning engine, suggestion cards + Learning page,
command palette, DevTools (Inspector, page capture, API Client, JSON
formatting), Quick Look, Pinned Tabs, Favorites, Glance, Panel view,
drag-and-drop tab management. Bundle id is `app.sill`.

---

## Next up

- **Sense-check the concept for real.** The original PRD's H1–H5 (and the
  Evolution doc's H6) were never formally graded — daily-drive Sill for a
  real stretch and grade them against the decision gates in
  `docs/archive/Sill-PoC-PRD.md` §7. This is the thing everything else here
  is downstream of: whether Sill graduates into "build this out" territory
  or a hypothesis quietly fails is evidence, not a vibe.
- **Apple default-browser entitlement.** Tracked in `docs/7-day-polish.md`
  §1 — sent (or about to be), long turnaround expected. Downloads and Web
  Inspector's long-term reliability both hinge partly on the outcome.

## Proposed, not built

- **MCP layer (H6 — agent legibility).** `docs/archive/Sill-PoC-Evolution.md`
  §4.10 spec's an external MCP server: read tools only (current tab/workspace
  state, `capture_page`, `describe_active_context`) plus one narrow write
  path (fire a request through the API Client), with every call logged to
  the Learning page under an "Agent activity" heading, in the same voice as
  the browser's own observations. Page capture itself (the toolbar feature)
  already shipped — the MCP server that would expose it to an external agent
  has not. Fully unbuilt; untouched since it was proposed.
- **Dark mode.** Deliberately deferred (light-mode-first was the PoC's
  explicit simplification, not an oversight) — tokens were built with dark
  values mirrored in from day one specifically so this is cheap whenever it
  gets picked up.
- **Workspaces evolving around agents (post-H6 direction).** If the MCP
  layer lands and H6 holds, `docs/archive/Sill-PoC-Evolution.md` §10 sketches
  the next organizing question: not "does the browser notice useful things"
  but "does the browser let an agent act on what it notices, legibly and on
  the user's terms" — scoped to a single observed workspace routine ("handle
  the Mornings routine") rather than open-ended browser control. Nothing
  beyond H6 is scoped yet; this is direction, not a spec.

## Accepted gaps (revisit only on new evidence)

- **No extensions** → no in-shell 1Password/Bitwarden. Mitigated today by
  the "that was annoying" friction counter; only worth building if that
  counter shows it's the thing actually breaking daily use.
- **Chromium escape hatch.** WebKit is the engine by choice, not marriage —
  if `engine`-tagged friction stings ever show WebKit itself is the reason
  daily use struggles, `docs/archive/Sill-PoC-PRD.md` §7's engine gate is the
  documented off-ramp. Not a plan in motion.
- **No DRM, no Windows/Linux, no sync, no notifications** — out of scope by
  original design-package decision, not revisited unless the product's shape
  changes enough to reopen it.
