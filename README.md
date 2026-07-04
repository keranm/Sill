# Sill

A calm macOS browser proof of concept: it observes how it is used (metadata only,
locally, with consent) and sparingly offers to fold what it notices back into the
interface, chiefly as workspaces.

- **Behaviour spec:** `Sill-PoC-PRD.md` (source of truth for what happens, when)
- **Visual spec:** `Project Browse — Design Package.pdf` (source of truth for everything visual)
- **Stack:** Swift + SwiftUI, WKWebView on system WebKit, SQLite. No network calls of
  its own, no telemetry, no LLM. PoC, light mode first.

## Build and run

```sh
make run        # release build → build/Sill.app → open
make debug      # debug configuration
make clean
```

Requires Xcode (tested with 26.6 / Swift 6.3 on macOS 26).

## Milestones (strict order, PRD §5)

| | Milestone | Status |
|---|---|---|
| M0 | Login viability spike | **Passed** — Google/GitHub/Microsoft sign-ins persist across restart (`docs/M0-login-spike.md`) |
| M1 | Shell (sidebar-first, D2a) | **Built** — awaiting the owner's full-workday gate (`docs/M1-shell.md`) |
| M2 | Workspaces, hibernation, benchmark | **Built** — H4 numbers need a clean measurement run (`docs/M2-workspaces.md`) |
| M3 | Consent + history import | **Built** — owner to grant FDA + run Safari import (`docs/M3-consent-import.md`) |
| M4 | Learning engine | **Built — harness 4/4, 1 FP** (`docs/M4-learning-engine.md`); real-history review pending import |
| M5 | Home, cards, Learning page | **Built** — demo-seed verified; owner to drive confirm flow (`docs/M5-surfaces.md`) |
| M6 | Palette + instrumentation | **Built** (`docs/M6-palette-instrumentation.md`) — fixed a real-URL-guessing bug found via owner's import |
| M7 | Sense-check fortnight (no code) | **Ready to start** — all milestones M0–M6 built |

## Hypotheses being tested (PRD §1)

H1 detection ≥50% confirmed · H2 at least one genuine surprise · H3 trust ("my data,
shown to me") · H4 measurable lightness vs Arc/Chrome · H5 daily-drivable for two weeks.
A clean negative on any of these is a successful PoC outcome.
