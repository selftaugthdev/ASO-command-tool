import XCTest
import Foundation
@testable import ASOCore
@testable import ASOStore

final class DailyScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso)!
    }

    func testDisabledIsNeverDue() {
        let schedule = DailySchedule(isEnabled: false, hour: 7)
        XCTAssertFalse(schedule.isDue(now: date("2026-03-10T09:00:00Z"),
                                      calendar: calendar))
    }

    func testDueWhenNeverRun() {
        let schedule = DailySchedule(isEnabled: true, hour: 7, lastRun: nil)
        XCTAssertTrue(schedule.isDue(now: date("2026-03-10T09:00:00Z"),
                                     calendar: calendar))
    }

    func testNotDueBeforeTheHourOnTheFirstDay() {
        // 06:00, slot is 07:00, and yesterday's slot was already served.
        let schedule = DailySchedule(isEnabled: true, hour: 7,
                                     lastRun: date("2026-03-09T07:05:00Z"))
        XCTAssertFalse(schedule.isDue(now: date("2026-03-10T06:00:00Z"),
                                      calendar: calendar))
    }

    func testDueOnceTheHourPasses() {
        let schedule = DailySchedule(isEnabled: true, hour: 7,
                                     lastRun: date("2026-03-09T07:05:00Z"))
        XCTAssertTrue(schedule.isDue(now: date("2026-03-10T07:30:00Z"),
                                     calendar: calendar))
    }

    func testNotDueTwiceInOneDay() {
        let schedule = DailySchedule(isEnabled: true, hour: 7,
                                     lastRun: date("2026-03-10T07:02:00Z"))
        XCTAssertFalse(schedule.isDue(now: date("2026-03-10T18:00:00Z"),
                                      calendar: calendar))
    }

    /// The case a plain repeating timer gets wrong: the Mac was closed for days,
    /// so the run is owed the moment the app opens rather than skipped.
    func testDueAfterTheAppWasClosedForDays() {
        let schedule = DailySchedule(isEnabled: true, hour: 7,
                                     lastRun: date("2026-03-01T07:00:00Z"))
        XCTAssertTrue(schedule.isDue(now: date("2026-03-10T09:00:00Z"),
                                     calendar: calendar))
    }

    /// Opening the Mac before the hour on a day whose slot has not arrived must
    /// not trigger a second run for yesterday.
    func testEarlyMorningAfterAnEveningRunIsNotDue() {
        let schedule = DailySchedule(isEnabled: true, hour: 7,
                                     lastRun: date("2026-03-09T22:00:00Z"))
        XCTAssertFalse(schedule.isDue(now: date("2026-03-10T05:00:00Z"),
                                      calendar: calendar))
    }

    func testMostRecentDueRollsBackWhenTodaysSlotHasNotArrived() {
        let schedule = DailySchedule(isEnabled: true, hour: 7)
        let recent = schedule.mostRecentDueDate(before: date("2026-03-10T05:00:00Z"),
                                                calendar: calendar)
        XCTAssertEqual(recent, date("2026-03-09T07:00:00Z"))
    }

    func testNextDueIsAlwaysInTheFuture() {
        let schedule = DailySchedule(isEnabled: true, hour: 7)
        for nowISO in ["2026-03-10T05:00:00Z", "2026-03-10T07:00:00Z",
                       "2026-03-10T23:59:00Z"] {
            let now = date(nowISO)
            let next = schedule.nextDueDate(after: now, calendar: calendar)
            XCTAssertNotNil(next)
            XCTAssertGreaterThan(next!, now, "next run must be ahead of \(nowISO)")
        }
    }

    func testPreferencesRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "schedule-tests-\(UUID().uuidString)")!
        let schedule = DailySchedule(isEnabled: true, hour: 3, minute: 30,
                                     lastRun: date("2026-03-10T03:30:00Z"),
                                     alertDropThreshold: 25)
        SchedulePreferences.save(schedule, to: defaults)
        let loaded = SchedulePreferences.load(defaults)

        XCTAssertEqual(loaded.isEnabled, true)
        XCTAssertEqual(loaded.hour, 3)
        XCTAssertEqual(loaded.minute, 30)
        XCTAssertEqual(loaded.alertDropThreshold, 25)
        XCTAssertEqual(loaded.lastRun, schedule.lastRun)
    }

    func testDefaultsAreSaneWhenNothingStored() {
        let defaults = UserDefaults(suiteName: "schedule-empty-\(UUID().uuidString)")!
        let loaded = SchedulePreferences.load(defaults)
        XCTAssertFalse(loaded.isEnabled, "must not run without being switched on")
        XCTAssertEqual(loaded.hour, 7)
        XCTAssertNil(loaded.lastRun)
    }
}

final class PruneAndResumeTests: XCTestCase {
    private var store: ASOStore!

    override func setUpWithError() throws {
        store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
    }

    private func addKeyword(_ term: String, popularity: Double?,
                            country: String = "us") throws -> Int64 {
        let id = try store.addKeyword(appId: "1", term: term, country: country)
        if let popularity {
            try store.updateMetrics(keywordId: id, popularity: popularity,
                                    difficulty: nil, competitors: nil,
                                    source: "imported")
        }
        return id
    }

