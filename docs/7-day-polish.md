# 7-day polish push

**Status: proposed, 2026-07-07 — not started.**

The owner's framing: "if we can get another 7 days of development and
polish, move away from POC terminology... push on Apple to see if we can get
that entitlement." This is the punch list for that push — the last lap
before Sill stops being described as disposable code and starts being
described as a real (if still small) product.

Not a schedule. A checklist to work through and cross off; re-prioritize
freely as real usage during the week surfaces anything sharper than what's
listed here.

---

## 1. The long pole: the entitlement request

Everything else on this list is ours to fix. This one isn't — it's an email
to Apple, and historically a slow, opaque process even for solo developers.
Send it first so the clock is running while the rest of this list gets worked.

- [ ] Send `docs/apple-default-browser-request-draft.md` to
      `default-browser-requests@apple.com`, filled in with Team ID
      (`AUEPCDGA5G`) and the **new** bundle id (`app.sill`, not the old
      `app.sill.poc` — the rename shipped in v0.1.12 specifically so the
      request goes out under the identity we intend to keep).
- [ ] Once (if) granted: re-test Web Inspector's long-term reliability
      (Downloads turned out not to depend on it — see §2, resolved
      2026-07-07 — but the private Inspector API's future behavior is
      still an open question the entitlement might bear on).

## 2. Downloads — resolved 2026-07-07, was never actually an entitlement issue

The original report (2026-07-06) bundled three symptoms together as one
"downloads are broken": a linked file, an image, and Sill's own zip from
keranmckenzie.com all silently no-op'd. Live investigation this session
split that into two genuinely different things:

- **Direct/navigation-triggered downloads** (clicking a real download
  link/button, e.g. Chrome's `.dmg`, Sill's own zip) — turned out to
  already work fine. `WebKitDelegate`'s `decidePolicyFor
  navigationAction/navigationResponse` → `didBecome download:` →
  `DownloadsStore.adopt` path was never actually broken.
- **Right-click "Download Linked File" / "Download Image"** — this was
  the real, reproducible bug. Root cause: WebKit puts these items in its
  default context menu unconditionally, but never wires them to an actual
  download for a third-party host app — true regardless of code signing,
  Hardened Runtime, or the `com.apple.developer.web-browser` entitlement.
  Confirmed by building and testing a version signed identically to the
  shipped app (same Developer ID cert, same Hardened Runtime, same
  entitlements) with no fix: still silently no-op'd, ruling the
  entitlement out as the cause of this half of the bug.

**Fixed** in `WebKitDelegate.swift`: implements the private
`_webView:getContextMenuFromProposedMenu:forElement:userInfo:
completionHandler:` SPI hook (same private-API risk tier as
`DeveloperTools.swift`'s Inspector integration) to read the right-clicked
link/image URL off the hit-test result, then rewires just those two menu
items to call the fully public `WKWebView.startDownload(using:
completionHandler:)`, feeding the resulting `WKDownload` into the same
`DownloadsStore.adopt(_:)` every other download already uses. Verified
live against a build signed identically to production.

## 3. Correctness cleanups deferred from the v0.1.12 review — all fixed 2026-07-07

Found during the pre-ship review, judged real but not urgent enough to
block shipping. Cleared this session.

- [x] **`BrowserTab.isMaterialized`** now returns `true` for `sill://` tabs
      unconditionally, which quietly broke `Workspace.isDormant`'s
      documented contract ("no live webviews") for any workspace holding an
      API Client tab. Fixed: `isDormant` now checks `webView != nil`
      directly instead of going through `isMaterialized`.
- [x] **Swagger/ReDoc spec detection** (`WebKitDelegate.swift`) ran an
      800ms delay + JS evaluation on *every* non-JSON page load,
      unconditionally. Fixed: a cheap synchronous DOM pre-check
      (`window.ui`/`<redoc>` presence) now runs first, and
      `BrowserTab.detectionTask` is cancelled at the start of every new
      navigation instead of relying solely on the URL-equality guard.
- [x] **API Client environment fields** persisted to SQLite (full table
      delete + reinsert) on every keystroke. Fixed: writes are now
      debounced 500ms in `APIClientStore`, with `environments` (the
      `@Observable` state) as the source of truth in between.

## 4. Known limitations to fix or explicitly accept

- [x] **Web Inspector** uses private, undocumented WKWebView API
      (`_inspector`/`show()`), gated behind `responds(to:)` with a graceful
      fallback alert. Owner's call (2026-07-07): the fallback alert is good
      enough to ship as final — no further caveat needed.

## 5. The terminology and framing decision (owner's call — resolved 2026-07-07)

- [x] **Bundle id:** done — `app.sill.poc` → `app.sill` shipped in v0.1.12.
- [x] **Document terminology:** owner's call — archive the PoC docs as the
      historical record and start fresh. `Sill-PoC-PRD.md` and
      `Sill-PoC-Evolution.md` moved to `docs/archive/` with an archival note
      at the top of each; `docs/roadmap.md` is the new live doc, describing
      Sill as a real (if still early) product and pulling forward whatever
      was proposed in those two docs but never built (chiefly the MCP/H6
      layer and dark mode).

---

## Not on this list

Deliberately excluded — real, but bigger than a polish week:

- Dark mode (Evolution §8, deviation 1 — light-mode-first was a deliberate
  PoC simplification; revisit only alongside the terminology decision above,
  not as a quick add).
- Any new DevTools capability beyond what shipped in v0.1.12 (Network tab,
  Elements-style DOM inspector, etc.) — the current set was scoped
  specifically to "developers coming from Chrome," not to matching Chrome
  DevTools feature-for-feature.
- The MCP layer / H6 (Evolution §4.10) — untouched this session, still
  fully unbuilt.
