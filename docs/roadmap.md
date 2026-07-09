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

Built 2026-07-10, unreleased: collapsible sidebar (⌘S, icons-only rail,
hover flyout), and three quick wins from the community-feedback triage below —
autoplay control (videos wait for a click, `makeConfiguration`); cookie-consent
banner suppression (EasyList Cookie List in `Resources/Blocklists/`, refresh
via `scripts/convert-cookie-list.py`) — **opt-in via Settings, off by default**:
under GDPR the consent prompt is the user's to answer or suppress, not the
browser's; and opt-in local file access (off by default — typed paths/file://,
a bare `file://` opens the open panel, Finder drops on the rail open new tabs).
Both toggles live in Sill's first Settings window (⌘,); the shared posture is
safe-out-of-the-box, the user opts in.

---

## Next up

- **Sense-check: graded 2026-07-10 — see `docs/h-grading.md`.** H1 pass
  (4/6 surfaced patterns real, though only 1 formally confirmed), H2
  **inconclusive** — population mismatch (owner is a casual home browser,
  not the SaaS-dense worker the detectors are tuned for; patterns surfaced
  were real but banal), H3 pass, H4 never measured, H5 in progress (7/14
  days), H6 N/A (unbuilt). Outstanding from the grading: **(a)** a decision
  memo — *who is Sill for, and what should the engine detect for that
  person?* — before any more learning-engine code; **(b)** actually run the
  H4 benchmark per `docs/M2-workspaces.md`; **(c)** re-grade H5 around
  Jul 17 when the 14-day streak completes.
- **Apple entitlements — reframed 2026-07-10** (full detail in
  `docs/7-day-polish.md` §1). The email route auto-bounced to a form, and
  the form revealed: `com.apple.developer.web-browser` is iOS-family only —
  **macOS needs no entitlement to be the default browser** (Sill already
  declares http/https; verify it appears in System Settings). The one ask
  that matters is the macOS-native passkey entitlement,
  `com.apple.developer.web-browser.public-key-credential` — **submitted
  2026-07-10, Request ID `BD9Q6ZFRD9`** (`app.sill` App ID registered in the
  developer account the same day). Waiting on Apple. Downloads and (it turns
  out) default-browser status never depended on any of this.

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

- **Per-site CSS overrides (user styles).** From the 2026-07-10 community
  triage: `WKUserScript`-injected per-domain stylesheets, stored in SQLite,
  a natural fit for the dev-tools identity. Domain identity must use
  `DisplayNames.observationDomain`, not `HostDisplay.registrableDomain`
  (the standing subdomain-collapsing trap). Medium effort, not started.

## Considered and declined (2026-07-10 community-feedback triage)

Community asks weighed against Sill's identity (local-first, deterministic,
no LLM, consent-first, WebKit). Recorded so they aren't relitigated:

- **Enterprise session security / DLP / BYOD / Shadow IT tracking** — wrong
  customer (Island/Citrix enterprise-browser market), and philosophically
  backwards: Sill observes *for the user, with consent, locally*; employee
  monitoring is the same machinery pointed the other way.
- **Chatbot webUI / AI sidebar** — direct no-LLM contradiction; same call as
  `docs/dia-sill-comparison.md`. A chatbot site as a Favorite works today.
- **SVG debugging tools** (mask/clipPath previews, filter stepping) — Web
  Inspector is Apple's compiled UI, not extensible from outside; a bespoke
  SVG debugger is a product in itself. Revisit only if the dev-tools
  direction deepens after H-grading.
- **A standardized "Cookie API"** — a web-standards/gatekeeper play needing
  market share. The shippable slice (consent-banner suppression) shipped in
  the triage's quick wins instead.
- **Bookmark sidebar** — already effectively covered: bookmarks import +
  live palette search + Favorites/Pinned as the curated tier. Revisit only
  if daily use shows palette search isn't enough.
- Also noted: the "seamless context switching / unified workspace
  management" gap named in enterprise-browser research *is* Sill's
  workspaces + hibernation — validation of the core bet, no work item.

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
