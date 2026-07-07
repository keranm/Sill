# Zen vs. Sill — a comparison, not a roadmap

Audit of Zen Browser (open-source, Firefox-based, the "spiritual successor to Arc")
against Sill, in the same spirit as the Dia comparison: understand what they're
doing, sanity-check Sill's bets, no commitment to build anything.

## What Zen actually is

Firefox fork, MPL 2.0 licensed, positioned explicitly as the Arc alternative
for people who wanted Arc's UX without Arc's Chromium engine or its shutdown.
Current stable as of mid-2026 is the 1.19–1.20 line on Firefox 150–151. Core
features, per official docs and independent reviews:

- **Workspaces** — the organizing primitive, near-identical in concept to
  Sill's: name it, pick a color/emoji, switch via `Cmd+1`–`Cmd+8` or a
  sidebar switcher. Can bind a Container Tab (Firefox's cookie-jar identity
  isolation) per workspace for account separation.
- **Compact Mode** — collapses the sidebar to a thin favicon strip on
  hover-exit or focus-loss; a screen-real-estate feature, not a learning one.
- **Split View** — up to 4 tabs tiled in a grid (horizontal/vertical/grid),
  drag-to-split, matches Arc's old ceiling. The single feature most
  reviewers call out as the standout differentiator.
- **Glance** — Alt+click opens a link in a floating, easily-dismissed
  overlay instead of a new tab. Arc's Peek, essentially.
- **Tab folders** (added Aug 2025) — nested tab groups, distinct from
  Workspaces, sitting one layer below them.
- **Live folders** (shipped Feb 2026) — a sidebar folder that
  auto-populates from a live source (open GitHub issues, PRs, an RSS feed).
- **Mods** — a curated catalog of community-built interface tweaks
  (tab animation, URL bar sizing, layout), toggle-installed, no restart.
- **Boosts** (Twilight/pre-release only as of mid-2026, not yet stable) —
  per-domain CSS: color tint, custom fonts, "element zap," forced dark mode.
  Arc's Boosts, reimplemented.
- **No native AI.** Explicitly and repeatedly confirmed across sources: "no
  native AI assistant ships in Zen." Users who want it bolt on Firefox
  add-ons (Sider, Monica, Page Assist for local Ollama).
- **Gecko engine**, not Chromium. This is Zen's actual point of principle —
  "avoiding the Chromium monoculture" — not a performance play.

