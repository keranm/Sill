import Foundation

/// Domain identity and display naming for learned surfaces.
enum DisplayNames {

    /// The domain identity a visit is recorded and grouped under.
    ///
    /// Deliberately **not** pure eTLD+1 (a documented deviation from PRD
    /// §3.1's literal "registrable domain" field, extending the precedent
    /// already set for mail.google.com/calendar.google.com in M5): a shared
    /// registrable domain routinely hosts several distinct, meaningfully
    /// different destinations — Google's app family, and just as often
    /// someone's own domain fronting several self-hosted services
    /// (home.example.com for Home Assistant, git.example.com for Gitea,
    /// grafana.example.com for dashboards). Collapsing those to one identity
    /// loses exactly the distinction the learning engine needs, and — worse —
    /// makes it impossible to reconstruct the right host when a confirmed
    /// pattern births a workspace.
    ///
    /// The rule: keep the host as observed, stripping only cosmetic mirror
    /// prefixes (www., m., amp.) that genuinely are the same site. Still just
    /// a hostname — still metadata, still nothing from the page itself.
    private static let mirrorPrefixes = ["www.", "m.", "amp."]

    static func observationDomain(for host: String) -> String {
        var lowered = host.lowercased()
        for prefix in mirrorPrefixes where lowered.hasPrefix(prefix) {
            lowered = String(lowered.dropFirst(prefix.count))
            break
        }
        return lowered
    }

    private static let friendly: [String: String] = [
        "mail.google.com": "Mail", "calendar.google.com": "Calendar",
        "docs.google.com": "Docs", "drive.google.com": "Drive",
        "meet.google.com": "Meet", "sheets.google.com": "Sheets",
        "slides.google.com": "Slides", "keep.google.com": "Keep",
        "photos.google.com": "Photos",
        "outlook.live.com": "Outlook", "outlook.office.com": "Outlook",
        "teams.microsoft.com": "Teams", "onedrive.live.com": "OneDrive",
        "github.com": "GitHub", "news.ycombinator.com": "Hacker News",
        "youtube.com": "YouTube", "linkedin.com": "LinkedIn",
        "stackoverflow.com": "Stack Overflow",
    ]

    /// Human name for a learned domain: known apps by name, else the
    /// leading label capitalised ("figma.com" → "Figma",
    /// "home.keranmckenzie.com" → "Home"). IP literals pass through as-is.
    static func displayName(for domain: String) -> String {
        if let known = friendly[domain.lowercased()] { return known }
        if domain.first(where: { $0.isLetter }) == nil { return domain } // IP / no letters
        let sld = domain.split(separator: ".").first.map(String.init) ?? domain
        return sld.prefix(1).uppercased() + sld.dropFirst()
    }

    /// "Mail, Calendar and Figma"
    static func list(_ domains: [String]) -> String {
        let names = domains.map(displayName(for:))
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
