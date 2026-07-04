import Foundation

/// Sensitive-domain exclusion, on by default (PRD §3.3). Excluded visits are
/// never recorded in any form — no rows, no counts, no hashes — during live
/// observation *and* during history import.
///
/// Deterministic and deliberately over-broad: excluding too much is the safe
/// failure. Categories: banking, health, government, adult, plus user-added.
enum ExclusionList {

    /// Suffix rules (matched against the end of the registrable domain).
    private static let excludedSuffixes: [String] = [
        ".gov", ".gov.au", ".gov.uk", ".gov.nz", ".mil", ".nhs.uk",
    ]

    /// Exact registrable domains: banks and payments (AU-weighted plus
    /// global), health, and known sensitive services.
    private static let excludedDomains: Set<String> = [
        // Banking / payments — Australia
        "commbank.com.au", "netbank.com.au", "nab.com.au", "anz.com",
        "westpac.com.au", "macquarie.com.au", "macquarie.com", "ing.com.au",
        "bendigobank.com.au", "boq.com.au", "suncorp.com.au", "amp.com.au",
        "ubank.com.au", "up.com.au", "greatsouthernbank.com.au",
        // Banking / payments — global
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citibank.com",
        "hsbc.com", "barclays.co.uk", "lloydsbank.com", "natwest.com",
        "monzo.com", "revolut.com", "wise.com", "n26.com", "starlingbank.com",
        "paypal.com", "venmo.com", "cash.app", "stripe.com",
        // Superannuation / investing
        "australiansuper.com", "aware.com.au", "hostplus.com.au", "rest.com.au",
        "vanguard.com.au", "stake.com.au", "commsec.com.au", "selfwealth.com.au",
        "fidelity.com", "schwab.com", "etrade.com", "robinhood.com",
        // Crypto exchanges
        "coinbase.com", "binance.com", "kraken.com", "coinspot.com.au",
        // Health
        "healthdirect.gov.au", "medicare.gov.au", "myhealthrecord.gov.au",
        "hotdoc.com.au", "healthengine.com.au", "nib.com.au", "bupa.com.au",
        "medibank.com.au", "hcf.com.au", "ahm.com.au",
        "betterhelp.com", "headspace.com", "talkspace.com", "calm.com",
        "webmd.com", "mayoclinic.org", "drugs.com", "goodrx.com",
        "23andme.com", "ancestry.com",
        // Adult
        "onlyfans.com", "fansly.com",
    ]

    /// Keyword rules on the registrable domain (not the path — paths are
    /// content-adjacent and we do not inspect them for this).
    private static let excludedKeywords: [String] = [
        "porn", "xxx", "hentai", "xvideos", "xhamster", "redtube",
        "onlyfans", "sexchat", "escort",
        "bank", // catches bankwest, bankaust, tsb-bank… over-broad by design
    ]

    static func isExcluded(domain: String, userAdded: Set<String>) -> Bool {
        let lowered = domain.lowercased()
        if userAdded.contains(lowered) { return true }
        if excludedDomains.contains(lowered) { return true }
        for suffix in excludedSuffixes {
            // ".nhs.uk" must catch nhs.uk itself as well as its subdomains.
            if lowered.hasSuffix(suffix) || lowered == String(suffix.dropFirst()) { return true }
        }
        for keyword in excludedKeywords {
            if lowered.contains(keyword) { return true }
        }
        return false
    }

    /// The defaults shown on the Learning page's never-observed list (M5).
    static var defaultDescription: String {
        "Private windows. Banking and health sites, by category. Government sites. Adult sites."
    }
}
