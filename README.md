# Sill

A calm macOS browser. Sill notices how you actually use it — the routines,
the tabs you keep together, the sites you're in and out of all day — and
quietly offers to fold that back into the interface, mostly as workspaces
that hibernate when you're not using them and favorites that follow you
everywhere. Nothing leaves your Mac: no telemetry, no account, no cloud sync
of your browsing.

**[Download the latest release](https://github.com/keranm/Sill/releases/latest)**
— or get it from [keranmckenzie.com/sill](https://keranmckenzie.com/sill) for
notes on what's inside. Requires macOS 14 or later. Auto-updates in place
after that.

## What it does

- **Workspaces** — separate contexts for separate parts of your life (work,
  shopping, whatever), each with its own tabs. Switch away and the tabs
  behind you hibernate for real: no memory held, no processes running, back
  instantly when you return.
- **Favorites** — the handful of sites you're in and out of constantly
  (mail, calendar, whatever they are for you), pinned above the workspace
  switcher and reachable from any workspace as the same live tab, not a copy
  that can drift out of sync.
- **A learning engine that only tells you what it can prove** — Sill watches
  for real patterns in how you browse (a morning routine, sites that always
  open together) and surfaces a suggestion only when the evidence is solid,
  with the reasoning always one click away. No AI, no guessing dressed up as
  insight.
- **Developer tools** — Web Inspector, page capture, in-page JSON formatting,
  and a first-party API client with request history, environments, and
  OpenAPI/Swagger/Postman collection import — for anyone who lives in both a
  browser and an API client all day.
- Everything else you'd expect: tabs, history, bookmarks, downloads,
  cross-browser import from Safari/Chrome/Arc/Firefox on first run.

## Privacy

Sill records browsing metadata locally (domain, path, timestamps — never
page content) only with your consent, only to power the features above, and
never leaves your Mac. Pause it or delete everything, any time, from the
Learning page. Full detail in [`docs/roadmap.md`](docs/roadmap.md) and the
archived design docs under [`docs/archive/`](docs/archive/).

## For the curious

This repository is the actual source Sill ships from, if you'd like to read
the code, follow along, or build it yourself:

```sh
make run        # release build → build/Sill.app → open
make debug      # debug configuration
```

Requires Xcode. Most people should just grab the release above, though —
building from source gets you an unsigned, un-notarized copy with none of
the auto-update machinery.
