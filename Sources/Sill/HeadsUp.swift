import SwiftUI
import WebKit

/// Heads-up favorites (owner ask, 2026-07-11): glanceability without opening
/// them — attention counts on favorite chips (Gmail's unread inbox, Home
/// Assistant's pending updates), and a small card when a Calendar meeting is
/// about to start (click-through lands on that meeting's own detail bubble
/// in Google Calendar).
///
/// All of it is read from the favorites' own signed-in pages — every
/// favorite is already loaded from launch (TabStore.ensureFavoriteTab), so
/// the Settings toggle only gates the *reading*: polling those pages with
/// the same JavaScript any page runs on itself. No Google API, no OAuth, no
/// network requests of our own (PRD §3.2), nothing leaves the machine. Off
/// by default: reading the user's mail and calendar is their call, not the
/// browser's.
///
/// Honest limitation: an event's reminder offsets are not rendered anywhere
/// in Calendar's DOM, so "show 2 minutes before *the event's own* alert"
/// can't be read from the page. We standardize on Google's default reminder
/// (10 minutes) plus that 2-minute head start — the card appears 12 minutes
/// out, which also covers the headline "meeting in the next 10 minutes."
@MainActor
@Observable
final class HeadsUpStore {
    struct Meeting: Equatable {
        /// Calendar's own `data-eventid` — the handle openMeeting() uses to
        /// click the real chip on the page.
        let eventID: String
        let title: String
        let start: Date
        let end: Date?
    }

    /// Per-favorite attention counts: Gmail's unread inbox, Home Assistant's
    /// settings notifications (pending updates). Absent until first
    /// successful read (or while the toggle is off).
    private(set) var badgeCounts: [Favorite.ID: Int] = [:]
    /// The one meeting currently worth a card, if any.
    private(set) var meeting: Meeting?
    /// Tick-updated clock the card's countdown derives from, so "in 8 min"
    /// stays honest without a per-second timer.
    private(set) var now = Date()

    @ObservationIgnored private weak var store: TabStore?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Dismissed cards stay dismissed for that event — session-only.
    @ObservationIgnored private var dismissedEventIDs: Set<String> = []
    /// Loop liveness, for the diagnostics report: the poll loop hanging is
    /// indistinguishable from "no data" in the UI, so count every pass.
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastTickAt: Date?

    private static let pollInterval: Duration = .seconds(20)
    /// 10-minute Google default reminder + the 2-minute head start.
    private static let meetingLead: TimeInterval = 12 * 60
    /// Keep the card up briefly past start ("Starting now"), then let go.
    private static let meetingLinger: TimeInterval = 2 * 60

    func attach(to store: TabStore) {
        self.store = store
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Right after launch the favorites are still loading, so
                // poll quickly until things warm up — a badge arriving 20s+
                // late reads as "not working". Settle to the slow cadence
                // once the first few passes are done.
                let warmingUp = (self?.tickCount ?? 0) < 6
                try? await Task.sleep(for: warmingUp ? .seconds(5) : Self.pollInterval)
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    /// The Settings toggle just flipped on — don't make the user wait out a
    /// poll interval to see something happen.
    func kick() {
        Task { await tick() }
    }

    func clear() {
        badgeCounts = [:]
        meeting = nil
    }

    /// The badge for a favorite chip, or nil when it has nothing to say.
    func badgeCount(for favorite: Favorite) -> Int? {
        guard let count = badgeCounts[favorite.id], count > 0 else { return nil }
        return count
    }

    func dismissCurrentMeeting() {
        guard let meeting else { return }
        dismissedEventIDs.insert(meeting.eventID)
        self.meeting = nil
    }

    /// Click-through (owner ask): land *on the meeting*, not just on
    /// Calendar — select the favorite, then click the event's own chip so
    /// Google Calendar opens its detail bubble.
    func openMeeting() {
        guard let store, let meeting,
              let favorite = store.favorites.first(where: { Self.isCalendar($0.url) }) else { return }
        store.openFavorite(favorite)
        // data-eventid is base64-flavoured; refuse anything that could
        // escape the querySelector string rather than trying to quote it.
        let id = meeting.eventID
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || "+/=_-".contains($0) }) else { return }
        let script = "(() => { const el = document.querySelector('[data-eventid=\"\(id)\"]'); if (el) el.click(); })()"
        store.backingTab(for: favorite)?.webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Polling

