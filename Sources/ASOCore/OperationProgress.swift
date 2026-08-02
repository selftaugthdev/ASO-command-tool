import Foundation

/// Progress of a long-running operation, with a time estimate.
///
/// Rank refreshes make one rate-limited store lookup per keyword, so a few
/// hundred keywords runs for many minutes. An indeterminate spinner over that
/// span is indistinguishable from a hang, so these operations report how far
/// along they are and roughly how much longer they will take.
public struct OperationProgress: Equatable, Sendable {
    public var label: String
    public var completed: Int
    public var total: Int
    public var startedAt: Date
    /// Set once cancellation is requested but the loop has not yet stopped.
    public var isCancelling: Bool

    public init(label: String, completed: Int, total: Int,
                startedAt: Date, isCancelling: Bool = false) {
        self.label = label
        self.completed = completed
        self.total = total
        self.startedAt = startedAt
        self.isCancelling = isCancelling
    }

    /// Clamped, so an overshooting callback cannot drive the bar past full.
    public var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    /// Seconds remaining, extrapolated from the rate measured so far.
    ///
    /// Requests are paced by a rate limiter, so throughput is close to constant
    /// and a running mean predicts well. Returns nil until a few items have
    /// completed rather than showing a wild figure derived from one sample.
    public var estimatedRemaining: TimeInterval? {
        guard completed >= 3, completed < total else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let perItem = elapsed / Double(completed)
        return perItem * Double(total - completed)
    }

    /// Estimate used before any samples exist, from the limiter's known pace.
    public static func initialEstimate(itemCount: Int,
                                       secondsPerItem: Double) -> TimeInterval {
        Double(itemCount) * secondsPerItem
    }

    public var detail: String {
        if isCancelling { return "Stopping…" }
        var parts = ["\(completed) of \(total)"]
        if let remaining = estimatedRemaining {
            parts.append(Self.describe(remaining) + " left")
        }
        return parts.joined(separator: " · ")
    }

    /// Deliberately vague wording. The estimate is an extrapolation, and
    /// "about 18 min" is honest where "17:42" would imply precision it lacks.
    public static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 45 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        return String(format: "about %.1f hr", Double(minutes) / 60)
    }
}
