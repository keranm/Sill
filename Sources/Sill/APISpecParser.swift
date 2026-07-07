import Foundation

/// Where a spec's declared auth token goes once a request is built, and how
/// to write it there — e.g. AirGradient's `?token={{token}}` query param, or
/// a bearer scheme's `Authorization: Bearer {{token}}` header (the "Bearer "
/// prefix belongs in the value, not the env variable, so the user's
/// environment entry holds just the bare token).
struct APIAuthPlaceholder: Codable, Equatable {
    var inQuery: Bool
    /// The literal header name (e.g. "Authorization") or query key (e.g.
    /// "token") this gets written under.
    var fieldName: String
    /// The `{{name}}` environment variable seeded for the user to fill in.
    var envVariableName: String
    /// Prepended to the variable in the actual header/query value — "Bearer "
    /// for bearer schemes, empty for a bare apiKey.
    var valuePrefix: String

    var placeholderValue: String { "\(valuePrefix){{\(envVariableName)}}" }
}

/// A parsed API spec/collection, normalized from either an OpenAPI/Swagger
/// document or a Postman Collection — different source formats, same
/// browsable shape once imported.
struct APICollection: Codable, Identifiable {
    var id: UUID
    var name: String
    /// nil for Postman collections, whose operations already carry a full
    /// URL; set for OpenAPI/Swagger, whose `paths` are relative to a server.
    var baseURL: String?
    var operations: [APIOperation]
    /// From the spec's declared security scheme, if any — "setup the
    /// headers ready for the user to put in the auth tokens" per the
    /// owner's actual ask, not just a bare list of endpoints.
    var authPlaceholder: APIAuthPlaceholder?
    var authDescription: String?
    /// Set by APIClientStore.importCollection once it seeds an Environment
    /// for `authPlaceholder`'s variable — nil until then.
    var environmentID: UUID?
}

struct APIOperation: Codable, Identifiable {
    var id: UUID
    var method: String
    /// Combine with `APICollection.baseURL` for OpenAPI/Swagger; already a
    /// full URL (Postman-variable placeholders and all) for Postman.
    var path: String
    var summary: String?
    var tag: String
    var headers: [String: String]
    var body: String?
}

/// developer-tools.md #3's collections feature: sniffs already-parsed JSON
/// for the shape of a known, strictly-defined spec format — not scraping or
/// interpreting arbitrary content, just checking a couple of top-level keys
/// against known schemas (OpenAPI 3.x, Swagger 2.0, Postman Collection
/// v2.1). API Blueprint dropped: declining format, not worth a parser.
enum APISpecParser {
    static func detect(_ json: Any, name: String, sourceURL: URL? = nil) -> APICollection? {
        guard let object = json as? [String: Any] else { return nil }
        if object["openapi"] is String || object["swagger"] is String {
            return parseOpenAPI(object, name: name, sourceURL: sourceURL)
        }
        if let info = object["info"] as? [String: Any],
           let schema = info["schema"] as? String,
           schema.contains("schema.getpostman.com") {
            return parsePostmanCollection(object, name: name)
        }
        return nil
    }

    static func parseOpenAPI(_ object: [String: Any], name: String, sourceURL: URL? = nil) -> APICollection? {
        guard let paths = object["paths"] as? [String: Any] else { return nil }

        var baseURL: String?
        if let servers = object["servers"] as? [[String: Any]], let first = servers.first?["url"] as? String {
            baseURL = first
        } else if let host = object["host"] as? String {
            let scheme = (object["schemes"] as? [String])?.first ?? "https"
            let basePath = object["basePath"] as? String ?? ""
            baseURL = "\(scheme)://\(host)\(basePath)"
        } else if let sourceURL, let scheme = sourceURL.scheme, let host = sourceURL.host() {
            // Some specs (AirGradient's, e.g.) declare no server/host at
            // all — the only reasonable base is wherever the spec itself
            // was actually fetched from.
            baseURL = "\(scheme)://\(host)"
        }

        let methodKeys = ["get", "post", "put", "patch", "delete", "head", "options"]
        var operations: [APIOperation] = []
        for (path, rawItem) in paths {
            guard let item = rawItem as? [String: Any] else { continue }
            for methodKey in methodKeys {
                guard let operation = item[methodKey] as? [String: Any] else { continue }
                operations.append(APIOperation(
                    id: UUID(),
                    method: methodKey.uppercased(),
                    path: path,
                    summary: (operation["summary"] as? String) ?? (operation["description"] as? String),
                    tag: (operation["tags"] as? [String])?.first ?? "General",
                    headers: [:],
                    body: nil
                ))
            }
        }
        guard !operations.isEmpty else { return nil }
        operations.sort { $0.tag != $1.tag ? $0.tag < $1.tag : $0.path < $1.path }

        let title = (object["info"] as? [String: Any])?["title"] as? String
        let (authPlaceholder, authDescription) = parseAuthScheme(object)
        return APICollection(
            id: UUID(), name: title ?? name, baseURL: baseURL, operations: operations,
            authPlaceholder: authPlaceholder, authDescription: authDescription
        )
    }

