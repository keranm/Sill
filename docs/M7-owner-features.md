# M7 additions — owner-requested, post-milestone (PRD calls for no more code
# during the sense-check fortnight "unless bugs surface during daily use";
# these are deliberate scope decisions by the owner, not bug fixes)

**Status: built, self-test green, released v0.1.5–v0.1.7.**

Arc-inspired (`resources.arc.net`), each adapted to Sill's actual
architecture rather than ported directly — see `docs/dia-sill-comparison.md`
for the broader philosophy this sits inside.

## Frameless window (v0.1.5)

`.windowStyle(.hiddenTitleBar)` + a `WindowConfigurator` (NSViewRepresentable
setting `titlebarAppearsTransparent`, hidden title, `fullSizeContentView`)
merges the title bar into the content — traffic lights float over the rail
instead of a separate gray bar. `ShellView` opts out of the automatic
safe-area inset that comes with it (`.ignoresSafeArea(.container, edges:
.top)`) so there's one controlled source of top clearance, not two stacking.

## Quick Look (v0.1.6) — `QuickLookWindow.swift`

Inspired by Arc's **Little Arc**: a real detached `NSWindow`
(`WindowGroup(for: QuickLookRequest.self)`, keyed by a fresh UUID per request
so repeats always open a new window) for a one-off lookup that never touches
a workspace unless promoted. Triggers: `⌘⌥N` (blank lookup), `⌘⌥`+click a rail
tab (peek its current URL without disturbing the real tab). "Open in
[workspace]" adopts the tab into a real workspace, preserving its live
session rather than reloading.

**Bug found and fixed**: promoting adopted the tab into a workspace, then
dismissing the window unconditionally dehydrated it in `.onDisappear` —
tearing down the webview that had just been adopted, worst when promoting
into the *already-active* workspace (where `switchWorkspace`'s guard makes it
a no-op and nothing re-materializes the tab). Fixed with a `promoted` flag
that skips the dehydrate.

## Pinned Tabs (v0.1.7) — `BrowserTab.isPinned`/`pinnedURL`, `TabStore`

Tabs that stick around per workspace, never auto-archive, shown in their own
section above the regular list (no drag-reorder yet — separate scope).
`BrowserTab.pinnedHomeDomain` anchors a pinned tab to its registrable domain;
an outbound link to a different domain doesn't replace the pinned page (see
Glance, below). Right-click: Pin/Unpin/Reset Tab (back to the URL it was
pinned at). `moveTabs` had to be rewritten to splice the reordered unpinned
list back against the full underlying array — pinned tabs render in a
separate section now, so drag indices from the filtered list no longer map
onto `workspace.tabs` directly.

## Favorites (v0.1.7) — `Favorite.swift`, `TabStore.favorites`

"Pinned Tabs accessible in every Space" (Arc's framing, kept almost
verbatim) — a small global list (own DB table, capped at 15), independent of
any workspace, shown as a 3-wide icon grid above the workspace switcher.
`⌘1`–`⌘9` jump straight to one. `openFavorite` acts like a Dock icon: focuses
an already-open tab anchored to that domain in the current workspace, or
opens one fresh (pinned, so it inherits Glance's domain-anchoring for free).
Favoriting **converts** the source tab — it disappears from the list as the
favorite appears, not a duplicate (`addFavorite` closes `sourceTab` once
favicon discovery completes, ordered to avoid racing the JS evaluation
against tearing down the webview).

**Found while building**: favorite-backed tabs were also matching the
`isPinned` filter, so they showed twice — once as the favorite chip, once as
a redundant pinned-tab row. `pinnedTabs` now excludes any tab whose
`pinnedHomeDomain` matches an existing Favorite; the chip itself gained the
selected-state highlight and the Reset/Remove actions that row would have
carried.

## Glance (v0.1.7) — `GlanceView.swift`

Arc calls this **Peek** — deliberately renamed to avoid confusion with Apple's
own Quick Look/Peek conventions. A lightweight overlay *inside* the current
window (dimmed backdrop, click-outside to dismiss) — not a separate OS
window, which is what Quick Look is for. Triggered when a link inside a
Pinned/Favorited tab points outside its home domain, checked in **two**
WebKit delegate paths: `decidePolicyFor navigationAction` (same-tab
navigation) and `createWebViewWith` (target="_blank"/`window.open` popups —
Gmail's "View Order" links go this route, and initially bypassed Glance
entirely because only the first path was checked).

State lives on `TabStore.glanceURL` rather than view-local `@State`, so the
global `⌘W` command can check it first and dismiss the overlay instead of
closing a tab in the main window — sidesteps relying on uncertain SwiftUI/
AppKit shortcut-precedence between a local `Button.keyboardShortcut` and an
app-wide `.commands` menu shortcut for the same key.

**Bugs found and fixed**:
1. Same adopt-then-dehydrate race as Quick Look's promote (see above) — same
   `expanded` flag fix.
2. Gmail wraps external links as `google.com/url?q=<real destination>` for
   click-tracking. The first navigation hop reads as `google.com` — the same
   registrable domain as the pinned Gmail tab's home domain — so the
   domain-mismatch check missed it entirely. `WebKitDelegate` now resolves
   that specific redirect-wrapper pattern (extracts `q=`) before comparing
   domains, in both delegate methods via a shared `glanceDestination(for:from:)`
   helper.
3. The overlay's buttons showed an I-beam cursor on hover — the pinned tab's
   own `WKWebView` underneath still owns native AppKit cursor-rects for
   whatever's on the actual page at that screen position, and a SwiftUI
   overlay drawn on top doesn't automatically override that. Fixed with an
   `arrowCursor()` view helper (`NSCursor.arrow.push()`/`.pop()` on hover).

No Split View button: Sill has no split-view feature to drop into. Flagged,
not built — see `docs/dia-sill-comparison.md`.

## Real favicons — `FaviconStore.swift`, `Glyph.swift`

**A further, explicit PRD §3.2 deviation** ("zero network calls of our
own"), same category as the M3 content-blocker exception — flagged here for
the same reason. Narrowly scoped on the owner's own instruction: fetching
only happens at the moment a tab is **pinned or favorited**, and only that
result is written to disk (`Application Support/Sill/Favicons/`). Every
other materialized tab gets a best-effort, **in-memory-only** fetch on page
load (`WebKitDelegate.didFinish` → `FaviconStore.requestEphemeral`) — never
persisted, refetched fresh next launch if the domain isn't already cached
from a pin/favorite elsewhere. `GlyphView` (shared by tab rows, Pinned Tabs,
and the Favorites grid) checks the disk-then-memory cache and falls back to
the original letter chip on any miss — a failed or pending fetch is never
visible as an error state, just the chip.

## Owner action

None required — these shipped via the normal Sparkle auto-update path
(v0.1.5 → v0.1.7). Worth exercising Pinned Tabs + Favorites + Glance daily
alongside the M7 sense-check itself, since they're new enough surface to
plausibly hide another bug like the three found while building them.
