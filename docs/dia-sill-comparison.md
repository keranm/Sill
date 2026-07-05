# Dia vs. Sill — a comparison, not a roadmap

Requested 2026-07-05: an audit of Dia (The Browser Company's post-Arc, AI-first
browser) against Sill, explicitly **not** to copy it, but to understand what
they're doing and sanity-check Sill's own bets. Findings below; nothing here
is a commitment to build anything.

## What Dia actually is

Dia strips out Arc's power-user chrome (Spaces gestures, heavy customization)
and puts an **AI chat pane at the top of the sidebar** as the primary
interaction layer. Core features, per its own release notes and independent
reviews:

- **Sidebar Chat** — `@`-mention a tab/Tab Group/whole profile and ask
  questions about it; replaces Arc's fuzzy-search-everything with a
  conversational layer.
- **Skills** — natural-language-generated automations ("summarize this page
  and extract action items," auto-fill job applications) that "chain across
  tabs."
- **Memory** — Dia stores facts learned from your chats *and tab activity*,
  surfaced automatically later. Per reviewers: **"Dia collects pages you
  visit and AI queries" for "assistant training and personalization
  context."** Which fields are end-to-end encrypted vs. server-readable isn't
  publicly detailed.
- **Tab Groups**, including auto-grouping tabs opened during a calendar
  meeting (survives after the event for later searchability).
- **Split View**, integrations with Gmail/Calendar/Slack/Notion (plus an
  Atlassian acquisition closed October 2025).
- Free tier + **Dia Pro at $20/mo** for extended AI features.

Sources:
- [Dia Browser Mac Review 2026 – SupaSidebar](https://supasidebar.com/blog/dia-browser-mac-review-2026)
- [A Second Look at Dia: Pleasantly Surprised – Christopher Penkin](https://www.penkin.me/browsers/arc/dia/2026/01/09/arc-to-dia-revisited.html)
- [Dia Browser Review 2026 – Efficient.app](https://efficient.app/apps/dia)
- [Dia Browser release notes](https://www.diabrowser.com/release-notes/latest)

## Where the two browsers already overlap

| Dia | Sill | Note |
|---|---|---|
| Tab Groups for Meetings (auto-groups tabs opened during a calendar event, LLM-organized) | `LearningEngine`'s ritual detector (deterministic, time-window pattern detection — "Mail, then Calendar, then Figma most mornings") | Same *instinct* — context-aware grouping — arrived at completely differently. Dia asks an LLM to notice; Sill computes it. Validates that the underlying idea (routine-aware grouping) is sound even without AI. |
| Memory ("learn from every tab you open") | Learning page + explicit pattern confirmation | Both are "the browser learns your habits." Dia's is opaque and server-assisted; Sill's is deterministic, on-device, and every inference is inspectable via "Why?" |
| Sidebar chat for navigation | Command palette (⌘K, plain substring match) | Dia bet on natural language; Sill deliberately kept this dumb and fast, per the PRD's own "no learning behaviour in the palette, exactly as specified." |

## Worth considering (the UX idea, not the mechanism)

- **Tab Groups (color-coded) within a workspace.** Sill has workspaces but no
  sub-grouping inside one. Multiple reviewers independently called this
  Dia's best non-AI feature. Pure UI, zero network calls, no LLM — fits
  Sill's constraints entirely if ever wanted.
- **Split View.** Already flagged as a real gap when Glance was built (Arc
  and Dia both have it; Sill doesn't). Real feature, real work, not a quick
  add.
- **Meeting-aware grouping**, conceptually. Would require calendar access —
  a new permission surface and arguably a new "sensitive domain" question,
  not a quick add either.

## Explicitly worth rejecting, given what Sill actually is

- **Sidebar Chat / "ask the browser about your tabs."** This is Dia's whole
  thesis, and it's the direct opposite of Sill's H3 trust hypothesis —
  *"my data, shown to me," never "something is watching me."* An
  always-present chat pane reasoning over open tabs is exactly the failure
  mode Sill was built to avoid.
- **Memory as implemented.** "Collects pages you visit and AI queries" for
  server-side "assistant training" hits PRD §3's two hardest lines at once —
  zero network calls of our own, no LLM. Not a gray area; a direct
  contradiction.
- **Skills.** LLM-generated automation is banned twice over (no LLM, no
  automation) in Sill's PRD §3.
- **Cloud integrations (Gmail/Calendar/Slack/Notion).** Each is an OAuth flow
  and an ongoing network relationship — the opposite of a metadata-only,
  zero-own-calls shell.

## The honest verdict

Sill and Dia are answering the same underlying question — *"can the browser
notice what I actually do and help without me asking?"* — with opposite
architectures. Dia's answer is a cloud-assisted LLM watching everything, and
its own reviewers are already flagging that as a trust cost ("the exact
scope... is not detailed in the public changelog"). Sill's answer is a
deterministic engine you can read line by line, with an explicit Learning
page showing exactly what it noticed and why. That's not a gap to close —
it's the differentiator. This audit, if anything, confirms the PRD's
constraints were the right call rather than something to loosen. The only
pieces worth borrowing (colored sub-groups, split view) are pure UI ideas
with zero philosophical conflict, not things Dia does *because* it has an
LLM.
