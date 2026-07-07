import Foundation
import CryptoKit

/// Resolves `{name}` tokens across the API client — plain environment
/// variables, built-in dynamic values, and computed expressions — all
/// through the *same* single-brace notation used for OpenAPI path
/// parameters (`APIClientView.substitute(path:using:)`), so there's exactly
/// one notation in the tool rather than two.
///
/// An environment variable's stored value is either a plain literal (the
/// common case — pasted straight back out) or, if it looks like a function
/// call (`md5(...)`, `hmacSha256(...)`, etc.), a computed expression
/// re-evaluated on every substitution. This needs no schema change — the
/// heuristic is "does the trimmed value start with `identifier("`" — because
/// a real API value is never going to coincidentally look like that.
enum APIVariableResolver {
    /// Reserved names available in every request regardless of which
    /// environment (if any) is selected — Postman's `{{$timestamp}}`-style
    /// dynamic variables, just single-braced here. `$path` is special: it's
    /// only meaningful during `resolve(url:...)`'s own multi-pass
    /// substitution (see below) and isn't advertised outside it.
    private static let dynamicNames = ["$timestamp", "$timestampMs", "$isoTimestamp", "$guid"]

    /// Every `$`-prefixed reserved name, `$path`/`$query` included — used by
    /// the editor's inline `{variable}` colour coding to mark these as
    /// "always resolves" (its own colour) regardless of which environment is
    /// active, distinct from a plain `{name}` that's only green when it
    /// actually exists in the selected environment.
    static let builtinNames: Set<String> = Set(dynamicNames + ["$path", "$query"])

    /// All `{name}` tokens this resolver would recognize right now — used to
    /// avoid scanning `text` for names that can't possibly be there (and,
    /// critically, to never touch a `{...}` group that isn't a known
    /// variable — stray JSON braces in a body must survive untouched).
    static func knownNames(environment: APIEnvironment?, extra: [String] = []) -> [String] {
        dynamicNames + extra + (environment?.variables.keys.map { $0 } ?? [])
    }

    /// Substitutes every known `{name}` token in `text`. Unknown `{...}`
    /// groups (JSON braces, literal curly text) are left exactly as typed.
    ///
    /// A signature recipe like `md5({$path} + "\r\n" + {token} + "\r\n" +
    /// {$timestamp})` is just as likely to get typed directly into a header
    /// value as it is into a named environment variable — so before doing
    /// per-token replacement, check whether the *whole* field is itself a
    /// computed expression and evaluate it whole. Token replacement only
    /// runs when it isn't, so a bare `{token}` reference still works and
    /// unrelated `{...}` groups (JSON braces) are never touched.
    static func substitute(_ text: String, environment: APIEnvironment?, extra: [String: String] = [:]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let expression = APIExpressionParser.parseComputed(trimmed) {
            return APIExpressionEvaluator.evaluate(expression) { name in
                resolvedValue(for: name, environment: environment, extra: extra, visited: [])
            }
        }

        var result = text
        for name in knownNames(environment: environment, extra: Array(extra.keys)) {
            let token = "{\(name)}"
            guard result.contains(token) else { continue }
            result = result.replacingOccurrences(of: token, with: resolvedValue(for: name, environment: environment, extra: extra, visited: []))
        }
        return result
    }

    /// The request-URL-aware entry point `send()` actually uses: a first
    /// pass resolves plain/computed variables in the URL so `{$path}` has
    /// something real to extract from, then a second pass resolves
    /// everything (URL, headers, body) with `{$path}` now available —
    /// letting a signature expression reference the path Postman-style
    /// (`md5({$path} + "\r\n" + {token} + "\r\n" + {$timestamp})`) without a
    /// separate manual step to copy it in. `extra` should carry the same
    /// frozen `$timestamp`/`$timestampMs`/etc. snapshot the caller is about
    /// to use for the rest of the request — see `frozenDynamicValues()`.
    ///
    /// `$path` is deliberately query-string-free — FoxESS's own docs for
    /// this exact signature recipe are explicit that "the path does not
    /// include the domain or query parameters in the signature string," and
    /// a `GET .../plant/detail?id=...` request confirmed it by hand:
    /// signing with the query string included reproduces the signature
    /// Sill actually sent (and got rejected), while signing the bare path
    /// matches what the API expects. A path parameter still belongs in the
    /// real request URL — just not folded into what gets hashed by default.
    ///
    /// `$query` (the raw query string, no leading `?`) is split out
    /// separately rather than bundled back into `$path`, so a recipe that
    /// *does* want the query included can still write `{$path}?{$query}`
    /// explicitly instead of losing access to it entirely.
    static func resolvedPathAndQuery(fromSubstitutedURL urlText: String, environment: APIEnvironment?, extra: [String: String] = [:]) -> (path: String, query: String) {
        let resolvedURL = substitute(urlText, environment: environment, extra: extra)
        guard let components = URLComponents(string: resolvedURL) else { return (resolvedURL, "") }
        return (components.path, components.query ?? "")
    }

