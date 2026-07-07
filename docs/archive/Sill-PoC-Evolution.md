> **Archived 2026-07-07.** Sill graduated past "disposable PoC" — the DevTools
> and API Client work shipped in v0.1.12 on top of this framing already, and
> the owner has decided to stop describing the product this way. This
> document is kept as the historical record of how Sill got here; it is not
> being updated to match the shipped product. For what's actually built and
> what's next (including the still-unbuilt MCP/H6 layer this doc proposed),
> see `docs/roadmap.md`.

# Sill — PoC Evolution

**Version:** draft, forked from PRD v1.0/1.1 · 3 July 2026
**Status:** This is **not** the document the current build was built from. That document is `Sill-PoC-PRD.md` v1.1, uploaded separately, and it is canonical for what's actually shipped. This file is where speculative additions from later conversation (MCP layer, API client, H6, the developer-inspector line, the agents/SaaS roadmap) live until a decision is made to fold any of them back into a real, versioned spec and hand it to a build.

Treat everything below §2 as **proposed**, not built. Nothing here should be assumed present in the running app without checking the actual code.

---


## 1. What this PoC is for

A working macOS proof of concept good enough for the owner to **daily-drive and sense-check the core concept**: a calm browser that observes how it is used (metadata only, locally) and sparingly offers to fold what it notices back into the interface, chiefly as workspaces.

This is not production software. It is disposable code built to answer five questions, after which the concept is pivoted, built out, or shelved:

- **H1 Detection:** Routines can be found from navigation metadata alone, with ≥ 50% of surfaced suggestions confirmed as real by the user.
- **H2 Revelation:** At least one suggestion genuinely surprises the user (a pattern they didn't know they had, or a cost they'd never seen).
- **H3 Trust:** After two weeks, the experience reads as "my data, shown to me", never "something has been watching me".
- **H4 Lightness:** Workspace hibernation makes Sill measurably lighter than Arc and Chrome at identical tab load. A number, not a vibe.
- **H5 Drivability:** The owner uses Sill as their real work browser for two consecutive weeks by choice.
- **H6 Agent legibility** (new, tracked separately — see §4.10): agent access via MCP is exposed narrowly and reads on the Learning page exactly like the browser's own observations. A pass here is evidence for the *next* phase (workspaces evolving around agents), not a claim that phase has begun.

A clean negative on any hypothesis is a successful PoC outcome. Do not soften results.

---

## 2. Platform and stack (decided, not open)

- macOS only. Light mode first (see §8, deviation 1).
- **Swift + SwiftUI**, dropping to AppKit where SwiftUI falls short (window chrome, first-responder and keyboard routing), rendering via **WKWebView on the system WebKit**. One persistent, non-ephemeral `WKWebsiteDataStore` for real logins. **The engine choice is a PoC decision, not a marriage:** WebKit now; Chromium remains the documented escape hatch (§7) if compatibility evidence demands it.
- **SQLite via GRDB** (or raw sqlite3 if simpler), one local database file, inspectable with any SQLite client. Synchronous writes for observation events; never buffer events in memory across a potential crash.
- The design package's `tokens.css` and HTML prototypes are **visual truth to be translated, not consumed**: recreate the tokens as a Swift design-token layer with names preserved one-to-one. Values: Instrument Sans (bundled locally, no network fonts); still-water teal oklch(0.54 0.08 195) light / oklch(0.72 0.08 195) dark; canvas #FBFAF8, wells #F3F1EC, ink #21201C; dark values mirrored in tokens. Fidelity drift on the details the design package sweats — the 120 ms dismissal, the restore skeletons, wash-not-box cards — is a defect, not an interpretation.

---

## 3. Hard constraints (enforce in every review, no exceptions)

