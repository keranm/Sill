# M5 — Home, suggestion cards, Learning page (PRD §4.3, §4.6, §4.7)

**Status: built (4 July 2026); machine-verified to the card surface on the demo
seed. Owner gate: drive the confirm flow end-to-end (demo instance is running),
then live with it.**

## Suggestion lifecycle (§4.6) — `PatternStore.swift`

- Global cap **two cards**, Home the only card surface. At most **one new card
  per day** (`last_card_day`); the demo seed may fill both slots at once so the
  flow can be sense-checked on day one.
- Unanswered for **14 days → withdraws silently**, recorded on the Learning
  page as "withdrawn, unanswered". A withdrawn pattern may return **once**,
  after a 30-day cooldown, only with stronger evidence (count ≥ prev + 3).
  Never a third time (`times_suggested`).
- **Dismissal**: 120 ms fade, "Okay. That one won't come back.", permanent
  suppression; undo lives only on the Learning page. Engine re-runs never
  resurrect a non-noticed state.
- Confirm is **the one sanctioned action** (§3.5): workspace born
  pre-populated, shell lands in it, payoff on the stage ("Mail, Calendar and
  Figma are here. Tomorrow morning this is one click.") — the culled
  "keeps itself tidy" line stays culled (§8.4). App-promotion cards pin
  straight to Applications, no naming form.
- Card anatomy per D2c: observation with the pattern as grammatical subject,
  rounded evidence, inline "Why?" (same facts as the Learning page, including
  "dismissing this suggestion also forgets the pattern", link to the page),
  exactly two actions. Copy is template-built in `PatternStore` — every string
  checkable against D3; the "surprised me" checkbox on the naming form feeds H2.

## Home (§4.3) — `HomeView.swift`

Three temporal states emerge from data, not modes: day one = greeting
("Good morning"; weekday joins after a week of observing), search (⌘K hint),
recent, one import invitation. Applications row appears only once something is
**confirmed** (§8.2 — discovery never places an icon). Cards join below the
fold of attention, capped at two. Post-import, pre-detection: "Watching
quietly. Patterns usually appear within a few days."

## Learning page (§4.7) — `LearningPageView.swift`

⌘⇧L or Learning menu; also linked from every card's "Why?". Status line
("Observing locally since 14 June. Nothing has left this machine." — paused
and observation-off variants), **pause and delete-everything above the fold**,
observed-in-aggregate paragraph (counts rounded to "about forty sites"),
noticed-so-far with per-item **forget** and "recent, still settling" entries,
suggestions-made with outcomes (accepted — became "Mornings" / dismissed +
**undo** / withdrawn, unanswered), never-observed list with user-add field
("Excluded sites leave no trace here at all — not even a count." — literal:
adding an exclusion also scrubs existing rows). Delete confirm per D2d: sober,
specific; workspaces survive, learning doesn't. Consent is revisitable here
(§4.4): "Turn observation on" when declined.

## Also in this build

- `DisplayNames.swift`: well-known app subdomains (mail.google.com,
  calendar.google.com…) keep their identity instead of collapsing into
  eTLD+1 — without this the package's own "Mail, then Calendar" copy would be
  impossible to evidence. Friendly names for learned surfaces.
- Post-import engine run: months of history trigger detection immediately,
  not at the next 12-hour tick.
- Metrics recording began (cards surfaced/confirmed/dismissed, surprised,
  first-card timestamp) — M6 exports them.

## Verified on the demo seed (screenshot in session log)

Home rendered with both planted cards, D3-clean:
"Most weekday mornings here start with Mail, then Calendar, then Figma —
usually before ten." / "Seen about twenty mornings over the past month." and
the co-occurrence card with "Together on most working days."

## Owner gate (the demo instance is running now)

1. In the demo instance: expand "Why?", then confirm the morning card — name
   it, watch the workspace assemble and the payoff land. Dismiss the other;
   check the Learning page records both outcomes and undo works.
2. In your real Sill: relaunch to pick up M5. Home now lives on every new tab;
   ⌘⇧L opens the Learning page. Cards appear only when something settles.
