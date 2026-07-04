import Foundation

/// The header readout is a security surface (PRD §4.1). One state per tab,
/// derived from the committed URL, mixed-content status, and TLS failures.
enum SecurityState: Equatable {
    /// Nothing loaded yet (new tab, about:blank).
    case blank
    /// HTTPS, nothing insecure loaded. Per §8.6 this renders with no padlock —
    /// quiet is the default state, only danger gets marked.
    case secure
    /// Plain HTTP: warning treatment + plain-sentence explanation on click.
    case insecureHTTP
    /// HTTPS page that loaded insecure subresources.
    case mixedContent
    /// TLS/certificate failure: full interstitial, product voice.
    case certificateFailure(host: String, reason: String)

    var isNegative: Bool {
        switch self {
        case .blank, .secure: return false
        case .insecureHTTP, .mixedContent, .certificateFailure: return true
        }
    }

    /// The plain-sentence explanation shown on click (D3 register: factual,
    /// full sentences, no theatre).
    var explanation: String? {
        switch self {
        case .blank, .secure:
            return nil
        case .insecureHTTP:
            return "This page travelled over plain HTTP. Anyone on the network between you and the site could read it or change it."
        case .mixedContent:
            return "The page itself is encrypted, but it loaded parts over plain HTTP. Those parts could have been read or changed in transit."
        case .certificateFailure(let host, let reason):
            return "\(host) presented a certificate that can't be verified — \(reason) What arrived may not be from the site at all."
        }
    }
}
