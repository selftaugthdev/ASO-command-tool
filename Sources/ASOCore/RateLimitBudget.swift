import Foundation

/// Apple's `X-Rate-Limit` header, as returned by the App Store Connect API.
///
/// The header looks like `user-hour-lim:7200;user-hour-rem:7183;`, so the
/// server tells us the real budget on every response. Reading it beats guessing
/// from a hardcoded constant: the documented ceiling is explicitly "subject to
/// change", individual endpoints have their own subordinate limits Apple does
/// not publish, and the budget is shared across everything using the same key —
/// including anything else the user runs.
public struct AppleRateLimit: Equatable, Sendable {
    public let limit: Int
    public let remaining: Int

    public init(limit: Int, remaining: Int) {
        self.limit = limit
        self.remaining = remaining
    }

    /// Parses the header value. Returns nil when it is absent or unrecognised,
    /// which is normal: Apple does not send it on every endpoint.
    public init?(header: String) {
        var values: [String: Int] = [:]
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let number = Int(value) { values[key] = number }
        }
        guard let limit = values["user-hour-lim"],
              let remaining = values["user-hour-rem"], limit > 0 else { return nil }
        self.limit = limit
        self.remaining = max(0, remaining)
    }

    public var fractionRemaining: Double {
        limit > 0 ? Double(remaining) / Double(limit) : 0
    }

    public var isExhausted: Bool { remaining <= 0 }
}

/// Tracks the budget Apple reports and paces requests to fit inside it.
///
/// This sits alongside the token bucket rather than replacing it. The bucket
/// enforces a steady local pace; this reacts to what the server actually says
/// is left, which is the only way to notice budget consumed elsewhere.
public actor RateLimitBudget {
    private var latest: AppleRateLimit?
    private var observedAt: Date?

    /// Below this share of the hourly budget, requests start being spaced out
    /// so the remainder lasts rather than being burned in a minute.
    private let conserveBelow = 0.2

    public init() {}

    public func update(from header: String?) {
        guard let header, let parsed = AppleRateLimit(header: header) else { return }
        latest = parsed
        observedAt = Date()
    }

    public var current: AppleRateLimit? { latest }

    /// Extra delay to apply before the next request.
    ///
    /// Zero while there is plenty of budget, so normal use is unaffected. Once
    /// the budget runs low the remaining requests are spread across the rest of
    /// the rolling hour, which degrades throughput instead of hitting a wall of
    /// 429s.
    public func recommendedDelay() -> TimeInterval {
        guard let latest, let observedAt else { return 0 }

        // A reading older than the rolling window tells us nothing.
        let age = Date().timeIntervalSince(observedAt)
        guard age < 3600 else { return 0 }

        if latest.isExhausted {
            // The window is rolling, so budget frees up continuously rather
            // than at a fixed reset. Back off a minute and re-check.
            return 60
        }
        guard latest.fractionRemaining < conserveBelow else { return 0 }

        let secondsLeftInWindow = 3600 - age
        return secondsLeftInWindow / Double(latest.remaining)
    }

    /// Human-readable state for diagnostics.
    public func describe() -> String? {
        guard let latest else { return nil }
        return "\(latest.remaining) of \(latest.limit) requests left this hour"
    }
}
