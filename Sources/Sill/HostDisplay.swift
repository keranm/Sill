import Foundation

/// Host-related display rules for the header readout (PRD §4.1).
enum HostDisplay {

    // MARK: Registrable domain

    /// Common multi-part public suffixes. A full PSL is overkill for the PoC;
    /// this covers the owner's real traffic. Tune if the readout ever lies.
    private static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz", "govt.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "co.in", "co.za", "co.kr", "com.br", "com.mx", "com.ar",
        "com.sg", "com.hk", "com.tw", "com.cn", "com.tr",
    ]

    /// eTLD+1 of a host ("docs.github.com" → "github.com").
    /// IPs and single labels pass through unchanged.
    static func registrableDomain(of host: String) -> String {
        let lowered = host.lowercased()
        if isIPAddress(lowered) { return lowered }
        let labels = lowered.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return lowered }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoPartSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: Homoglyph policy (PRD §4.1)

    /// IDN labels render in Unicode only when every decoded label is
    /// single-script; anything mixed or undecodable stays punycode.
    static func displayHost(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.contains(where: { $0.lowercased().hasPrefix("xn--") }) else {
            return host
        }
        var decoded: [String] = []
        for label in labels {
            if label.lowercased().hasPrefix("xn--") {
                guard let unicode = Punycode.decode(String(label.dropFirst(4))),
                      isSingleScript(unicode) else {
                    return host // any doubt → punycode for the whole host
                }
                decoded.append(unicode)
            } else {
                decoded.append(label)
            }
        }
        return decoded.joined(separator: ".")
    }

    /// Coarse script classification; digits and hyphen are neutral,
    /// combining marks are always suspicious.
    private static func isSingleScript(_ label: String) -> Bool {
        var seen: Script?
        for scalar in label.unicodeScalars {
            guard let script = Script(scalar) else { return false } // unknown → suspicious
            if script == .neutral { continue }
            if let seen, seen != script { return false }
            seen = script
        }
        return true
    }

    private enum Script: Equatable {
        case neutral, latin, cyrillic, greek, cjk, hangul, arabic, hebrew, thai, devanagari

        init?(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x30...0x39, 0x2D: self = .neutral
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0xFF, 0x100...0x17F: self = .latin
            case 0x300...0x36F: return nil // combining marks
            case 0x370...0x3FF: self = .greek
            case 0x400...0x4FF: self = .cyrillic
            case 0x590...0x5FF: self = .hebrew
            case 0x600...0x6FF: self = .arabic
            case 0x900...0x97F: self = .devanagari
            case 0xE00...0xE7F: self = .thai
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF: self = .cjk
            case 0xAC00...0xD7AF, 0x1100...0x11FF: self = .hangul
            default: return nil
            }
        }
    }

    // MARK: Path-or-title rule

    /// "Show path if ≤ 40 chars and human-readable, else title."
    static func pathIsShowable(_ path: String) -> Bool {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains("%") else { return false }
        for segment in trimmed.split(separator: "/") {
            if segment.count > 28 { return false }
            var digitRun = 0, hexRun = 0
            for character in segment {
                digitRun = character.isNumber ? digitRun + 1 : 0
                hexRun = character.isHexDigit ? hexRun + 1 : 0
                if digitRun >= 7 || hexRun >= 14 { return false } // ID-shaped slug
            }
        }
        return true
    }
}

/// RFC 3492 punycode decoding — just enough for display.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    static func decode(_ input: String) -> String? {
        var output: [Unicode.Scalar] = []
        var inputScalars = Array(input.unicodeScalars)

        // Basic code points come before the last delimiter.
        if let delimiterIndex = inputScalars.lastIndex(of: "-") {
            for scalar in inputScalars[..<delimiterIndex] {
                guard scalar.value < 128 else { return nil }
                output.append(scalar)
            }
            inputScalars = Array(inputScalars[(delimiterIndex + 1)...])
        }

        var n = initialN, i = 0, bias = initialBias
        var position = 0

        while position < inputScalars.count {
            let oldI = i
            var weight = 1
            var k = base
            while true {
                guard position < inputScalars.count,
                      let digit = digitValue(inputScalars[position]) else { return nil }
                position += 1
                let step = digit * weight
                if step / weight != digit { return nil } // overflow
                i += step
                if i < 0 { return nil }
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                weight *= base - t
                if weight < 0 { return nil }
                k += base
            }
            let handled = output.count + 1
            bias = adapt(delta: i - oldI, numPoints: handled, firstTime: oldI == 0)
            n += i / handled
            i %= handled
            guard let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }

        var result = ""
        result.unicodeScalars.append(contentsOf: output)
        return result
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value - 0x30 + 26) // 0-9
        case 0x41...0x5A: return Int(scalar.value - 0x41)      // A-Z
        case 0x61...0x7A: return Int(scalar.value - 0x61)      // a-z
        default: return nil
        }
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * delta) / (delta + skew)
    }
}
