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
command palette, DevTools (Inspector, page capture, API Client, MCP Explorer,
JSON formatting), Quick Look, Pinned Tabs, Favorites, Glance, Panel view,
drag-and-drop tab management. Bundle id is `app.sill`.

---

## Next up

- **Sense-check the concept for real.** The original PRD's H1–H5 (and the
  Evolution doc's H6) were never formally graded — daily-drive Sill for a
  real stretch and grade them against the decision gates in
  `docs/archive/Sill-PoC-PRD.md` §7. This is the thing everything else here
  is downstream of: whether Sill graduates into "build this out" territory
  or a hypothesis quietly fails is evidence, not a vibe.
- **Apple entitlement requests.** Tracked in `docs/7-day-polish.md` §1 —
  **not yet sent**, long turnaround expected once it is. Two separate asks
  worth bundling into one email: `com.apple.developer.web-browser` (default-
  browser eligibility; Web Inspector's long-term reliability hinges partly
  on this) and `com.apple.developer.web-browser.public-key-credential`
  (passkeys — see below). Downloads turned out not to depend on either.

## Proposed, not built

- **MCP layer (H6 — agent legibility).** `docs/archive/Sill-PoC-Evolution.md`
  §4.10 spec's an external MCP server: read tools only (current tab/workspace
  state, `capture_page`, `describe_active_context`) plus one narrow write
  path (fire a request through the API Client), with every call logged to
  the Learning page under an "Agent activity" heading, in the same voice as
  the browser's own observations. Page capture itself (the toolbar feature)
  already shipped — the MCP server that would expose it to an external agent
  has not. Fully unbuilt; untouched since it was proposed. (Not to be
  confused with the MCP *Explorer* in the Develop menu, shipped 2026-07-08:
  that's Sill as an MCP client for exploring other people's servers —
  `developer-tools.md` #5. This item is the reverse direction.)
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

- **Passkeys don't work in-shell** (`docs/M0-login-spike.md`). Needs the
  `com.apple.developer.web-browser.public-key-credential` entitlement
  (separate from the default-browser one — see "Next up" above) plus real
  integration work against `ASAuthorizationWebBrowserPublicKeyCredentialManager`
  once granted. Gated on Apple, not started.
- **No in-shell password-manager extension** (no 1Password/Bitwarden
  browser extension, since Sill has no WebExtension host) — **but this
  turned out not to be the gap it looked like**: 1Password's Universal
  Autofill (macOS Accessibility API + global `⌘\`) is browser-agnostic by
  construction and confirmed working in Sill already, live-tested
  2026-07-07, zero code changes. The extension-based integration remains
  genuinely out of reach short of Sill building its own WebExtension
  compatibility layer (what Kagi's Orion did, on the same WebKit engine —
  a large undertaking, not a plugin ask) — but for day-to-day autofill,
  that gap is effectively already closed.
- **Chromium escape hatch.** WebKit is the engine by choice, not marriage —
  if `engine`-tagged friction stings ever show WebKit itself is the reason
  daily use struggles, `docs/archive/Sill-PoC-PRD.md` §7's engine gate is the
  documented off-ramp. Not a plan in motion.
- **No DRM, no Windows/Linux, no sync, no notifications** — out of scope by
  original design-package decision, not revisited unless the product's shape
  changes enough to reopen it.
