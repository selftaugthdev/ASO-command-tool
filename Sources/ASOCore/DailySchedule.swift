import Foundation

/// When the daily refresh should run.
///
/// Deliberately not a repeating timer alone. A Mac is asleep, or the app is
/// closed, at whatever hour you picked more often than not, so a timer that
/// only fires while running would skip most days. This models the schedule as
/// "has the due time passed since the last successful run", which a check on
/// launch answers correctly no matter how long the app was closed.
public struct DailySchedule: Equatable, Sendable {
    public var isEnabled: Bool
    /// Local hour, 0–23.
    public var hour: Int
    public var minute: Int
    public var lastRun: Date?
    /// Rank drop, in positions, that is worth an alert.
    public var alertDropThreshold: Int

    public init(isEnabled: Bool = false, hour: Int = 7, minute: Int = 0,
                lastRun: Date? = nil, alertDropThreshold: Int = 10) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.lastRun = lastRun
        self.alertDropThreshold = alertDropThreshold
    }

    /// The most recent moment the schedule was due at or before `now`.
    public func mostRecentDueDate(before now: Date,
                                  calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        if today <= now { return today }
        // Today's slot has not arrived, so the last due moment was yesterday's.
        return calendar.date(byAdding: .day, value: -1, to: today)
    }

    /// The next moment the schedule becomes due after `now`.
    public func nextDueDate(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let recent = mostRecentDueDate(before: now, calendar: calendar) else {
            return nil
        }
        return calendar.date(byAdding: .day, value: 1, to: recent)
    }

    /// Whether a run is owed right now.
    ///
    /// True when enabled and the last run predates the most recent due moment,
    /// which covers both "the app was open and the hour passed" and "the app
    /// was shut for three days and has just been opened".
    public func isDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        guard let due = mostRecentDueDate(before: now, calendar: calendar) else {
            return false
        }
        guard let lastRun else { return true }
        return lastRun < due
    }

    public func describeNextRun(now: Date = Date(),
                               calendar: Calendar = .current) -> String {
        guard isEnabled else { return "Off" }
        guard let next = nextDueDate(after: now, calendar: calendar) else {
            return "Unknown"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDateInToday(next) ? "'today at' HH:mm"
                                                            : "'tomorrow at' HH:mm"
        return formatter.string(from: next)
    }
}

/// Persistence for the schedule. UserDefaults, not the Keychain: none of this
/// is secret, and it must be readable before any credential prompt.
public enum SchedulePreferences {
    private static let enabledKey = "schedule.enabled"
    private static let hourKey = "schedule.hour"
    private static let minuteKey = "schedule.minute"
    private static let lastRunKey = "schedule.lastRun"
    private static let thresholdKey = "schedule.alertDropThreshold"

    public static func load(_ defaults: UserDefaults = .standard) -> DailySchedule {
        DailySchedule(
            isEnabled: defaults.bool(forKey: enabledKey),
            hour: defaults.object(forKey: hourKey) as? Int ?? 7,
            minute: defaults.object(forKey: minuteKey) as? Int ?? 0,
            lastRun: defaults.object(forKey: lastRunKey) as? Date,
            alertDropThreshold: defaults.object(forKey: thresholdKey) as? Int ?? 10)
    }

    public static func save(_ schedule: DailySchedule,
                            to defaults: UserDefaults = .standard) {
        defaults.set(schedule.isEnabled, forKey: enabledKey)
        defaults.set(schedule.hour, forKey: hourKey)
        defaults.set(schedule.minute, forKey: minuteKey)
        defaults.set(schedule.alertDropThreshold, forKey: thresholdKey)
        if let lastRun = schedule.lastRun {
            defaults.set(lastRun, forKey: lastRunKey)
        } else {
            defaults.removeObject(forKey: lastRunKey)
        }
    }
}
