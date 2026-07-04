# M3 — Consent, observation, history import (PRD §4.4, §3)

**Status: built and machine-verified (4 July 2026). Owner gates remaining:
grant Sill Full Disk Access and run the Safari import; confirm the timing.**

## What's in

- **Consent screen (D2f, verbatim, under 60 words)** on first run. "Not now"
  keeps observation off; the browser works fully either way. Okay opens the
  import sheet. Decision stored in `app_state`; revisitable from the Learning
  page when M5 builds it.
- **Observation events** (consent-gated, pausable): metadata only per §3.1 —
  registrable domain, path (query/fragment never stored), title truncated to
  120, timestamps, tab open/close/switch + workspace switches, transition type
  (`typed` from our go-to fields, else mapped from WKNavigationType), workspace
  id, session id (25-minute gap rule), and the open-tab domain set per visit
  (feeds M4's co-occurrence detector). One `event` table in the same SQLite file.
- **Sensitive-domain exclusion, on by default** (§3.3): curated bank/health
  lists (AU-weighted), `.gov`/`.nhs.uk`-style suffixes, adult + "bank" keyword
  rules — deliberately over-broad, excluding too much is the safe failure.
  User-added exclusions scrub any existing rows for that domain. Applied in
  `recordVisit` and during import: an excluded visit never becomes a row, a
  count, or a hash.
- **History import** (the cold-start killer): Safari, Chrome, Arc,
  Firefox/Zen readers — copy-then-open read-only, WAL sidecars included, time
  epochs normalised (Core Data / 1601-µs / unix-µs), transitions mapped,
  `source: import:<browser>`, re-import replaces rather than duplicates. All
  inside one transaction: the 18-visit Chrome fixture lands in 0.00 s; the
  math holds for ~100 k Safari rows well inside the minute budget.
- **Safari needs Full Disk Access** — the designed flow (not a bare OS dialog):
  plain-sentence explanation + "Open System Settings" deep link + Try again.
- **Bookmarks import** into a flat, unpromoted `bookmark` table (Safari plist,
  Chromium JSON, Mozilla places) — surfaced via the palette in M6.
- **Learning menu (stopgap until M5's Learning page):** Pause/Resume
  Observation, Import Browsing History…, Delete Everything Learned… (sober
  confirm, workspaces survive — copy per D2d).
- **Content blocker (owner request, out-of-spec addition):** WebKit's
  declarative content-rule engine loaded with an EasyList ad-server snapshot
  (42.5 k domains — including Admiral's randomised anti-adblock fleet), compiled
  once and cached, attached to every webview. Declarative rules, so Sill's own
  code still never reads page content and records nothing from it — §3 intact.
  Refresh: re-run the conversion in git history (easylist_adservers.txt →
  `Resources/Blocklists/easylist-adservers.json`), any Safari-format JSON
  dropped in that folder is picked up.

## Machine-verified (in `--selftest`)

- Undecided consent records nothing; declined records nothing; paused records
  nothing; granted records.
- Excluded visit leaves no row (live and import paths); user exclusion scrubs
  history; delete-everything leaves zero events; nhs.uk-style apex domains
  excluded (regression from this build, caught by the test).
- Real Chrome History file imports through the full pipeline
  (`--selftest --chromium-fixture <path>`).

## Owner gates for M3

1. Answer the consent card (it's live on your screen). Okay → import sheet.
2. Chrome import: instant. Safari: hit Import, follow the Full Disk Access
   explanation (System Settings → Privacy & Security → Full Disk Access → add
   `build/Sill.app`), Try again. Confirm months of history land in under a
   minute.
3. Sanity-check the ledger with any SQLite client:
   `sqlite3 ~/Library/Application\ Support/Sill/sill.sqlite "SELECT count(*), source FROM event GROUP BY source"`
   — and confirm zero rows for a bank you visit.