    /// A single snapshot of every `$`-prefixed built-in, taken once per
    /// request. Without this, `{$timestampMs}` referenced in both a
    /// `timestamp` header and a `signature` header (the exact FoxESS-style
    /// recipe this tool exists for) would each call `Date()` independently
    /// — almost always the same millisecond, but not guaranteed, and a
    /// signature scheme has no tolerance for "almost always." One instant,
    /// reused everywhere it's referenced, removes the race entirely. Pass
    /// the result back in as `substitute`'s `extra`, merged with `$path`
    /// once that's known.
    static func frozenDynamicValues(at now: Date = Date()) -> [String: String] {
        [
            "$timestamp": String(Int(now.timeIntervalSince1970)),
            "$timestampMs": String(Int(now.timeIntervalSince1970 * 1000)),
            "$isoTimestamp": ISO8601DateFormatter().string(from: now),
            "$guid": UUID().uuidString,
        ]
    }

    private static func resolvedValue(for name: String, environment: APIEnvironment?, extra: [String: String], visited: Set<String>) -> String {
        guard !visited.contains(name) else { return "" }
        var visited = visited
        visited.insert(name)

        if let value = extra[name] { return value }
        if let value = dynamicValue(for: name) { return value }
        guard let raw = environment?.variables[name] else { return "" }

        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let expression = APIExpressionParser.parseComputed(trimmed) {
            return APIExpressionEvaluator.evaluate(expression) { referencedName in
                resolvedValue(for: referencedName, environment: environment, extra: extra, visited: visited)
            }
        }
        return raw
    }

    private static func dynamicValue(for name: String) -> String? {
        switch name {
        case "$timestamp": return String(Int(Date().timeIntervalSince1970))
        case "$timestampMs": return String(Int(Date().timeIntervalSince1970 * 1000))
        case "$isoTimestamp": return ISO8601DateFormatter().string(from: Date())
        case "$guid": return UUID().uuidString
        default: return nil
        }
    }
}

// MARK: - Expression AST + parser

indirect enum APIExpr {
    case literal(String)
    case variable(String)
    case concat([APIExpr])
    case call(String, [APIExpr])
}

/// A tiny recursive-descent parser for the one shape of expression this tool
/// supports: string literals, `{name}` references, `+` concatenation, and
/// function calls — enough to express an HMAC/MD5 signature recipe like
/// FoxESS's `md5(url + "\r\n" + token + "\r\n" + timestamp)`, deliberately
/// not a general scripting language (developer-tools.md #3: "no scripting").
enum APIExpressionParser {
    private static let functionNames: Set<String> = [
        "md5", "sha1", "sha256", "hmacSha256", "hmacSha1", "base64", "upper", "lower", "urlEncode", "concat"
    ]

    /// Returns nil (meaning: treat as a plain literal) unless `text` starts
    /// with a recognized function name followed by `(` — the heuristic that
    /// lets computed values live in the same plain `[String: String]`
    /// variable storage as everything else.
    static func parseComputed(_ text: String) -> APIExpr? {
        var parser = Parser(text)
        guard let name = parser.peekIdentifier(), functionNames.contains(name) else { return nil }
        guard let expr = try? parser.parseExpression(), parser.isAtEnd else { return nil }
        return expr
    }

    private struct Parser {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) { chars = Array(text) }

        var isAtEnd: Bool { index >= chars.count }