Sources:
- [Zen Browser Features Guide 2026 – SupaSidebar](https://supasidebar.com/blog/zen-browser-features-guide-2026)
- [Zen Browser Mac Review 2026 – SupaSidebar](https://supasidebar.com/blog/zen-browser-mac-review-2026)
- [Zen Browser vs Brave 2026 – SupaSidebar](https://supasidebar.com/blog/zen-browser-vs-brave-2026)
- [Zen Browser Chrome Extension Support? – SuperchargeBrowser](https://www.superchargebrowser.com/library/zen-browser-vs-chrome-extensions/)
- [Zen Browser — Wikipedia](https://en.wikipedia.org/wiki/Zen_Browser)
- [Zen Browser Workspaces — official docs](https://docs.zen-browser.app/user-manual/workspaces)
- [Long-Term User Reviews of Zen Browser 2024–2026 – Factually](https://factually.co/product-reviews/electronics-tech/zen-browser-long-term-user-reviews-2024-2026-6a6315)
- ["I Switched to a Browser Most People Have Never Heard of" – Medium](https://medium.com/@ezraclintoc/i-switched-to-a-browser-most-people-have-never-heard-of-i-am-not-going-back-e4eda23eb039)

## Where the two browsers already overlap

| Zen | Sill | Note |
|---|---|---|
| Workspaces (name, color/emoji, switch, bind identity) | Workspaces (name, switch, born from detection or manual) | Same primitive, opposite origin story. Zen's are 100% manual — the user builds every one by hand, every time. Sill's can be manual *or* self-assembled from observed routine. This is the actual product bet Zen doesn't make at all. |
| Container Tabs bound to a Workspace (per-workspace identity isolation) | No equivalent | Real gap, see below — not identity isolation exactly, but the *reason* people want it (keep a work Google login separate from personal) is a real, named need Sill doesn't address. |
| Gecko, not Chromium — "avoiding the monoculture" as a stated value | WebKit, not Chromium — decided for lightness, not monoculture politics | Different engine, different justification. Zen's is closer to a principle; Sill's is closer to a performance and daily-driver bet. Worth being honest that Sill's engine choice was never framed as an anti-Chromium stance and shouldn't retroactively claim to be one. |
| No native AI, add-ons only if wanted | Deterministic learning engine, no LLM, by hard constraint | Zen arrived at "no AI" by simply not building it yet (roadmap discussion exists, nothing shipped). Sill arrived at "no AI" as a considered constraint tied to trust (H3) and precision (H1). Same current state, very different reasons — worth remembering if Zen ships AI later and the comparison needs redoing. |

## Worth considering (the UX idea, not the mechanism)

- **Split View.** ~~Already flagged in the Dia comparison as a real, deferred
  gap.~~ **Shipped**, 2-pane side-by-side. Zen's implementation goes further
  (up to 4 tabs, grid, drag-to-split) and multiple sources independently
  call the 4-pane grid the standout differentiator few non-Arc browsers
  match. Sill's 2-pane covers the core use case both comparisons actually
  cited (research in one pane, write in another) — per Zen's own docs,
  most users on typical laptop screens stay at 2 regardless of the
  4-pane ceiling, so this isn't a weak version of the feature, it's the
  version that covers most real usage. The gap that remains is real
  (3–4 tab grid layouts) but is now a scoped enhancement to something
  live, not a from-scratch build. Worth confirming: how split view
  interacts with "the active tab" for the MCP layer's
  `describe_active_context()`/`capture_page(tab_id)` and the co-occurrence
  detector's session model — neither this doc nor the PRD specified an
  answer before this shipped.
- **Live folders** (a sidebar folder that auto-populates from a live
  source — open GitHub issues, PRs, an RSS feed). Interesting precedent for
  "Applications" done one step further: not just promoting a site to an
  icon, but surfacing a *live slice* of it in the sidebar. Worth watching
  as a UI idea, though it's Zen's one feature that gestures toward
  something Sill-shaped (a workspace showing you a *summary* of what's
  inside it) without any learning behind it — Zen's version is
  configured by hand per source, not detected.
- **Compact Mode.** Pure screen-real-estate UI, zero conflict with
  anything in Sill's PRD. Cheap if ever wanted; not core to the thesis
  either way.

## Explicitly worth rejecting, given what Sill actually is

- **Mods (community interface tweaks) and Boosts (per-domain CSS).** This
  is Zen's actual identity — "you are not just choosing a theme, you are
  reshaping the tool" — and it is the direct opposite of Sill's "earn
  complexity" and "suggestions over settings" principles. Mods are exactly
  the *settings-as-commitments* model those principles were written to
  avoid; a catalog of manually-installed interface tweaks is a
  configuration surface, not an observation-driven one. Zen's own users
  praise this as the reason they switched, which only sharpens the
  contrast: Zen and Sill are optimizing for opposite kinds of user
  satisfaction — one from control, one from not needing to exercise any.
- **Manual-only Workspaces as the ceiling, not the floor.** Not something
  to "reject" exactly, since Sill already does better here, but worth
  stating plainly: Zen's Workspaces, for all the praise, never move beyond
  a folder the user builds and names themselves. There is no "I noticed
  you use these together" anywhere in Zen's model. If Sill's detection
  engine underdelivers in practice, the fallback experience is "as good as
  Zen's Workspaces." That's a fine floor, not a differentiator — the
  differentiator only exists if H1/H2 hold.
- **Chrome extension compatibility, full stop.** Multiple sources are blunt
  about this being Zen's real-world adoption ceiling: "Zen Browser runs on
  Firefox — Chrome Web Store extensions won't work. You lose your
  extensions, passwords, and sync." Sill has the identical structural gap
  (no extension runtime, by deliberate PRD choice), and Zen is the live
  case study for what that costs in practice — not a hypothetical.

## The honest verdict

Zen is a much closer competitor than Dia in surface area — same UI
philosophy (calm, vertical sidebar, workspace-first, opinionated), same
target user in some overlap (people who wanted Arc but didn't want Chromium
or a shutdown risk), and zero AI ambitions to distract the comparison. That
closeness makes it the more useful audit: where Sill differs from Zen, it's
because of a genuine, considered bet, not because Zen is chasing something
Sill's principles already ruled out.

Two things this audit actually changes, versus the Dia one:

1. **Split View shipped as 2-pane; the 4-pane grid is the remaining gap,
   not the whole feature.** Two independent competitors converging on
   Split View as their most-praised feature was real signal — signal
   Sill has now partly acted on. The honest scoping question going
   forward is whether the last mile (3–4 tab grid) is worth the
   architectural cost, given 2-pane already covers what most users on
   most screens actually reach for.
2. **The extension-compatibility gap is confirmed as a live cost, not a
   theoretical one.** Zen has been shipping for two years with this exact
   limitation and reviewers still lead with it. Sill inherits the same
   limitation by the same reasoning (no extension runtime); the honest
   read is that this is a known, accepted, ongoing tax on adoption for
   both browsers, not a solved problem for either.

Everything else confirms rather than challenges the existing PRD: Zen's Mods
catalog is the clearest available proof that "configuration as the product"
and "observation as the product" are genuinely different bets, not two
implementations of the same idea — and Sill is intentionally on the second
side of that line.
