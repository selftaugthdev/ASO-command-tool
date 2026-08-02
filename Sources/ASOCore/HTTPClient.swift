import Foundation

public struct APIError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable {
        case unauthorized
        /// ASC returns 403 with this code when a paid/free apps agreement lapsed. It
        /// looks like an auth failure but re-issuing the key will not fix it.
        case agreementExpired
        case rateLimited(retryAfter: TimeInterval?)
        case notFound
        /// 409 from ASC — usually a character-limit violation or writing to a
        /// non-editable version.
        case conflict
        case server(status: Int)
        case transport
        case decoding
    }

    public var kind: Kind
    public var message: String
    public var appleCode: String?

    public var errorDescription: String? { message }

    public init(kind: Kind, message: String, appleCode: String? = nil) {
        self.kind = kind
        self.message = message
        self.appleCode = appleCode
    }
}

/// Apple's JSON:API error envelope, shared by ASC and Search Ads.
struct AppleErrorEnvelope: Decodable {
    struct Item: Decodable {
        var code: String?
        var title: String?
        var detail: String?
    }
    var errors: [Item]?
}

/// Token-bucket limiter that keeps us under a vendor's published request ceiling.
///
/// App Store Connect allows roughly 3600 requests/hour. A metadata pull across
/// 4 apps x 8 locales plus a push is easily a few hundred calls, and rank
/// tracking runs on a schedule, so without this the app would trip the limit
/// during normal use rather than in some exotic edge case.
public actor RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date

    public init(requestsPerHour: Int, burst: Int? = nil) {
        self.capacity = Double(burst ?? max(1, requestsPerHour / 60))
        self.refillPerSecond = Double(requestsPerHour) / 3600.0
        self.tokens = self.capacity
        self.lastRefill = Date()
    }

    /// Suspends until a request slot is available.
    public func acquire() async {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            let deficit = 1 - tokens
            let waitSeconds = max(0.05, deficit / refillPerSecond)
            try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }
}

public struct HTTPClientConfig: Sendable {
    public var maxRetries: Int
    public var baseBackoff: TimeInterval
    public var requestsPerHour: Int
    public var timeout: TimeInterval

    public init(maxRetries: Int = 4, baseBackoff: TimeInterval = 1.0,
                requestsPerHour: Int = 3000, timeout: TimeInterval = 60) {
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
        self.requestsPerHour = requestsPerHour
        self.timeout = timeout
    }
}

/// Shared HTTP layer: rate limiting, 429 handling with Retry-After, and
/// exponential backoff on transient failures.
public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let limiter: RateLimiter
    private let config: HTTPClientConfig

    public init(config: HTTPClientConfig = HTTPClientConfig(), session: URLSession? = nil) {
        self.config = config
        self.limiter = RateLimiter(requestsPerHour: config.requestsPerHour)
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = config.timeout
            c.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: c)
        }
    }

    public func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            await limiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Transport failures are worth retrying; a dropped connection
                // mid-sync should not abort a whole pull.
                if attempt < config.maxRetries {
                    try await backoff(attempt: attempt, suggested: nil)
                    attempt += 1
                    continue
                }
                throw APIError(kind: .transport, message: error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw APIError(kind: .transport, message: "Non-HTTP response")
            }

            if (200..<300).contains(http.statusCode) {
                return data
            }

            let envelope = try? JSONDecoder().decode(AppleErrorEnvelope.self, from: data)
            let first = envelope?.errors?.first
            let detail = [first?.title, first?.detail]
                .compactMap { $0 }
                .joined(separator: " — ")
            let message = detail.isEmpty
                ? (String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
                : detail

            switch http.statusCode {
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                guard attempt < config.maxRetries else {
                    throw APIError(kind: .rateLimited(retryAfter: retryAfter),
                                   message: "Rate limited by Apple. \(message)",
                                   appleCode: first?.code)
                }
                try await backoff(attempt: attempt, suggested: retryAfter)
                attempt += 1
                continue

            case 500...599:
                guard attempt < config.maxRetries else {
                    throw APIError(kind: .server(status: http.statusCode),
                                   message: message, appleCode: first?.code)
                }
                try await backoff(attempt: attempt, suggested: nil)
                attempt += 1
                continue

            case 401:
                throw APIError(kind: .unauthorized, message: message, appleCode: first?.code)

            case 403:
                if first?.code == "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED" {
                    throw APIError(
                        kind: .agreementExpired,
                        message: "An App Store Connect agreement is missing or expired. "
                               + "Accept it in App Store Connect → Business, then retry.",
                        appleCode: first?.code)
                }
                throw APIError(kind: .unauthorized, message: message, appleCode: first?.code)

            case 404:
                throw APIError(kind: .notFound, message: message, appleCode: first?.code)

            case 409:
                throw APIError(kind: .conflict, message: message, appleCode: first?.code)

            default:
                throw APIError(kind: .server(status: http.statusCode),
                               message: message, appleCode: first?.code)
            }
        }
    }

    public func send<T: Decodable>(_ request: URLRequest, as type: T.Type,
                                   decoder: JSONDecoder = .appleDecoder) async throws -> T {
        let data = try await send(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(kind: .decoding,
                           message: "Could not decode \(T.self): \(error)")
        }
    }

    private func backoff(attempt: Int, suggested: TimeInterval?) async throws {
        // Respect Retry-After when Apple sends it; otherwise exponential with
        // jitter so parallel syncs do not resynchronise into another burst.
        let base = suggested ?? config.baseBackoff * pow(2, Double(attempt))
        let jitter = Double.random(in: 0...(base * 0.25))
        try await Task.sleep(nanoseconds: UInt64((base + jitter) * 1_000_000_000))
    }
}

extension JSONDecoder {
    /// Apple's APIs emit ISO8601 with fractional seconds in some fields and
    /// without in others, so try both before giving up.
    public static var appleDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            let dayOnly = DateFormatter()
            dayOnly.dateFormat = "yyyy-MM-dd"
            dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dayOnly.locale = Locale(identifier: "en_US_POSIX")
            if let date = dayOnly.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unrecognised date format: \(raw)")
        }
        return decoder
    }
}