        private func peek() -> Character? { index < chars.count ? chars[index] : nil }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { index += 1 }
        }

        func peekIdentifier() -> String? {
            var i = index
            guard i < chars.count, chars[i].isLetter || chars[i] == "_" || chars[i] == "$" else { return nil }
            var name = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" {
                name.append(chars[i])
                i += 1
            }
            return name
        }

        private mutating func readIdentifier() -> String {
            var name = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "$" {
                name.append(c)
                index += 1
            }
            return name
        }

        enum ParseError: Error { case malformed }

        mutating func parseExpression() throws -> APIExpr {
            var parts = [try parseTerm()]
            skipWhitespace()
            while peek() == "+" {
                index += 1
                skipWhitespace()
                parts.append(try parseTerm())
                skipWhitespace()
            }
            return parts.count == 1 ? parts[0] : .concat(parts)
        }

        private mutating func parseTerm() throws -> APIExpr {
            skipWhitespace()
            guard let c = peek() else { throw ParseError.malformed }
            if c == "\"" { return try parseStringLiteral() }
            if c == "{" { return try parseVariable() }
            if c.isLetter || c == "_" || c == "$" { return try parseCall() }
            throw ParseError.malformed
        }

        private mutating func parseStringLiteral() throws -> APIExpr {
            index += 1 // opening quote
            var text = ""
            while let c = peek(), c != "\"" {
                if c == "\\", index + 1 < chars.count {
                    index += 1
                    switch chars[index] {
                    case "n": text.append("\n")
                    case "r": text.append("\r")
                    case "t": text.append("\t")
                    case "\"": text.append("\"")
                    case "\\": text.append("\\")
                    default: text.append(chars[index])
                    }
                } else {
                    text.append(c)
                }
                index += 1
            }
            guard peek() == "\"" else { throw ParseError.malformed }
            index += 1 // closing quote
            return .literal(text)
        }

        private mutating func parseVariable() throws -> APIExpr {
            index += 1 // "{"
            let name = readIdentifier()
            guard !name.isEmpty, peek() == "}" else { throw ParseError.malformed }
            index += 1 // "}"
            return .variable(name)
        }

        private mutating func parseCall() throws -> APIExpr {
            let name = readIdentifier()
            skipWhitespace()
            guard peek() == "(" else { throw ParseError.malformed }
            index += 1
            var args: [APIExpr] = []
            skipWhitespace()
            if peek() != ")" {
                args.append(try parseExpression())
                skipWhitespace()
                while peek() == "," {
                    index += 1
                    args.append(try parseExpression())
                    skipWhitespace()
                }
            }
            guard peek() == ")" else { throw ParseError.malformed }
            index += 1
            return .call(name, args)
        }
    }
}

enum APIExpressionEvaluator {
    static func evaluate(_ expr: APIExpr, resolve: (String) -> String) -> String {
        switch expr {
        case .literal(let text):
            return text
        case .variable(let name):
            return resolve(name)
        case .concat(let parts):
            return parts.map { evaluate($0, resolve: resolve) }.joined()
        case .call(let name, let args):
            return apply(name, args.map { evaluate($0, resolve: resolve) })
        }
    }

    private static func apply(_ name: String, _ args: [String]) -> String {
        switch name {
        case "md5": return hex(Insecure.MD5.hash(data: Data((args.first ?? "").utf8)))
        case "sha1": return hex(Insecure.SHA1.hash(data: Data((args.first ?? "").utf8)))
        case "sha256": return hex(SHA256.hash(data: Data((args.first ?? "").utf8)))
        case "hmacSha256":
            guard args.count == 2 else { return "" }
            let key = SymmetricKey(data: Data(args[0].utf8))
            return hex(HMAC<SHA256>.authenticationCode(for: Data(args[1].utf8), using: key))
        case "hmacSha1":
            guard args.count == 2 else { return "" }
            let key = SymmetricKey(data: Data(args[0].utf8))
            return hex(HMAC<Insecure.SHA1>.authenticationCode(for: Data(args[1].utf8), using: key))
        case "base64": return Data((args.first ?? "").utf8).base64EncodedString()
        case "upper": return (args.first ?? "").uppercased()
        case "lower": return (args.first ?? "").lowercased()
        case "urlEncode": return (args.first ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? (args.first ?? "")
        case "concat": return args.joined()
        default: return ""
        }
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
