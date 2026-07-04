# M6 — Command palette + instrumentation (PRD §4.8, §4.9)

**Status: built, self-test green.**

## Command palette — `PaletteOverlay.swift`

⌘K from anywhere; ⌘L opens the same surface in go-to mode (URL pre-filled,
selected — replaces the interim `GoToOverlay` from M1). Groups exactly per
D2e: GO TO, ACTIONS, WORKSPACES, APPLICATIONS, HISTORY (queried live from the
event ledger), BOOKMARKS (from the M3 import), SEARCH fallback. ↑↓ to move,
↵ to open, ⌘↵ to open in a new tab. No learning behaviour in the PoC — plain
substring matching only, exactly as specified.

## Instrumentation — `ObservationStore.exportAggregate`, `HeaderView`

- **Local-only metrics** (`metric` table): `cards_surfaced/confirmed/dismissed`,
  `surprised` (H2 proxy from the naming form's checkbox), `active_days` (H5
  proxy, ticked once per calendar day on launch), `annoyance_{password,engine,other}`.
- **The "that was annoying" counter**: a quiet hand-icon in the header, next
  to reload. One tap, three tags, gone in under a second — a diary, not a
  feature. Expected customers per the PRD: the password-manager gap and
  Chrome-first sites.
- **Export** (Learning menu → Export Aggregate Metrics…): `NSSavePanel`,
  explicit action only. Contains counts, day-spans, and derived rates —
  `h1_precision` (confirmed / (confirmed+dismissed)), `days_to_first_card` —
  never a URL, title, or individual timestamp. Safe to post publicly, per spec.
- **Demo-seed flag** (M4/M5) already exercises the full flow on a clean
  profile; unchanged here.

## Bug found and fixed while wiring the demo-seed confirm flow

**The owner's real Safari import surfaced a genuine defect**: a confirmed
"weekday lunchtime" sequence pattern (`google.com → home-assistant.io`) built
its workspace by guessing `https://home-assistant.io/` for every domain in the
pattern, rather than reading the actual visited URL. For a self-hosted service
reached at a different host (their case: three distinct real hosts across
different visits — `home-assistant.io` the public project site,
`homeassistant.local` and `192.168.0.10` for their own instance), the guess
opens the wrong destination outright, and even for an ordinary public site it
silently drops the real path.

Root-caused and fixed:

1. **`event.scheme` column added** (migrated in `ObservationStore.migrateColumns`).
   Nothing recorded http vs https before this; a confirmed pattern could not
   have opened a plain-HTTP LAN dashboard correctly even with the right host.
2. **`ObservationStore.mostVisitedURL(forDomain:)`** — the most frequent
   (path, scheme) pair on file for a domain, tie-broken by recency. This
   replaces every `URL(string: "https://\(domain)/")` guess in the codebase:
   `PatternStore.confirm` (workspace birth), the confirmed-Applications row
   and RECENT list on Home, and the palette's Applications/History groups.
3. **`DisplayNames.observationDomain` generalised**: previously only a
   hardcoded allowlist of Google/Microsoft app subdomains kept their own
   identity instead of collapsing to eTLD+1 (a deviation introduced in M5 to
   make "Mail, then Calendar" evidenceable). That allowlist doesn't scale to
   arbitrary self-hosted setups. The rule is now general: keep the host as
   observed, strip only cosmetic mirror prefixes (`www.`, `m.`, `amp.`).
   **This is a further deliberate deviation from PRD §3.1's literal
   "registrable domain" field** — flagged here explicitly, same as the M5
   precedent, because a shared registrable domain routinely fronts several
   meaningfully distinct destinations (Google's app family, or someone's own
   domain hosting several self-hosted services), and collapsing them loses
   exactly the distinction both detection and workspace-building need.
   Exclusion checks (§3.3) were re-verified to still operate on the true
   registrable domain regardless of what gets stored, so a bank subdomain is
   still caught even though its full host is what's now on file.
4. **A second, independent bug found in the same code path**: newly birthed
   workspaces only persisted their first (materialized) tab immediately;
   the rest relied on a *later* switch-away to ever reach disk, so a quit in
   between could silently lose them. `switchWorkspace` now snapshots the
   arriving workspace's tabs immediately, not just the departing one.

All four points are covered by new `--selftest` assertions (domain-identity
preservation, real URL/scheme/path readback, exclusion still catching a
subdomain of an excluded registrable domain).

**Owner action:** re-run the Safari import (Learning menu) so existing rows
pick up `scheme`; previously-confirmed patterns whose workspace no longer
exists can simply be re-confirmed once re-detected.