    /// Reads the spec's declared auth scheme — Swagger 2's
    /// `securityDefinitions` or OpenAPI 3's `components.securitySchemes` —
    /// and picks the first one, since a spec with more than one is rare
    /// enough that guessing which applies where isn't worth the complexity.
    /// Only `apiKey` (header or query) and `http: bearer` are handled;
    /// `basic`/`oauth2` are left alone rather than guessed at.
    private static func parseAuthScheme(_ object: [String: Any]) -> (APIAuthPlaceholder?, String?) {
        let schemes = (object["securityDefinitions"] as? [String: Any])
            ?? (object["components"] as? [String: Any])?["securitySchemes"] as? [String: Any]
        guard let scheme = schemes?.values.first as? [String: Any] else { return (nil, nil) }
        let description = scheme["description"] as? String

        switch scheme["type"] as? String {
        case "apiKey":
            let paramName = (scheme["name"] as? String) ?? "apiKey"
            let placeholder = APIAuthPlaceholder(
                inQuery: (scheme["in"] as? String) == "query",
                fieldName: paramName,
                envVariableName: paramName,
                valuePrefix: ""
            )
            return (placeholder, description)
        case "http" where (scheme["scheme"] as? String) == "bearer":
            let placeholder = APIAuthPlaceholder(
                inQuery: false, fieldName: "Authorization", envVariableName: "token", valuePrefix: "Bearer "
            )
            return (placeholder, description)
        default:
            return (nil, description)
        }
    }

    static func parsePostmanCollection(_ object: [String: Any], name: String) -> APICollection? {
        guard let items = object["item"] as? [[String: Any]] else { return nil }
        var operations: [APIOperation] = []
        collectPostmanItems(items, tag: "General", into: &operations)
        guard !operations.isEmpty else { return nil }

        let title = (object["info"] as? [String: Any])?["name"] as? String
        return APICollection(id: UUID(), name: title ?? name, baseURL: nil, operations: operations)
    }

    /// Postman collections nest folders arbitrarily; recurse, carrying the
    /// nearest enclosing folder name down as the tag for grouping.
    private static func collectPostmanItems(_ items: [[String: Any]], tag: String, into operations: inout [APIOperation]) {
        for item in items {
            if let nested = item["item"] as? [[String: Any]] {
                collectPostmanItems(nested, tag: (item["name"] as? String) ?? tag, into: &operations)
                continue
            }
            guard let request = item["request"] as? [String: Any] else { continue }

            let urlString: String
            if let urlObject = request["url"] as? [String: Any] {
                urlString = (urlObject["raw"] as? String) ?? ""
            } else {
                urlString = (request["url"] as? String) ?? ""
            }
            guard !urlString.isEmpty else { continue }

            var headers: [String: String] = [:]
            for header in (request["header"] as? [[String: Any]]) ?? [] {
                if let key = header["key"] as? String, let value = header["value"] as? String {
                    headers[key] = value
                }
            }
            let body = (request["body"] as? [String: Any])?["raw"] as? String

            operations.append(APIOperation(
                id: UUID(),
                method: ((request["method"] as? String) ?? "GET").uppercased(),
                path: urlString,
                summary: item["name"] as? String,
                tag: tag,
                headers: headers,
                body: body
            ))
        }
    }
}
