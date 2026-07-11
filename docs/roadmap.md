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

Built 2026-07-11, unreleased: heads-up favorites (Gmail unread badge on the
favorite chip, upcoming-meeting card in the rail with click-through to the
event — read from the user's own signed-in pages, opt-in via Settings), and
always-loaded favorites (every favorite's shared tab materializes at launch
and stays alive — Dock model, instant selection; favoriting a live tab now
adopts it in place).

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

From the 2026-07-11 streamer-needs triage (asks common among streamers,
weighed the usual way — none touch the learning engine, so none are gated on
the "who is Sill for" memo; they're shell features that also serve any
screensharing or single-monitor user):

- **"On Air" mode (streaming-safe privacy).** The strongest fit of the
  batch: streamers fear leaking personal context on stream, and Sill is
  unusually well placed because *every* personal surface is local and
  enumerable — we can actually guarantee coverage where Chrome can't say
  what autofill might volunteer. One manual toggle (palette command + menu
  item, obvious "on air" indicator) that suppresses, for the session:
  Home's greeting/Recent/suggestion cards, the palette's history and
  bookmark groups (typed URLs and search still work), heads-up badges and
  the meeting card, the downloads popover, and transient toasts. Manual
  only — auto-detecting screen capture is surveillance-adjacent and stays
  out. Medium effort.
- **Per-tab mute + audio indicator.** Mute one tab (a VOD, a second
  stream) without silencing the app. WebKit only exposes this via private
  API (`_setPageMuted:`, `_isPlayingAudio` for the rail's speaker glyph) —
  same guarded, `responds(to:)`-checked risk tier as the Inspector,
  developer-extras, and context-menu SPI already shipped; degrades to the
  item simply not appearing. Autoplay-off (shipped) already prevents
  *surprise* audio; this covers deliberately playing media. Small effort.
- **Floating Quick Look (always-on-top pop-out player).** Single-monitor
  streamers want chat/reference video floating over a game. Quick Look
  *is* Sill's pop-out window already — add a "Float on Top" toggle
  (`NSWindow.level = .floating`, public API, remember the choice per
  window) and it covers the ask. Small effort. True picture-in-picture
  (video-only, chromeless) has no public WKWebView path on macOS; note it
  as a possible deeper slice only if floating Quick Look proves
  insufficient in real use.
- **Idle-tab auto-hibernation.** Our honest formulation of the "RAM/CPU
  caps" ask (caps themselves declined below): hibernation is Sill's
  existing answer to browser weight, but today it only fires on workspace
  switch. Dehydrating ordinary background tabs after N idle minutes
  (favorites exempt — always-loaded by design; pinned and audible tabs
  likely exempt too) would keep Sill light *within* a workspace during a
  long gaming/streaming session, using machinery that already exists.
  Small-to-medium effort; needs a think about restore friction before
  building (scroll/URL snapshots already make restores cheap).

## Considered and declined

Community asks weighed against Sill's identity (local-first, deterministic,
no LLM, consent-first, WebKit). Recorded so they aren't relitigated.

From the 2026-07-10 community-feedback triage:

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

From the 2026-07-11 streamer-needs triage:

- **Hard CPU/RAM caps ("resource limiters", Opera GX's headline)** — not
  buildable honestly on WebKit: embedders get no per-page CPU or memory
  budget API (Safari's own throttling is WebKit-internal), so a "limiter"
  UI would be theatre. Sill's real answer is hibernation — dormant tabs
  release their whole WebContent process, which is more than a cap ever
  delivers — and the shippable slice of this ask is the idle-tab
  auto-hibernation item under Proposed.
- **Blocking pre-roll/mid-roll video ads (Twitch/YouTube)** — the display
  and tracker-network layer is already shipped (EasyList adservers content
  blocker, 42.5k domains). But stream-embedded ads are increasingly
  stitched into the video server-side, where no declarative content
  blocker can reach; the extensions that manage it live in a weekly
  player-patching arms race that contradicts calm-and-deterministic and
  would break constantly under WebKit's rule model. Decline the promise
  rather than half-keep it; revisit only if WebKit's content-blocker
  surface materially changes.
- **"Metal-rendered" hardware-accelerated video pop-outs** — the premise
  is wrong: WKWebView video already decodes on the media engine
  (VideoToolbox) and composites on the GPU; a bespoke Metal pipeline
  wouldn't remove CPU cost that isn't there. The honest kernel — a
  genuinely chromeless, near-zero-overhead floating player — would mean
  a native AVPlayer window fed by the stream's raw HLS URL, i.e. building
  and maintaining a custom Twitch client (token handshakes, ad
  stitching, API churn) inside a browser: a separate product, and a
  fragile one. The shippable slice is the floating always-on-top Quick
  Look window already under Proposed, which inherits WebKit's existing
  hardware path for free.
- **Clipboard-to-Twitch-chat macro (global shortcut posts links to chat)**
  — declined on two hard constraints at once: Sill makes zero network
  calls of its own, and posting to Twitch's chat API on the user's behalf
  is exactly that (plus automated actions in the user's name, which the
  observation posture has always ruled out); and a global clipboard
  interceptor is the kind of quiet surveillance Sill exists to reject.
  If the H6 MCP layer lands, an external, user-run agent could do this
  itself with Sill merely exposing page context, logged on the Learning
  page — the right shape for any "act on my behalf" ask.

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
