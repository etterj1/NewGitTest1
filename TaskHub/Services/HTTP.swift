import Foundation

enum APIError: LocalizedError {
    case http(status: Int, body: String)
    case api(String)
    case unsupported(String)
    case notConfigured(String)
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if status == 401 { return "Not authorized (401). The token may have expired or been revoked — reconnect this account." }
            return "HTTP \(status): \(body.prefix(300))"
        case .api(let message): return message
        case .unsupported(let message): return message
        case .notConfigured(let message): return message
        case .missingCredential: return "No saved credential for this account. Remove it and connect it again."
        }
    }
}

enum HTTPBody {
    case json(Any)
    case form([String: String])
}

/// Tiny async HTTP helper shared by every provider.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// For AI requests, which can take minutes when the model researches on the web.
    static let longSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func data(
        _ base: URL,
        _ path: String = "",
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: HTTPBody? = nil,
        session: URLSession = HTTP.session
    ) async throws -> Data {
        // appendingPathComponent percent-escapes characters such as "#" that appear in some IDs.
        let url = path.isEmpty ? base : base.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.api("Invalid URL: \(url)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
            // URLComponents leaves "+" alone, which servers read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let finalURL = components.url else { throw APIError.api("Invalid URL: \(url)") }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        switch body {
        case .json(let object)?:
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        case .form(let fields)?:
            request.httpBody = formEncode(fields).data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case nil:
            break
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.api("Invalid response from \(base.host ?? "server")") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    static func json<T: Decodable>(
        _ type: T.Type,
        _ base: URL,
        _ path: String = "",
        method: String = "GET",
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: HTTPBody? = nil
    ) async throws -> T {
        let data = try await self.data(base, path, method: method, query: query, headers: headers, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.api("Unexpected response from \(base.host ?? "server"): \(error.localizedDescription)")
        }
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

/// Date parsing/formatting for the various API formats.
enum DateCoding {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// RFC 3339 / ISO 8601, with or without fractional seconds.
    static func iso(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    static func isoString(_ date: Date) -> String { isoFractional.string(from: date) }

    /// "yyyy-MM-dd" interpreted as local midnight.
    static func day(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return localDay.date(from: String(string.prefix(10)))
    }

    static func dayString(_ date: Date) -> String { localDay.string(from: date) }

    /// Unix milliseconds as a string (ClickUp, Gmail).
    static func millis(_ string: String?) -> Date? {
        guard let string, let ms = Double(string) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func millisValue(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Google Tasks stores a date as UTC midnight; turn it into local midnight of the same calendar day.
    static func googleTasksDue(_ string: String?) -> Date? {
        guard let date = iso(string) else { return nil }
        return localDay.date(from: utcDay.string(from: date))
    }

    static func googleTasksDueString(_ date: Date) -> String { "\(localDay.string(from: date))T00:00:00.000Z" }
}

extension String {
    /// Decodes the handful of HTML entities that appear in Gmail snippets.
    var decodingHTMLEntities: String {
        var s = self
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, value) in entities { s = s.replacingOccurrences(of: entity, with: value) }
        return s
    }

    var firstLine: String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }
}
