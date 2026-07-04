# M2 — Workspaces, hibernation, benchmark (PRD §4.2)

**Status: built and machine-verified (4 July 2026). Hibernation works; the
official H4 numbers still need a clean measurement run (below).**

## What's in

- **Workspaces are first-class:** create (⌘⇧N or the switcher's "New workspace…"
  row — inline naming, no modal), switch via the rail popover per D2a (active row
  with teal dot and tab count; dormant rows faint with "n tabs resting"), rename
  and delete via context menu. Deleting folds tabs back into Everything else.
- **"Everything else" is a real, ordinary workspace:** exists from first launch as
  the unnamed initial context, becomes *visible* the moment the first user workspace
  is created (PRD §8's one-label-one-rule reading). Renameable; undeletable.
- **Full hibernation:** switching away captures each tab's scroll position, then
  deallocates every WKWebView in the departing workspace — the WebContent processes
  die, which is where the memory actually goes. URL/title/scroll snapshots are in
  SQLite (`~/Library/Application Support/Sill/sill.sqlite`, inspectable with any
  SQLite client). Switch-back rebuilds the rail instantly from snapshots, shows
  "{Name}, as you left it — n tabs", and rematerializes the selected tab; other
  tabs restore lazily on first click (keeps the win from being given back).
- **Scroll restore:** applied after the next load finishes.
- **Dormant workspaces sit at the rail foot** as faint facts — name + resting tab
  count, no badges, click to switch.
- **Persistence moved from UserDefaults to SQLite** (workspace, tab_snapshot,
  app_state tables; WAL, synchronous FULL). One-time migration from the M1
  UserDefaults session runs automatically on first M2 launch.
- **Benchmark harness:** `Sill --benchmark-seed` loads 40 defined tabs across 4
  workspaces (plan printable via `--print-benchmark-plan`) against a throwaway
  database, hibernates 3 by ordinary switching, then touches
  `/tmp/sill-benchmark-ready`. `scripts/benchmark.sh {sill|chrome|arc|measure-*}`
  drives all three browsers with identical tabs and sums RSS.

## Benchmark method (H4) — run when the machine is quiet

1. Quit Safari and any WebKit-heavy apps (Sill's content processes are named
   `com.apple.WebKit.*`; attribution is by name, so other WebKit apps pollute).
   Quit your daily Sill instance too.
2. `./scripts/benchmark.sh sill` — loads, hibernates, settles, prints the number.
3. Quit Sill. `./scripts/benchmark.sh chrome`, wait ~2 min, `measure-chrome`. Quit.
4. Same for Arc.
5. Record all three in this file, flattering or not. To separate the hibernation
   effect from the WebKit-vs-Chromium engine advantage (PRD §1 H4), also measure
   Sill with all 4 workspaces active (switch through them and back without
   settling — or note the number the harness prints before its final switch).

A functional run on 4 July (owner's session + Safari running, numbers therefore
meaningless) confirmed the mechanics: 40 tabs loaded in ~35 s, 3 workspaces
hibernated, dormant rows correct, restore-with-scroll verified by hand.

## Known M2 seams

- The benchmark's "Everything else" shows a stray blank tab or two (the tab each
  empty workspace is born with) — cosmetic, benchmark DB only.
- Scroll restore is a JS `window.scrollTo` after load — SPAs that restore their own
  position may fight it; watch during daily driving.
- At quit, scroll positions of the *active* workspace aren't captured (no async at
  termination); URLs/titles are. Hibernated workspaces keep theirs.
