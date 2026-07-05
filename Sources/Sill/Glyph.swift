import SwiftUI

/// No-network favicon stand-in (PRD §3.2 bans our own fetches): a letter chip,
/// muted and stable per-domain. Shared by tab rows, Quick Look, and Favorites.
enum Glyph {
    private static let palette: [Color] = [
        Color(hex: 0x267D7D), Color(hex: 0x7D6226), Color(hex: 0x5B4E8F),
        Color(hex: 0x8F4E62), Color(hex: 0x4E6F8F), Color(hex: 0x5F7D3A),
    ]

    static func letter(for url: URL?) -> String {
        guard let host = url?.host() else { return "•" }
        let domain = DisplayNames.observationDomain(for: host)
        return domain.first.map { String($0).uppercased() } ?? "•"
    }

    static func color(for url: URL?) -> Color {
        guard let host = url?.host() else { return Tokens.inkFaint }
        let domain = DisplayNames.observationDomain(for: host)
        var hash = 5381
        for byte in domain.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// The letter chip, or a real favicon if this domain was cached by a
/// previous favoriting (FaviconStore) — read-only, never triggers a fetch.
struct GlyphView: View {
    let url: URL?
    var size: CGFloat = 15
    var cornerRadius: CGFloat = 3.5

    var body: some View {
        if let image = FaviconStore.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            Text(Glyph.letter(for: url))
                .font(.system(size: size * 0.63, weight: .semibold))
                .foregroundStyle(Glyph.color(for: url))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Glyph.color(for: url).opacity(0.12)))
        }
    }
}