    func testPruneSelectsOnlyBelowThreshold() throws {
        _ = try addKeyword("floor", popularity: 5)
        _ = try addKeyword("mid", popularity: 20)
        _ = try addKeyword("high", popularity: 62)

        let doomed = try store.lowPopularityKeywords(appId: "1", below: 10,
                                                     includeUnknown: false)
        XCTAssertEqual(doomed.map(\.term), ["floor"])
    }

    /// Never-measured keywords must survive a prune by default, or an import
    /// that has not been researched yet would be wiped out.
    func testUnknownPopularityIsExcludedByDefault() throws {
        _ = try addKeyword("unmeasured", popularity: nil)
        let doomed = try store.lowPopularityKeywords(appId: "1", below: 50,
                                                     includeUnknown: false)
        XCTAssertTrue(doomed.isEmpty)
    }

    func testUnknownPopularityIncludedWhenAsked() throws {
        _ = try addKeyword("unmeasured", popularity: nil)
        let doomed = try store.lowPopularityKeywords(appId: "1", below: 50,
                                                     includeUnknown: true)
        XCTAssertEqual(doomed.map(\.term), ["unmeasured"])
    }

    func testPruneAcrossAllAppsWhenAppIdIsNil() throws {
        try store.upsertApp(TrackedApp(id: "2", bundleId: "c", name: "Other"))
        _ = try addKeyword("a", popularity: 5)
        let other = try store.addKeyword(appId: "2", term: "b", country: "us")
        try store.updateMetrics(keywordId: other, popularity: 5, difficulty: nil,
                                competitors: nil, source: "imported")

        XCTAssertEqual(try store.lowPopularityKeywords(appId: nil, below: 10,
                                                       includeUnknown: false).count, 2)
        XCTAssertEqual(try store.lowPopularityKeywords(appId: "1", below: 10,
                                                       includeUnknown: false).count, 1)
    }

    func testRemoveKeywordsDeletesRankHistoryToo() throws {
        let id = try addKeyword("gone", popularity: 5)
        try store.recordRank(keywordId: id, rank: 4)

        XCTAssertEqual(try store.removeKeywords(ids: [id]), 1)
        XCTAssertTrue(try store.rankHistory(keywordId: id).isEmpty)
        XCTAssertTrue(try store.keywords(appId: "1").isEmpty)
    }

    func testRemoveWithEmptyListIsANoOp() throws {
        _ = try addKeyword("keep", popularity: 5)
        XCTAssertEqual(try store.removeKeywords(ids: []), 0)
        XCTAssertEqual(try store.keywords(appId: "1").count, 1)
    }

    // MARK: Resumability

    /// The property that makes an interrupted sweep cheap: anything already
    /// checked today is identified so it can be skipped on the retry.
    func testAlreadyCheckedKeywordsAreIdentified() throws {
        let done = try addKeyword("checked", popularity: 30)
        _ = try addKeyword("pending", popularity: 30)

        let today = Calendar.utc.startOfDay(for: Date())
        try store.recordRank(keywordId: done, rank: 12)

        let fresh = try store.keywordIdsWithRank(appId: "1", country: "us", since: today)
        XCTAssertEqual(fresh, [done])
    }

    /// Yesterday's reading must not count as today's, or a resumed run would
    /// skip everything and record no new data.
    func testYesterdaysReadingDoesNotCountAsFresh() throws {
        let id = try addKeyword("stale", popularity: 30)
        try store.recordRank(keywordId: id, rank: 12,
                             at: Date().addingTimeInterval(-2 * 86_400))

        let today = Calendar.utc.startOfDay(for: Date())
        let fresh = try store.keywordIdsWithRank(appId: "1", country: "us", since: today)
        XCTAssertTrue(fresh.isEmpty)
    }

    /// An unranked reading still counts as checked; otherwise keywords that fell
    /// out of the top 100 would be retried on every resume, forever.
    func testUnrankedReadingStillCountsAsChecked() throws {
        let id = try addKeyword("dropped", popularity: 30)
        try store.recordRank(keywordId: id, rank: nil)

        let today = Calendar.utc.startOfDay(for: Date())
        XCTAssertEqual(try store.keywordIdsWithRank(appId: "1", country: "us",
                                                    since: today), [id])
    }

    func testTrackedPairsCoverEveryAppAndCountry() throws {
        try store.upsertApp(TrackedApp(id: "2", bundleId: "c", name: "Other"))
        _ = try addKeyword("a", popularity: 30, country: "us")
        _ = try addKeyword("b", popularity: 30, country: "nl")
        _ = try store.addKeyword(appId: "2", term: "c", country: "us")

        let pairs = try store.trackedAppCountryPairs()
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs.reduce(0) { $0 + $1.count }, 3)
    }

    /// Untracked apps must not be swept, or unticking an app would not stop it
    /// consuming rate limit every night.
    func testUntrackedAppsAreExcludedFromTheSweep() throws {
        _ = try addKeyword("a", popularity: 30)
        try store.setTracked(false, appId: "1")
        XCTAssertTrue(try store.trackedAppCountryPairs().isEmpty)
    }
}
