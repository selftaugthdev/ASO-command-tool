import Foundation
import ASOCore

/// One app as returned by the public iTunes Search API.
public struct StoreApp: Identifiable, Hashable, Sendable {
    public var id: String              // trackId
    public var bundleId: String
    public var name: String            // trackName
    public var subtitle: String?
    public var description: String
    public var sellerName: String
    public var genres: [String]
    public var averageRating: Double
    public var ratingCount: Int
    public var price: Double
    public var version: String
    public var screenshotURLs: [String]
    public var releaseDate: Date?
    public var currentVersionReleaseDate: Date?

    /// Title plus subtitle, the fields Apple weights most for keyword matching.
    public var indexedTitleText: String {
        [name, subtitle].compactMap { $0 }.joined(separator: " ")
    }
}

/// Wrapper for Apple's public search and lookup endpoints.
///
/// These are unauthenticated and rate-limited by IP at roughly 20 calls/minute,
/// which is the binding constraint on how many keywords can be rank-checked in
/// one run, so the limiter here is deliberately much tighter than the ASC one.
public final class iTunesSearchClient: @unchecked Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient? = nil) {
        // ~20 requests/minute is the documented soft ceiling; going over it
        // returns 403s that look like bans.
        self.http = http ?? HTTPClient(config: HTTPClientConfig(maxRetries: 3,
                                                               baseBackoff: 3.0,
                                                               requestsPerHour: 1000))
    }

    private struct SearchResponse: Decodable {
        var resultCount: Int
        var results: [Result]

        struct Result: Decodable {
            var trackId: Int?
            var bundleId: String?
            var trackName: String?
            var description: String?
            var sellerName: String?
            var genres: [String]?
            var averageUserRating: Double?
            var userRatingCount: Int?
            var price: Double?
            var version: String?
            var screenshotUrls: [String]?
            var releaseDate: String?
            var currentVersionReleaseDate: String?
        }
    }

    private func map(_ result: SearchResponse.Result) -> StoreApp? {
        guard let trackId = result.trackId, let name = result.trackName else { return nil }
        let iso = ISO8601DateFormatter()
        return StoreApp(
            id: String(trackId),
            bundleId: result.bundleId ?? "",
            name: name,
            // The Search API does not expose subtitle; it is filled in from
            // App Store Connect for our own apps and left nil for competitors.
            subtitle: nil,
            description: result.description ?? "",
            sellerName: result.sellerName ?? "",
            genres: result.genres ?? [],
            averageRating: result.averageUserRating ?? 0,
            ratingCount: result.userRatingCount ?? 0,
            price: result.price ?? 0,
            version: result.version ?? "",
            screenshotURLs: result.screenshotUrls ?? [],
            releaseDate: result.releaseDate.flatMap(iso.date(from:)),
            currentVersionReleaseDate: result.currentVersionReleaseDate.flatMap(iso.date(from:)))
    }

    /// Searches the store exactly as a user would, returning ranked results.
    public func search(term: String, country: String = "us",
                       limit: Int = 100) async throws -> [StoreApp] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(min(limit, 200))),
        ]
        let response = try await http.send(URLRequest(url: components.url!),
                                           as: SearchResponse.self,
                                           decoder: JSONDecoder())
        return response.results.compactMap(map)
    }

    /// Looks up one or more apps by App Store id.
    public func lookup(ids: [String], country: String = "us") async throws -> [StoreApp] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "software"),
        ]
        let response = try await http.send(URLRequest(url: components.url!),
                                           as: SearchResponse.self,
                                           decoder: JSONDecoder())
        return response.results.compactMap(map)
    }

    /// Accepts an App Store URL or a bare numeric id.
    public static func appId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return trimmed }
        // https://apps.apple.com/us/app/some-name/id1234567890
        if let range = trimmed.range(of: #"id(\d+)"#, options: .regularExpression) {
            return String(trimmed[range].dropFirst(2))
        }
        return nil
    }
}
