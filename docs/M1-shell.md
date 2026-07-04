# M1 — Shell (PRD §4.1, D2a v2)

**Status: built and machine-verified (4 July 2026). Done-gate pending: the owner
completes a full normal workday in it.**

## What's in

- **Sidebar-first chrome per D2a:** left rail (workspace header with teal dot →
  "Search or go to…" → vertical tabs with per-domain letter chips → Downloads at the
  foot), page as the stage in a rounded, hairline-bordered card on warm canvas.
  Applications grid and dormant workspaces appear in later milestones (M5/M2) —
  the sections are absent, not empty, per the calm rule.
- **Design tokens** (`Tokens.swift`): canvas `#FBFAF8`, well `#F3F1EC`, ink `#21201C`,
  still-water teal `#267D7D` light / `#63B5B4` dark (sRGB projections of the package's
  OKLCH values). Instrument Sans bundled and registered locally — zero network fonts.
  Light mode forced app-wide (PRD §8.1).
- **Header readout as security surface:**
  - registrable domain in full ink, path in faint ink; ID-shaped/long paths (> 40 chars,
    digit/hex runs, %-encoding) replaced by the page title. eTLD+1 via a pragmatic
    multi-part-suffix list, not a full PSL.
  - **No padlock on secure pages** (PRD §8.6) — only negative states get marked.
  - Plain HTTP / mixed content: domain in warning ochre + "Not private" chip; clicking
    the chip explains in plain sentences. Verified live against http://example.com.
  - TLS/cert failures: full-stage interstitial in product voice, one "Go back" action,
    deliberately **no** proceed-anyway. Verified live against https://expired.badssl.com.
  - Homoglyph policy: IDN labels decode to Unicode only when single-script; mixed-script
    lookalikes stay punycode. RFC 3492 decoder + coarse script classifier in
    `HostDisplay.swift`, covered by `--selftest`.
- **⌘L / readout click:** go-to overlay pre-filled with the full URL, selected
  (AppKit-backed field to guarantee the selection contract). Becomes the palette's
  go-to mode in M6.
- **Tabs:** new (⌘T, focuses the rail field), close (⌘W, opener-aware selection return),
  drag-reorder in the rail, popup tabs open beside their opener (OAuth flows that
  window.close() hand selection back). Session restore on launch.
- **Downloads:** non-renderable responses become WKDownloads into ~/Downloads
  (Finder-style unique naming), listed at the rail foot with progress; click reveals
  in Finder. Verified with a live 1 MB fetch.
- **`Sill --selftest`:** headless checks for punycode/homoglyph, registrable domain,
  path-or-title rule, and address parsing. Exits non-zero on failure; M4's detector
  harness will extend it.

## Deliberate M1 shortcuts (not defects)

- Workspace switcher is a stub popover ("Workspaces arrive with M2").
- Blank tab shows quiet paper, not Home — D2b Home is M5's.
- Search fallback is Google; palette search-grouping lands in M6.
- No favicon fetching, ever (PRD §3.2) — letter chips are the design's own answer.

## Owner checks for the M1 gate

1. Work a full day in it. Logins persist (M0 already proved), session restores.
2. ⌘L from anywhere — including while a page has focus — must open the go-to overlay
   with the URL selected. If a site swallows it, that's an M1 defect: report it.
3. Drag tabs to reorder; close/reopen; downloads land and reveal.
4. Log every friction moment mentally (the formal annoyance counter arrives in M6).
