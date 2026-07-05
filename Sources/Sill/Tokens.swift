import SwiftUI
import CoreText

/// The design-token layer, translated from the design package (PRD §2: names
/// preserved, values are the build contract). Light mode first (PRD §8.1);
/// dark values kept alongside so dark stays cheap.
///
/// Accent hexes are the sRGB projection of the package's OKLCH values:
/// oklch(0.54 0.08 195) → #267D7D, oklch(0.72 0.08 195) → #63B5B4.
enum Tokens {
    // MARK: Colour

    /// Warm paper the whole window sits on.
    static let canvas = Color(hex: 0xFBFAF8)
    /// Recessed surfaces: fields, chips, the switcher popover.
    static let well = Color(hex: 0xF3F1EC)
    /// Text.
    static let ink = Color(hex: 0x21201C)
    /// Secondary text — evidence lines, paths, resting tab counts.
    static let inkFaint = Color(hex: 0x21201C).opacity(0.55)
    /// Tertiary — section labels, hints, dormant facts.
    static let inkGhost = Color(hex: 0x21201C).opacity(0.35)
    /// Hairline borders.
    static let hairline = Color(hex: 0x21201C).opacity(0.08)
    /// Still-water teal. Jobs: focus rings, active workspace dot, confirm
    /// action, noticed-card wash. Nothing decorative.
    static let accent = Color(hex: 0x267D7D)
    static let accentDark = Color(hex: 0x63B5B4)
    /// The teal wash behind noticed cards (accent at low opacity over canvas).
    static let accentWash = Color(hex: 0x267D7D).opacity(0.07)
    /// Negative security states. Provisional values pending tokens.css —
    /// restrained, no red alarm theatre.
    static let warning = Color(hex: 0x8F5B22)
    static let danger = Color(hex: 0xA94A42)
    /// Page stage behind web content.
    static let stage = Color.white

    // MARK: Type

    static let fontFamily = "Instrument Sans"

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(fontFamily, size: size).weight(weight)
    }

    // MARK: Metrics

    static let railWidth: CGFloat = 216
    static let radiusStage: CGFloat = 10
    static let radiusControl: CGFloat = 7
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Registers the bundled Instrument Sans variable fonts (PRD §3.2: no network
/// fonts). Process-scoped; works from both `swift run` and the app bundle.
enum FontLoader {
    static func registerBundledFonts() {
        guard let urls = BundledResources.bundle?.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"),
              !urls.isEmpty else {
            NSLog("Sill: bundled fonts missing — falling back to system font")
            return
        }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}