    private func tick() async {
        tickCount += 1
        lastTickAt = Date()
        guard let store, store.headsUpEnabled else { return }
        now = Date()
        var sawCalendar = false
        for favorite in store.favorites {
            let tab = store.ensureFavoriteTab(favorite)
            if Self.isCalendar(favorite.url) {
                sawCalendar = true
                await pollCalendar(tab)
            } else {
                await pollBadge(favorite, tab: tab, script: Self.badgeScript(for: favorite.url))
            }
        }
        if !sawCalendar { meeting = nil }
        // Removed favorites take their counts with them.
        badgeCounts = badgeCounts.filter { id, _ in store.favorites.contains { $0.id == id } }
    }

    /// Which page-reading script knows how to badge this favorite: Gmail's
    /// title parse, or the Home Assistant probe for everything else (any
    /// host — HA is self-hosted, so it's detected by the page, not the
    /// domain; on a non-HA page the probe answers "can't tell" forever and
    /// no badge ever appears).
    nonisolated static func badgeScript(for url: URL) -> String {
        isGmail(url) ? gmailUnreadScript : homeAssistantBadgeScript
    }

    private func pollBadge(_ favorite: Favorite, tab: BrowserTab, script: String) async {
        guard let webView = tab.webView else { return }
        // -1 means "can't tell right now" (mid-load, signed out, not a page
        // this script understands) — keep the last known count instead of
        // flickering, and never badge a page we can't actually read.
        if let count = await evaluate(script, in: webView) as? Int, count >= 0 {
            badgeCounts[favorite.id] = count
        }
    }

    private func pollCalendar(_ tab: BrowserTab) async {
        guard let webView = tab.webView else { return }
        guard let chips = await readCalendarChips(from: webView) else { return }
        let candidates = chips.compactMap { Self.parseEvent(id: $0.id, label: $0.label, now: now) }
        meeting = candidates
            .filter { !dismissedEventIDs.contains($0.eventID) }
            .filter { $0.start.timeIntervalSince(now) <= Self.meetingLead }
            .filter { now.timeIntervalSince($0.start) <= Self.meetingLinger }
            .min { $0.start < $1.start }
    }

    private func readCalendarChips(from webView: WKWebView) async -> [EventChip]? {
        guard let json = await evaluate(Self.calendarEventsScript, in: webView) as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([EventChip].self, from: data)
    }

    // MARK: - Diagnostics (Develop menu)