1. **Metadata only.** Recorded fields: registrable domain, path (query strings and fragments stripped), page title (truncated 120 chars), timestamps, tab events, transition type, workspace id, session id. No DOM reads, no content scripts, no screenshots, no scraping.
2. **Zero network calls from our own code.** Pages the user loads obviously use the network; the shell, engine, and learning system make none of their own. No telemetry, no update pings, no analytics, no font CDNs (bundle Instrument Sans locally).
3. **Sensitive-domain exclusion, on by default.** Banking, health, government, adult categories, plus user-added domains and all private windows. Excluded visits are never recorded in any form — no rows, no counts, no hashes. Exclusion applies during history import too, not after.
4. **Pause and delete-everything are one click each,** on the Learning page, visible without scrolling. Delete-everything verifiably empties observation data while created workspaces survive (exactly as the PDF's confirm copy states).
5. **No automation.** Sill never opens tabs on the user's behalf, never pre-fills, never acts. It observes, detects, and asks. (The confirm flow creating a workspace the user just approved is the one sanctioned action.)
6. **No LLM anywhere in this PoC,** local or cloud. Detection is deterministic; suggested names are template-derived (e.g. "Mornings" from a weekday-morning ritual), not generated.

---

## 4. Functional specification

### 4.1 Shell (PDF: Shell chrome, D2a v2)
Sidebar-first, exactly as drawn: left rail with workspace switcher, "Search or go to…" (⌘K), promoted Applications grid, vertical tabs, dormant workspaces and Downloads at the foot. The page is the stage.

**The header address display** (per the D2a screenshot: back/forward, lock, `domain / path-or-title`) is a **security surface**, and behaves as follows:
- Registrable domain always rendered in full ink; path in faint ink. When the path is uninformative (long IDs, query-shaped slugs), the page title may stand in for it; the rule is: show path if ≤ 40 chars and human-readable, else title.
- Clicking the readout (or pressing **⌘L**, which must work from anywhere) opens the palette's go-to field pre-filled with the full URL, selected. Twenty years of muscle memory is honoured.
- **Negative states (must be designed-in, not Chromium defaults):** plain HTTP and broken/invalid TLS render the domain on a warning treatment with a plain-sentence explanation on click; certificate errors get an interstitial in the product's own voice with no "proceed anyway" styling that makes danger look calm.
- **Homoglyph policy:** IDN domains render in punycode unless the label is single-script; mixed-script lookalikes always show punycode.

New tab, close tab, reorder, back/forward, reload, downloads list, session restore on launch. Zero learning tax: any experienced browser user lands productive instantly. The caliber bar is Arc and Zen, not legacy mimicry.

**Developer inspector:** `WKWebView.isInspectable = true` on every view, always on, reachable from the standard right-click "Inspect Element" and a menu item. This is the entire developer-tooling commitment for the PoC: Safari's own Web Inspector, for free, no custom build. No attempt to match or exceed Chrome DevTools — general users never see this surface, and that's by design, not a gap.

### 4.2 Workspaces and hibernation (PDF: D2a switcher and restore states)
- Workspaces are first-class contexts: create (⌘⇧N), name, switch via the rail popover exactly as drawn. Dormant workspaces are faint facts, never badged.
- **Full hibernation:** on switch-away, every WKWebView in the departing workspace is deallocated; URL, title, favicon, and scroll position snapshot to SQLite. On switch-back, the rail rebuilds instantly with skeletons of the actual returning tabs and the "Research, as you left it — 12 tabs" line, per the PDF; pages restore within 2 seconds.
- **"Everything else"** is a real, ordinary workspace: born automatically the moment the first user workspace is created, holds all unclaimed tabs, hibernates like any other, renameable, cannot be deleted while it is the only other context.
- **The benchmark harness ships with this milestone:** scripted load of 40 defined tabs across 4 workspaces; RSS of all app processes measured with 3 of 4 workspaces hibernated, versus Arc and versus Chrome with the same 40 tabs open. Method documented and repeatable; results in the readme, flattering or not.

### 4.3 Home (PDF: D2b, three temporal states)
One evolving page, exactly as the three mocks show: day one (greeting, search, recent, one import invitation), week one (Applications row appears), month one (at most two noticed cards join, below the fold of attention). Time-of-day greeting, no widgets, no configuration begging.

**Applications row rule (resolves the PDF's conflation):** the row is populated only by *confirmed* applications — ones the user accepted via a "Pin it as an application?" card, plus any they pin manually from a tab's context menu. Discovery alone never places an icon there. (Deviation 2 in §8.)

### 4.4 Consent and import (PDF: D2f)
- The under-60-words consent screen, verbatim from the PDF, on first run. "Not now" keeps observation off; the browser works fully either way. Consent can be revisited from the Learning page.
- **History import** (the cold-start killer): with consent, ingest existing history from **Safari** (`~/Library/Safari/History.db`, handle the Full Disk Access permission flow gracefully with a designed explanation, not a bare OS dialog), **Chrome** and **Arc** (both Chromium `History` SQLite, ~90 days), and **Zen/Firefox** (`places.sqlite`). Normalise into the event schema flagged `source: import`, exclusions applied during ingest. Target: months of cross-browser history ingested in under a minute.
- Bookmarks import from the same browsers into a flat, unpromoted list reachable from the palette. (Passwords import is **out**: see §6.)
- Post-import, pre-detection, Home carries the single quiet line: "Watching quietly. Patterns usually appear within a few days."

### 4.5 Learning engine (deterministic, runs on idle, at least daily)
Session = activity separated by gaps under 25 minutes. Four detectors:

- **Sequence detector:** recurring ordered domain sequences (length 2–5) within sessions. Qualifies at ≥ 5 occurrences across ≥ 3 distinct days; sequences composed entirely of the global top-5 domains are excluded as noise. Naive n-gram counting; no mining library until provably too slow.
- **Ritual detector:** domains visited at consistent times of day (≥ 10 visits/30 days, low circular variance), including day-of-week conditioning (weekday mornings, Sunday evenings).
- **Co-occurrence detector:** domains *open simultaneously* on most working days (tab-set snapshots at navigation events; qualifies at co-presence on ≥ 60% of active days over 2+ weeks). This is what makes "When Linear is open, GitHub and the staging site are usually open with it" truthful.
- **Cost accountant:** for every candidate, a plain-language evidence line with aggressive rounding ("about a dozen mornings over the past three weeks"). Never counts with false precision, never timestamps — the D3 rules are load-bearing product behaviour, not copywriting garnish.

**Confidence staging (promoted from the PDF's Learning-page mock into engine spec):** patterns below the suggestion threshold but above a floor appear on the Learning page as "recent, still settling" — visible in the ledger, never as cards. Only settled patterns generate suggestions.

**Application-promotion detection:** a domain visited most days for ~a month, reached chiefly by typed address or ranking top in dwell share, generates a "Pin it as an application?" candidate.

**Precision over recall throughout.** Thresholds are floors; tune upward only. One false card costs more trust than five missed ones.

### 4.6 Suggestions (PDF: D2c, all five states)
- **Global cap: two cards visible across the entire product,** Home being the only card surface in the PoC.
- **Cadence:** at most one new card surfaces per day. A card may sit unanswered for **14 days**, then withdraws silently, recorded on the Learning page as "withdrawn, unanswered". A withdrawn pattern may return **once**, with stronger evidence, after a 30-day cooldown. Never a third time.
- **Card anatomy and flow exactly per D2c:** observation (pattern as grammatical subject), rounded evidence, inline "Why?" expansion answering with the same facts the Learning page holds (including "dismissing this suggestion also forgets the pattern"), exactly two actions. Confirm morphs the card into the in-place naming form (one editable template-derived name) → workspace born pre-populated, landing in the full shell exactly as the payoff mock shows. Dismissal: 120 ms fade, "Okay. That one won't come back.", undo only on the Learning page.
- **Copy source:** the D3 register and worked examples are canonical, minus the culled lines (§8, deviations 3–5). Every card the engine emits must be checkable against the D3 rules.

### 4.7 Learning page (PDF: D2d, all three states)
Build exactly as drawn: status line ("Observing locally since… Nothing has left this machine."), pause and delete-everything above the fold, observed-in-aggregate paragraph, noticed-so-far with per-item forget and "still settling" entries, suggestions-made with outcomes and dismissal undo, never-observed list with user-add field and the "no trace at all — not even a count" behaviour honoured literally. Paused state and delete confirmation per the mocks: factual, no guilt, no theatre.

### 4.8 Command palette (PDF: D2e)
⌘K from anywhere; groups exactly as drawn (actions, workspaces, applications, history, web-search fallback); ⌘↵ opens in new tab. No learning behaviour in the PoC. ⌘L variant opens it in go-to mode with the current URL selected (§4.1).

### 4.9 Instrumentation and the demo seed
- **Local-only metrics:** cards surfaced/confirmed/dismissed (H1); a small optional "this surprised me" checkbox on the naming form (H2); days-to-first-card and unprompted Learning-page revisits (H3 proxies); daily active shell use (H5); benchmark results (H4); plus a one-tap "that was annoying" counter in the shell chrome for logging friction moments, taggable `password`, `engine`, or `other` (the password-manager gap and Chrome-first sites will be its main customers).
- **Export:** aggregate JSON by explicit user action only; must contain no URLs, titles, or individual timestamps — publishable without leaking history.
- **Demo seed (dev flag only):** a synthetic 30-day history generator with 4 planted routines plus realistic noise, loadable behind a flag so the entire card→confirm→workspace flow can be sense-checked on day one without waiting for organic detection. The same generator is the detection test harness. Clearly walled off from real data; never both in one database.

### 4.10 API client and MCP layer (new for this PoC)

**API client.** A lightweight request builder as a first-party panel, not a capability plugin: method, URL, headers, body, response viewer, request history, and named environments (so a token captured while logged into an app in a workspace can be reused deliberately, never silently). Bounded scope: no collections/team-sharing/mocking/scripting. This is Postman's core loop, nothing more, sitting where the friction actually happens instead of in a separate app the user tabs away to.

**MCP layer.** Sill exposes an MCP server so an external agent (Claude Code, Claude Desktop, or similar) can query and act through it. This is a distinct hypothesis, not folded into H1–H5:

- **H6 Agent legibility:** an agent connected via MCP can read the present moment (active tab/workspace state) and issue an API-client request, and every such read or action appears on the Learning page in the same voice as everything else, indistinguishable in kind from the browser's own observations. Sill learns from behaviour; it does not share that learning with an agent — reach-in is scoped to *right now*, never to the observation history. If an agent's access can't be explained as plainly as a suggestion card, or if it reaches beyond the present moment into what Sill has learned, H6 fails regardless of whether the plumbing works.

Scope for the PoC: **read tools only**, plus one narrow write path. Every exposed tool answers a question about *right now* — the active tab, the active context, a screenshot taken on request. None of them hand over the learning history itself.
- Exposed: current tab URL/title, workspace list and contents, "run this request" via the API client, **`capture_page(tab_id)`** returning a full-page screenshot (handles scroll/lazy-load/sticky headers, same problem GoFullPage-style extensions already solve), and **`describe_active_context()`** returning current URL/title/workspace so an agent doesn't need to be told what's on screen before answering a question about it.
- **Not exposed:** no tab creation, no navigation, no form-filling, no credential access beyond what the API client's named environments already hold, no continuous or streaming capture — every read is a single, on-request snapshot, never a standing feed. **Also not exposed: the Learning page's contents, or anything the observation engine has inferred.** Sill learns from the owner's behaviour; it does not hand that learning to an agent. An agent can see what's on screen right now, the same as glancing at a shared monitor — it cannot ask what patterns, routines, or history Sill holds. That boundary is deliberate and not to be reopened without a separate, explicit decision. Standing delegation (rung five of the ladder from earlier discussion) is likewise explicitly not this PoC's job.
- The exclusion list applies to `capture_page` exactly as it applies to observation: a screenshot of an excluded domain is not captured, full stop.
- Every MCP call, screenshots included, is logged as an event, on the same footing as a page visit, subject to the same exclusion list, and visible **to the owner** on the Learning page under a new "Agent activity" heading — not hidden in a debug log, and not itself a channel the agent can read back through. The ledger is for the human; it is a record of the agent, not a resource available to it. Representing "an agent captured a full visual of your screen" as calmly and legibly as "an agent read your tab title" is a real copy problem, not just an engineering one, and belongs with Design rather than improvised in the build.
- This is where the trust-ledger work already done for H3 pays a second dividend: the same infrastructure that makes suggestions legible to a human makes agent access auditable. Building H6 mostly means routing a new caller through machinery that already exists.

**Dogfooding note:** the owner intends to use these two tools directly while building Sill itself — asking Claude Code to look at the running app instead of manually screenshotting and pasting. This is the first real test of H6, not a separate feature: if agent access here feels like "my data, shown to me" during actual daily use, that's the strongest evidence the hypothesis can get.

**Done when (joins M6):** an external MCP client can list workspaces, read the active tab, capture a full-page screenshot, describe the active context, and fire an API-client request, and every one of those calls shows up correctly and comprehensibly on the Learning page. If agent activity on the ledger reads as clear as a suggestion card, H6 passes.



Strict order. Each ends at a stopping point: demonstrate the definition of done before starting the next.

**M0 — Login viability spike (half a day, first).** Google sign-in and some anti-bot walls can reject *any* embedded webview ("this browser or app may not be secure"), WKWebView included. *Done when:* interactive sign-in succeeds to a Google account, GitHub, and one Microsoft property inside the shell, sessions surviving restart; the required data-store and user-agent configuration is documented. **If this fails after honest effort, stop and write it up — that outcome ends the WebKit path and the PoC pivots to the Chromium escape hatch before more code.**

**M1 — Shell.** §4.1 complete, including the header's negative states and ⌘L. *Done when:* the owner completes a full normal workday in it, logins persisting, session restoring correctly.

**M2 — Workspaces, hibernation, benchmark.** §4.2 complete. *Done when:* switch-away measurably releases memory; switch-back restores within 2 s to correct URL and scroll; Everything-else behaves per spec; the Arc/Chrome benchmark produces a documented number. If hibernation doesn't win meaningfully, H4 fails — record it, don't tune the benchmark until it flatters.

**M3 — Consent and import.** §4.4 complete. *Done when:* a fresh install ingests the owner's real Safari + Chrome/Arc history in under a minute with zero rows for excluded domains, and declining consent provably records nothing.

**M4 — Learning engine.** §4.5 complete, no UI. *Done when:* against the demo seed (4 planted routines + noise), detectors find ≥ 3 of 4 with ≤ 2 false positives; then run on the owner's real imported history and review the raw output together before any card exists.

**M5 — Suggestion surfaces and Learning page.** §4.3, 4.6, 4.7 to the PDF's mocks, light mode. *Done when:* a real detection travels end-to-end into a card; confirm births a populated workspace landing exactly as the payoff mock; dismissal suppresses permanently with Learning-page undo; every emitted card string passes the D3 rules; every §3 constraint demonstrably intact.

**M6 — Palette, API client, MCP layer, instrumentation.** §4.8, 4.9, 4.10. *Done when:* export contains every metric and could be posted publicly; the demo-seed flag exercises the full flow on a clean profile; the API client can fire and display a real request against one of the owner's actual SaaS tools; an external MCP client (Claude Code, in practice — this is the owner's own dogfooding tool during the build) can complete the §4.10 done-when checklist, screenshot and context tools included, with every call legible on the Learning page.

**M7 — The sense-check fortnight.** No code. The owner daily-drives Sill for two weeks on real work. Then the five hypotheses get graded against §7's gates.

---

## 6. Known gaps, accepted for the PoC

- **No extensions, therefore no 1Password/Bitwarden in-shell.** Mitigation: password manager's standalone app + manual fill, with every sting logged via the "that was annoying" counter. This is H5's most likely killer; we measure it rather than hide it. Passwords are **not** imported from other browsers (plain-text credential handling is out of scope and out of appetite for disposable code).
- **No DRM** — third-party WebKit shells get neither FairPlay nor Widevine, so no Netflix et al. Accepted; this is a work surface.
- **Chrome-first SaaS risk** — Chrome is often "the" browser of the modern SaaS world, and some tools degrade or nag on WebKit. The owner's six months of Safari-first daily work is the informal evidence this bites rarely; the PoC makes it formal: every "works best in Chrome" sting is logged via the annoyance counter, tagged `engine`, and the tally feeds the §7 engine gate. In exchange, the system WebKit rides macOS security updates, so the pinned-runtime treadmill liability from the Electron plan disappears entirely.
- **Notifications, capabilities, SDK, sync, Windows/Linux, settings beyond the exclusion list** — all out, per the design package's own out-of-scope list.

---

## 7. Decision gates after M7

- H1 ≥ 50% **and** H2 hit → the concept graduates; next phase is scoped (co-pilot rails, dark mode, extension strategy).
- H1 holds, H2 misses → recognition is a feature, not a product; decision memo before more code.
- H1 fails → metadata-only detection is insufficient; options memo (richer signals with their trust cost, or stop).
- H4 fails → the lightness claim is retired from the thesis, publicly and honestly.
- H5 fails → whatever broke daily-driving becomes the entire next milestone; nothing else matters until the owner chooses to live in it.
- **Engine gate:** if `engine`-tagged stings show WebKit itself is the reason H5 struggles (tools the owner genuinely needs that won't run well), the escape hatch opens — same shell concept, Chromium runtime — as a scoped decision made on the sting log as evidence, not as a reflex.

---

## 8. Deliberate deviations from the design PDF

1. **Light mode first.** The PDF notes dark comps are not yet produced. For a sense-check PoC, dark does not gate the build: implement against tokens so dark is cheap later, ship light. (Revises the earlier review position that dark gates M5; a PoC for one owner doesn't need both modes to answer H1–H5.)
2. **Applications row = confirmed only.** The week-one Home mock shows discovered apps in the row pre-confirmation; this PRD requires confirmation or manual pinning first, keeping "the user always decides" true. Design may relabel the row if it disagrees — but one label, one rule.
3. **Cull:** "Setting it up by hand takes a couple of minutes each time" (D2c anatomy card) — saved-time framing, banned by D3 rule 7. The month-one Home version of the same card already omits it; that version is canonical.
4. **Cull:** "It keeps itself tidy — nothing to maintain" (payoff screen) — promises maintenance behaviour that does not exist under constraint §3.5. The remaining payoff copy stands fine alone.
5. **Event-anchored worked copy retired for the PoC** (D3 rituals example 3, "Trips start here with the same pair…"): no detector produces this truthfully yet. The copy survives in D3 as future register guidance; the engine must never emit a card shape it cannot evidence.
6. **Padlock:** recommendation is to drop it for secure connections and mark only insecure states (§4.1) — Chrome retired the lock in 2023 because users misread it as site trustworthiness. Design has final say; the build implements one choice or the other, never Chromium's default.

---

---

## 9. What done looks like

A single macOS app the owner opens on a Monday morning, signs into their real tools, works in all day, and, within days (history import having front-loaded the learning), receives a first quiet card that is *true*. They confirm it, name it, and watch a workspace assemble itself from their own habits. Two weeks later, the five hypotheses have honest grades, and the decision to pivot, build, or shelve is made on evidence rather than enthusiasm.

---

## 10. Roadmap direction (not this PoC): workspaces evolving around agents and SaaS efficiency

If H1–H6 hold, the next phase's organising question changes from "does the browser notice useful things" to **"does the browser let an agent act on what it notices, legibly and on the user's terms."** That's rungs two through four of the delegation ladder discussed earlier (co-pilot on rails → do it while I watch → do it and show me), applied specifically to workspace routines rather than to browsing in general: a workspace that assembled itself from observed behaviour is also the natural unit an agent would be scoped to act within ("handle the Mornings routine" is a bounded, auditable request in a way "handle my browser" never could be).

H6 in this PoC is the first, smallest brick in that direction: proving agent access can be exposed without breaking the trust model the whole product depends on. Nothing further is scoped here. The instinct behind "open claw" is correctly held at arm's length for now — the shudder is the right response until the trust infrastructure has been proven at rung one first, which is precisely what this PoC is for.