    /// A plain-text dump of exactly what the poll sees right now, so "the
    /// card didn't show" is debuggable from a single paste instead of
    /// guesswork about Google's DOM shape on the owner's account.
    func diagnosticsReport() async -> String {
        var lines: [String] = ["Heads-up diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))"]
        guard let store else { return "no TabStore attached" }
        lines.append("enabled: \(store.headsUpEnabled)")
        lines.append("poll loop: \(tickCount) ticks, last \(lastTickAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")")
        lines.append("favorites: " + store.favorites.map { "\($0.url.host() ?? "?")" }.joined(separator: ", "))

        for favorite in store.favorites where !Self.isCalendar(favorite.url) {
            let host = favorite.url.host() ?? "?"
            let kind = Self.isGmail(favorite.url) ? "gmail" : "badge-probe"
            let tab = store.ensureFavoriteTab(favorite)
            lines.append("\(host) [\(kind)]: webView=\(tab.webView == nil ? "nil" : "live") loading=\(tab.isLoading) title=\(tab.title)")
            if let webView = tab.webView {
                let script = Self.badgeScript(for: favorite.url)
                let raw = await evaluate(script, in: webView)
                lines.append("  script result: \(raw.map { "\($0)" } ?? "nil (evaluation failed)")  published: \(badgeCounts[favorite.id].map(String.init) ?? "nil")")
            }
        }

        if let calendar = store.favorites.first(where: { Self.isCalendar($0.url) }) {
            let tab = store.ensureFavoriteTab(calendar)
            lines.append("calendar tab: webView=\(tab.webView == nil ? "nil" : "live") loading=\(tab.isLoading) url=\(tab.url?.absoluteString ?? "nil")")
            if let webView = tab.webView {
                if let chips = await readCalendarChips(from: webView) {
                    lines.append("calendar chips: \(chips.count)")
                    let reference = Date()
                    for chip in chips.prefix(40) {
                        let label = chip.label.count > 160 ? chip.label.prefix(160) + "…" : chip.label[...]
                        if let parsed = Self.parseEvent(id: chip.id, label: chip.label, now: reference) {
                            let delta = Int(parsed.start.timeIntervalSince(reference) / 60)
                            var verdict = "start \(parsed.start.formatted(date: .omitted, time: .shortened)) (\(delta)m away) title \"\(parsed.title)\""
                            if dismissedEventIDs.contains(parsed.eventID) { verdict += " [dismissed]" }
                            else if parsed.start.timeIntervalSince(reference) > Self.meetingLead { verdict += " [beyond 12m lead]" }
                            else if reference.timeIntervalSince(parsed.start) > Self.meetingLinger { verdict += " [already past]" }
                            else { verdict += " [WOULD SHOW]" }
                            lines.append("  ✓ \(verdict) — \(label)")
                        } else {
                            lines.append("  ✗ unparsed — \(label)")
                        }
                    }
                } else {
                    lines.append("calendar chips: script returned nothing (evaluation failed or non-JSON)")
                }
            }
        } else {
            lines.append("calendar: no matching favorite")
        }

        lines.append("published meeting: \(meeting.map { "\($0.title) @ \($0.start.formatted(date: .omitted, time: .shortened))" } ?? "nil")")
        return lines.joined(separator: "\n")
    }

    /// The async `evaluateJavaScript` overload traps on a nil/undefined
    /// result; the completion-handler form just hands us nil. Always use it.
    /// Timeboxed: on a freshly-created, still-loading webview the completion
    /// can fail to arrive, and one missing callback must not hang the poll
    /// loop's `await` forever (launch symptom: badges never appear until the
    /// Settings toggle forces a fresh poll). Everything here is MainActor,
    /// so the resume-once flag needs no synchronization.
    private func evaluate(_ script: String, in webView: WKWebView) async -> Any? {
        final class ResumeOnce { var done = false }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Page reading

    nonisolated static func isGmail(_ url: URL) -> Bool {
        (url.host() ?? "").hasSuffix("mail.google.com")
    }

    nonisolated static func isCalendar(_ url: URL) -> Bool {
        (url.host() ?? "").hasSuffix("calendar.google.com")
    }

    /// Gmail keeps the inbox unread count in the tab title — "Inbox (12) -
    /// you@gmail.com - Gmail" — which is the most stable thing on a page
    /// whose class names are obfuscated and churn. The aria-label on the
    /// inbox nav row ("Inbox 12 unread") is the fallback; a title that's on
    /// the inbox with no parenthesised count is a real zero.
    nonisolated private static let gmailUnreadScript = """
    (() => {
      const title = document.title;
      const m = title.match(/\\((\\d[\\d,.\\u202F\\u00A0]*)\\)/);
      if (m) return parseInt(m[1].replace(/\\D/g, ""), 10);
      const nav = document.querySelector('[aria-label*="unread"]');
      if (nav) {
        const n = (nav.getAttribute("aria-label") || "").match(/(\\d[\\d,]*)\\s+unread/);
        if (n) return parseInt(n[1].replace(/\\D/g, ""), 10);
      }
      if (/^Inbox\\b/.test(title)) return 0;
      return -1;
    })()
    """

    /// Home Assistant's Settings badge, read from the app's own `hass`
    /// object on the page (stable public surface for years) rather than
    /// spelunking its nested shadow DOM: the count is update entities with
    /// updates pending — which is what the sidebar's orange badge shows.
    /// (Repair issues also feed HA's badge but only exist behind a
    /// websocket call; updates cover the everyday case.) Returns -1 when
    /// this isn't a Home Assistant page at all, so it's safe to probe any
    /// favorite — HA is self-hosted and can live on any domain.
    nonisolated private static let homeAssistantBadgeScript = """
    (() => {
      const ha = document.querySelector("home-assistant");
      if (!ha || !ha.hass || !ha.hass.states) return -1;
      let n = 0;
      for (const id in ha.hass.states) {
        if (id.indexOf("update.") === 0 && ha.hass.states[id].state === "on") n++;
      }
      return n;
    })()
    """

    /// Best-effort scrape of Calendar's event chips. `data-eventid` marks a
    /// chip in every view (day/week/month); the details live in its
    /// screen-reader text (`.XuJrye`, obfuscated but stable for years) or
    /// aria-label — "10:30am to 11:30am, Standup, Keran McKenzie, …". The
    /// raw labels go back to Swift, which does the locale-ish parsing.
    private static let calendarEventsScript = """
    (() => {
      const items = [];
      const seen = new Set();
      document.querySelectorAll("[data-eventid]").forEach((el) => {
        const id = el.getAttribute("data-eventid") || "";
        if (!id || seen.has(id)) return;
        const sr = el.querySelector(".XuJrye");
        const label = ((sr && sr.textContent) || el.getAttribute("aria-label") || "").trim();
        if (!label) return;
        seen.add(id);
        items.push({ id: id, label: label });
      });
      return JSON.stringify(items);
    })()
    """

    private struct EventChip: Decodable {
        let id: String
        let label: String
    }

    // MARK: - Label parsing

    /// "10:30am to 11:30am", "10 – 11am", "14:00-15:00" — the time range in
    /// an event chip's accessible label.
    nonisolated private static let timeRange =
        #/(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:to|–|—|−|-)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/#
            .ignoresCase()

    /// A lone start time ("10:30am, Standup, …" — month view has no end).
    /// Requires minutes or a meridiem so a bare "11" in a title never counts.
    nonisolated private static let singleTime =
        #/(\d{1,2}):(\d{2})\s*(am|pm)?|(\d{1,2})\s*(am|pm)/#
            .ignoresCase()

    nonisolated private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]
    nonisolated private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    /// One chip label → a Meeting today, or nil (all-day event, another day's
    /// chip in week/month view, or nothing parseable). Deliberately lenient:
    /// a missed event costs a card, a wrong one costs a dismissal.
    nonisolated static func parseEvent(id: String, label: String, now: Date) -> Meeting? {
        let calendar = Calendar.current
        let lower = label.lowercased()

        // Week/month views hand us other days' chips too. Labels that name a
        // day only count if it's today's; the title itself might contain a
        // weekday ("Monday sync"), so this stays a cheap filter, not proof.
        let todayWeekday = weekdayNames[calendar.component(.weekday, from: now) - 1]
        if weekdayNames.contains(where: { lower.contains($0) }), !lower.contains(todayWeekday) {
            return nil
        }
        let todayMonth = monthNames[calendar.component(.month, from: now) - 1]
        let day = calendar.component(.day, from: now)
        if monthNames.contains(where: { lower.contains($0) }) {
            guard lower.contains(todayMonth),
                  lower.range(of: "\\b\(day)\\b", options: .regularExpression) != nil else { return nil }
        }

        var startHour: Int?, startMinute = 0
        var endHour: Int?, endMinute = 0
        var matchedRange: Range<String.Index>?

        if let match = label.firstMatch(of: timeRange) {
            matchedRange = match.range
            let endMeridiem = match.6.map { String($0).lowercased() }
            // "10 – 11am": the start inherits the end's meridiem…
            let startMeridiem = match.3.map { String($0).lowercased() } ?? endMeridiem
            startHour = hour24(Int(match.1), meridiem: startMeridiem)
            startMinute = match.2.flatMap { Int($0) } ?? 0
            endHour = hour24(Int(match.4), meridiem: endMeridiem)
            endMinute = match.5.flatMap { Int($0) } ?? 0
            // …unless that runs the event backwards ("11 to 12:30pm" is
            // 11am, not 11pm), in which case flip the inherited half back.
            if match.3 == nil, let s = startHour, let e = endHour,
               (s, startMinute) > (e, endMinute), s >= 12 {
                startHour = s - 12
            }
        } else if let match = label.firstMatch(of: singleTime) {
            matchedRange = match.range
            if let h = match.1 {
                startHour = hour24(Int(h), meridiem: match.3.map { String($0).lowercased() })
                startMinute = match.2.flatMap { Int($0) } ?? 0
            } else if let h = match.4 {
                startHour = hour24(Int(h), meridiem: match.5.map { String($0).lowercased() })
            }
        }

        guard let startHour,
              let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: now)
        else { return nil }
        var end: Date?
        if let endHour {
            end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: now)
        }

        return Meeting(eventID: id, title: title(from: label, excluding: matchedRange), start: start, end: end)
    }

    nonisolated private static func hour24(_ hour: Int?, meridiem: String?) -> Int? {
        guard let hour, (0...23).contains(hour) else { return nil }
        switch meridiem {
        case "am": return hour == 12 ? 0 : hour
        case "pm": return hour == 12 ? 12 : (hour < 12 ? hour + 12 : nil)
        default: return hour
        }
    }

    /// The title is whichever comma-chunk of the label isn't the time range,
    /// a date, an RSVP state, or one of Calendar's "Location:"-style fields —
    /// chunk order varies by view, so filter rather than index.
    nonisolated private static func title(from label: String, excluding matched: Range<String.Index>?) -> String {
        var remainder = label
        if let matched { remainder.removeSubrange(matched) }
        let boilerplate: Set<String> = [
            "accepted", "declined", "maybe", "tentative", "needs rsvp",
            "no location", "busy", "free", "all day",
        ]
        let chunks = remainder.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        }
        let survivor = chunks.first { chunk in
            guard !chunk.isEmpty else { return false }
            let lower = chunk.lowercased()
            if boilerplate.contains(lower) { return false }
            if ["calendar", "location", "organizer", "organiser"].contains(where: { lower.hasPrefix("\($0):") }) { return false }
            if weekdayNames.contains(where: { lower.contains($0) }) { return false }
            if monthNames.contains(where: { lower.contains($0) }) { return false }
            if chunk.firstMatch(of: singleTime) != nil { return false }
            if chunk.allSatisfy({ $0.isNumber }) { return false }
            return true
        }
        return survivor ?? "Upcoming meeting"
    }
}

// MARK: - Views

/// The unread-count chip on a favorite glyph. Accent teal, not alarm red —
/// same restrained register as the rest of the rail.
struct HeadsUpBadge: View {
    let count: Int
    var compact = false

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Tokens.font(compact ? 8.5 : 9.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 3.5 : 4.5)
            .frame(minWidth: compact ? 14 : 16, minHeight: compact ? 14 : 16)
            .background(Capsule().fill(Tokens.accent))
            .overlay(Capsule().strokeBorder(Tokens.canvas, lineWidth: 1.5))
    }
}

/// The meeting card, sitting in the rail just under the favorites grid it
/// came from. The whole card is the click-through to the meeting; the X
/// dismisses this event for the rest of the session.
struct HeadsUpMeetingCard: View {
    @Bindable var store: TabStore
    let meeting: HeadsUpStore.Meeting

    var body: some View {
        Button {
            store.headsUp.openMeeting()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(countdown)
                        .font(Tokens.font(10.5, .semibold))
                        .foregroundStyle(Tokens.accent)
                    Text(meeting.title)
                        .font(Tokens.font(13, .semibold))
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(timeRange)
                        .font(Tokens.font(11.5))
                        .foregroundStyle(Tokens.inkFaint)
                }

                Spacer(minLength: 0)

                Button {
                    store.headsUp.dismissCurrentMeeting()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Tokens.inkGhost)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Tokens.accentWash)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Open in Google Calendar")
    }

    private var countdown: String {
        let seconds = meeting.start.timeIntervalSince(store.headsUp.now)
        guard seconds > 0 else { return "Starting now" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes == 1 ? "In 1 minute" : "In \(minutes) minutes"
    }

    private var timeRange: String {
        let start = meeting.start.formatted(date: .omitted, time: .shortened)
        guard let end = meeting.end else { return start }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
