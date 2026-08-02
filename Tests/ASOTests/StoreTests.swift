import XCTest
import Foundation
@testable import ASOCore
@testable import ASOStore
@testable import KeywordKit
@testable import RevenueKit

final class StoreTests: XCTestCase {
    private var store: ASOStore!

    override func setUpWithError() throws {
        store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "123", bundleId: "com.t.migrainecast",
                                       name: "MigraineCast"))
    }

    func testMigrationIsIdempotent() throws {
        let database = try Database()
        try Schema.migrate(database)
        XCTAssertNoThrow(try Schema.migrate(database))
    }

    func testUpsertAppReplacesRatherThanDuplicating() throws {
        try store.upsertApp(TrackedApp(id: "123", bundleId: "com.t.migrainecast",
                                       name: "MigraineCast Pro"))
        let apps = try store.apps()
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "MigraineCast Pro")
    }

    func testKeywordsAreNormalizedAndDeduplicated() throws {
        let first = try store.addKeyword(appId: "123", term: "  Migraine  ", country: "us")
        let second = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        XCTAssertEqual(first, second, "case and whitespace should normalize to one keyword")
        XCTAssertEqual(try store.keywords(appId: "123").count, 1)
    }

    /// Same term in a different storefront is a distinct tracked keyword.
    func testSameTermInDifferentCountriesAreSeparate() throws {
        _ = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        _ = try store.addKeyword(appId: "123", term: "migraine", country: "nl")
        XCTAssertEqual(try store.keywords(appId: "123").count, 2)
        XCTAssertEqual(try store.keywords(appId: "123", country: "nl").count, 1)
    }

    /// Two runs on the same day must update one row, not stack up points.
    func testRankSnapshotsCollapsePerDay() throws {
        let id = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        let morning = Date()
        let evening = morning.addingTimeInterval(8 * 3600)

        try store.recordRank(keywordId: id, rank: 12, at: morning)
        try store.recordRank(keywordId: id, rank: 9, at: evening)

        let history = try store.rankHistory(keywordId: id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.rank, 9, "later reading should win")
    }

    func testRankDeltaUsesTwoMostRecentPoints() throws {
        let id = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        let today = Date()
        try store.recordRank(keywordId: id, rank: 20, at: today.addingTimeInterval(-86_400))
        try store.recordRank(keywordId: id, rank: 12, at: today)

        let keyword = try XCTUnwrap(try store.keywords(appId: "123").first)
        XCTAssertEqual(keyword.currentRank, 12)
        XCTAssertEqual(keyword.previousRank, 20)
        XCTAssertEqual(keyword.rankDelta, 8, "moving from 20 to 12 is an 8-position gain")
    }

    /// Falling out of the top 100 stores NULL, which must survive as nil rather
    /// than collapsing to 0.
    func testUnrankedIsStoredAsNil() throws {
        let id = try store.addKeyword(appId: "123", term: "obscure", country: "us")
        try store.recordRank(keywordId: id, rank: nil)
        let history = try store.rankHistory(keywordId: id)
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.first?.rank)
    }

    func testMetricsUpsertOverwrites() throws {
        let id = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        try store.updateMetrics(keywordId: id, popularity: 40, difficulty: 60,
                                competitors: 100, source: "appleSearchAds")
        try store.updateMetrics(keywordId: id, popularity: 55, difficulty: 62,
                                competitors: 120, source: "appleSearchAds")

        let keyword = try XCTUnwrap(try store.keywords(appId: "123").first)
        XCTAssertEqual(keyword.popularity, 55)
        XCTAssertEqual(keyword.competitors, 120)
    }

    func testDeletingAppCascadesToKeywordsAndRanks() throws {
        let id = try store.addKeyword(appId: "123", term: "migraine", country: "us")
        try store.recordRank(keywordId: id, rank: 5)
        try store.database.run("DELETE FROM apps WHERE id = ?;", [.text("123")])

        XCTAssertEqual(try store.rankHistory(keywordId: id).count, 0,
                       "foreign keys should cascade rank history away with the app")
    }

    func testRevenueEventsAreIdempotentByEventId() throws {
        let event = RevenueEvent(eventId: "evt-1", appId: "123", type: "INITIAL_PURCHASE",
                                 revenueUSD: 9.99, occurredAt: Date())
        try store.recordRevenue([event])
        try store.recordRevenue([event])
        XCTAssertEqual(try store.revenue(appId: "123",
                                         since: Date().addingTimeInterval(-3600)).count, 1)
    }

    /// A later event carrying attribution must not wipe ids already recorded.
    func testRevenueUpsertPreservesExistingAttribution() throws {
        try store.recordRevenue([RevenueEvent(eventId: "evt-1", appId: "123",
                                              type: "INITIAL_PURCHASE", revenueUSD: 9.99,
                                              occurredAt: Date(), asaKeywordId: "kw-77")])
        // Same event re-delivered without attribution fields.
        try store.recordRevenue([RevenueEvent(eventId: "evt-1", appId: "123",
                                              type: "INITIAL_PURCHASE", revenueUSD: 9.99,
                                              occurredAt: Date())])

        let events = try store.revenue(appId: "123", since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(events.first?.asaKeywordId, "kw-77")
    }

    func testAttributionCoverageCountsOnlyKeywordIds() throws {
        let now = Date()
        try store.recordRevenue([
            RevenueEvent(eventId: "a", appId: "123", type: "PURCHASE",
                         revenueUSD: 5, occurredAt: now, asaKeywordId: "kw-1"),
            RevenueEvent(eventId: "b", appId: "123", type: "PURCHASE",
                         revenueUSD: 5, occurredAt: now, asaCampaignId: "c-1"),
            RevenueEvent(eventId: "c", appId: "123", type: "PURCHASE",
                         revenueUSD: 5, occurredAt: now),
        ])
        let coverage = try store.attributionCoverage(appId: "123",
                                                     since: now.addingTimeInterval(-3600))
        XCTAssertEqual(coverage.total, 3)
        XCTAssertEqual(coverage.attributed, 1)
    }

    func testSpendUpsertReplacesSameDayRow() throws {
        let day = Date()
        let row = SpendRow(appId: "123", campaignId: "c1", adGroupId: "g1",
                           keywordId: "k1", keywordText: "migraine", country: "US",
                           day: day, spend: 10, impressions: 100, taps: 10, installs: 2)
        try store.recordSpend([row])

        var updated = row
        updated.spend = 14
        updated.installs = 3
        try store.recordSpend([updated])

        let rows = try store.spend(appId: "123", since: day.addingTimeInterval(-86_400))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.spend, 14)
        XCTAssertEqual(rows.first?.installs, 3)
    }

    func testMetadataSnapshotRoundTrip() throws {
        var entry = LocalizedMetadata(locale: "en-US")
        entry[.keywords] = "migraine,headache"
        try store.recordSnapshot(appId: "123", metadata: ["en-US": entry])

        let last = try XCTUnwrap(try store.lastSnapshot(appId: "123", locale: "en-US",
                                                        field: .keywords))
        XCTAssertEqual(last.value, "migraine,headache")
    }

    func testAlertsRoundTripAndAcknowledge() throws {
        let id = try store.recordAlert(appId: "123", kind: "rank_drop",
                                       title: "Rank drop", body: "migraine fell 12 places",
                                       severity: .warning)
        XCTAssertEqual(try store.alerts(unacknowledgedOnly: true).count, 1)
        try store.acknowledgeAlert(id: id)
        XCTAssertEqual(try store.alerts(unacknowledgedOnly: true).count, 0)
        XCTAssertEqual(try store.alerts().count, 1)
    }
}

final class ROASTests: XCTestCase {

    private func spend(keywordId: String?, keyword: String, campaign: String = "c1",
                       amount: Double, installs: Int = 10) -> SpendRow {
        SpendRow(appId: "123", campaignId: campaign, campaignName: "Brand",
                 adGroupId: "g1", keywordId: keywordId, keywordText: keyword,
                 country: "US", day: Date(), spend: amount,
                 impressions: 1000, taps: 100, installs: installs)
    }

    private func revenue(keywordId: String?, campaignId: String? = nil,
                         amount: Double, id: String = UUID().uuidString) -> RevenueEvent {
        RevenueEvent(eventId: id, appId: "123", type: "INITIAL_PURCHASE",
                     revenueUSD: amount, occurredAt: Date(),
                     asaCampaignId: campaignId, asaKeywordId: keywordId)
    }

    /// With keyword ids present on both sides, ROAS is a direct measurement.
    func testMeasuredWhenKeywordIdsPresent() throws {
        let rows = ROASCalculator.compute(
            spend: [spend(keywordId: "k1", keyword: "migraine", amount: 100)],
            revenue: [revenue(keywordId: "k1", amount: 250)])

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.revenue, 250)
        XCTAssertEqual(row.roas, 2.5)
        XCTAssertEqual(row.quality, .measured)
    }

    /// Without keyword ids, campaign revenue is split by spend share and the
    /// result must be labelled estimated.
    func testEstimatedAllocatesBySpendShare() throws {
        let rows = ROASCalculator.compute(
            spend: [
                spend(keywordId: "k1", keyword: "migraine", amount: 75),
                spend(keywordId: "k2", keyword: "headache", amount: 25),
            ],
            revenue: [revenue(keywordId: nil, campaignId: "c1", amount: 400)])

        let byKeyword = Dictionary(uniqueKeysWithValues: rows.map { ($0.keyword, $0) })
        let migraine = try XCTUnwrap(byKeyword["migraine"])
        let headache = try XCTUnwrap(byKeyword["headache"])
        XCTAssertEqual(migraine.revenue, 300, accuracy: 0.001)
        XCTAssertEqual(headache.revenue, 100, accuracy: 0.001)
        XCTAssertEqual(migraine.quality, .estimated)
    }

    func testMixedWhenSomeEventsAttributed() throws {
        let rows = ROASCalculator.compute(
            spend: [spend(keywordId: "k1", keyword: "migraine", amount: 100)],
            revenue: [
                revenue(keywordId: "k1", amount: 50),
                revenue(keywordId: nil, campaignId: "c1", amount: 30),
            ])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.quality, .mixed)
        XCTAssertEqual(row.revenue, 80, accuracy: 0.001)
    }

    /// Revenue with no Search Ads attribution at all is organic and must not be
    /// credited to any paid keyword.
    func testOrganicRevenueIsNotAllocated() {
        let rows = ROASCalculator.compute(
            spend: [spend(keywordId: "k1", keyword: "migraine", amount: 100)],
            revenue: [revenue(keywordId: nil, campaignId: nil, amount: 999)])
        XCTAssertEqual(rows.first?.revenue, 0)
    }

    /// Revenue from a different campaign must not leak across campaigns.
    func testAllocationIsScopedToItsCampaign() {
        let rows = ROASCalculator.compute(
            spend: [
                spend(keywordId: "k1", keyword: "migraine", campaign: "c1", amount: 100),
                spend(keywordId: "k2", keyword: "sleep", campaign: "c2", amount: 100),
            ],
            revenue: [revenue(keywordId: nil, campaignId: "c1", amount: 200)])

        let byKeyword = Dictionary(uniqueKeysWithValues: rows.map { ($0.keyword, $0) })
        XCTAssertEqual(byKeyword["migraine"]?.revenue, 200)
        XCTAssertEqual(byKeyword["sleep"]?.revenue, 0)
    }

    /// Zero spend must not produce an infinite or NaN ROAS.
    func testZeroSpendYieldsNilROAS() {
        let rows = ROASCalculator.compute(
            spend: [spend(keywordId: "k1", keyword: "free", amount: 0, installs: 0)],
            revenue: [revenue(keywordId: "k1", amount: 100)])
        XCTAssertNil(rows.first?.roas)
        XCTAssertNil(rows.first?.cpa)
    }

    func testDerivedMetrics() throws {
        let rows = ROASCalculator.compute(
            spend: [spend(keywordId: "k1", keyword: "migraine", amount: 50, installs: 25)],
            revenue: [revenue(keywordId: "k1", amount: 100)])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try XCTUnwrap(row.cpa), 2.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.arpu), 4.0, accuracy: 0.001)
        XCTAssertEqual(row.profit, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.conversionRate), 0.25, accuracy: 0.001)
    }
}

final class KeywordAnalysisTests: XCTestCase {

    private func app(name: String, ratings: Int) -> StoreApp {
        StoreApp(id: UUID().uuidString, bundleId: "com.x", name: name, subtitle: nil,
                 description: "", sellerName: "Seller", genres: [], averageRating: 4.5,
                 ratingCount: ratings, price: 0, version: "1.0", screenshotURLs: [],
                 releaseDate: nil, currentVersionReleaseDate: nil)
    }

    func testEmptyResultsScoreZero() {
        XCTAssertEqual(DifficultyScorer.score(results: [], term: "x", requestedLimit: 100), 0)
    }

    /// Every top result matching the term in its title, with heavy review counts,
    /// is the hardest case.
    func testContestedTermScoresHigh() {
        let results = (0..<10).map { _ in app(name: "Migraine Tracker Pro", ratings: 200_000) }
        let score = DifficultyScorer.score(results: results, term: "migraine",
                                           requestedLimit: 10)
        XCTAssertGreaterThan(score, 70)
    }

    func testUncontestedTermScoresLow() {
        let results = (0..<3).map { index in app(name: "Unrelated App \(index)", ratings: 5) }
        let score = DifficultyScorer.score(results: results, term: "migraine",
                                           requestedLimit: 100)
        XCTAssertLessThan(score, 25)
    }

    func testScoreStaysInRange() {
        for ratings in [0, 10, 1_000, 10_000_000] {
            let results = (0..<10).map { _ in app(name: "Migraine", ratings: ratings) }
            let score = DifficultyScorer.score(results: results, term: "migraine",
                                               requestedLimit: 100)
            XCTAssertTrue((0...100).contains(score), "score \(score) out of range")
        }
    }

    // MARK: Competitor keyword extraction

    func testExtractionWeightsTitleOverDescription() {
        let competitor = StoreApp(
            id: "1", bundleId: "com.x", name: "Migraine Diary", subtitle: "Headache Tracker",
            description: "wellness wellness wellness journal", sellerName: "S", genres: [],
            averageRating: 4, ratingCount: 10, price: 0, version: "1", screenshotURLs: [],
            releaseDate: nil, currentVersionReleaseDate: nil)

        let terms = CompetitorAnalyzer.extractKeywords(from: competitor)
        let migraineIndex = try? XCTUnwrap(terms.firstIndex(of: "migraine"))
        let wellnessIndex = try? XCTUnwrap(terms.firstIndex(of: "wellness"))
        XCTAssertLessThan(migraineIndex ?? .max, wellnessIndex ?? .max,
                          "title terms should outrank description terms")
    }

    func testExtractionProducesTitleBigrams() {
        let competitor = StoreApp(
            id: "1", bundleId: "com.x", name: "Migraine Tracker", subtitle: nil,
            description: "", sellerName: "S", genres: [], averageRating: 4,
            ratingCount: 10, price: 0, version: "1", screenshotURLs: [],
            releaseDate: nil, currentVersionReleaseDate: nil)

        XCTAssertTrue(CompetitorAnalyzer.extractKeywords(from: competitor)
            .contains("migraine tracker"))
    }

    func testExtractionDropsStopWordsAndShortTokens() {
        let competitor = StoreApp(
            id: "1", bundleId: "com.x", name: "The Best App for You", subtitle: nil,
            description: "", sellerName: "S", genres: [], averageRating: 4,
            ratingCount: 10, price: 0, version: "1", screenshotURLs: [],
            releaseDate: nil, currentVersionReleaseDate: nil)

        let terms = CompetitorAnalyzer.extractKeywords(from: competitor)
        XCTAssertFalse(terms.contains("the"))
        XCTAssertFalse(terms.contains("for"))
        XCTAssertFalse(terms.contains("you"))
    }

    // MARK: App id parsing

    func testParsesAppStoreURL() {
        XCTAssertEqual(
            iTunesSearchClient.appId(from: "https://apps.apple.com/us/app/migrainecast/id123456789"),
            "123456789")
    }

    func testParsesBareId() {
        XCTAssertEqual(iTunesSearchClient.appId(from: " 123456789 "), "123456789")
    }

    func testRejectsNonsense() {
        XCTAssertNil(iTunesSearchClient.appId(from: "not an app"))
    }
}

final class RevenueMappingTests: XCTestCase {

    /// The relay may spell attribution keys several ways depending on how the
    /// app wrote its subscriber attributes; all must resolve.
    func testMapsAlternateAttributionKeys() {
        let fields: [String: FirestoreValue] = [
            "eventId": .string("evt-1"),
            "type": .string("INITIAL_PURCHASE"),
            "revenueUSD": .double(9.99),
            "occurredAt": .timestamp(Date()),
            "$keywordId": .string("kw-9"),
        ]
        let event = RevenueCatSync.event(from: fields)
        XCTAssertEqual(event?.asaKeywordId, "kw-9")
    }

    func testMissingEventIdIsRejected() {
        XCTAssertNil(RevenueCatSync.event(from: ["type": .string("PURCHASE")]))
    }

    func testFallsBackAcrossRevenueFieldNames() {
        let event = RevenueCatSync.event(from: [
            "eventId": .string("evt-2"),
            "type": .string("RENEWAL"),
            "price": .double(4.99),
            "occurredAt": .timestamp(Date()),
        ])
        XCTAssertEqual(event?.revenueUSD, 4.99)
    }

    func testEmptyAttributionStringIsTreatedAsAbsent() {
        let event = RevenueCatSync.event(from: [
            "eventId": .string("evt-3"),
            "type": .string("PURCHASE"),
            "occurredAt": .timestamp(Date()),
            "asaKeywordId": .string(""),
        ])
        XCTAssertNil(event?.asaKeywordId)
    }
}

final class TableSortKeyTests: XCTestCase {

    private func keyword(_ term: String, rank: Int? = nil, popularity: Double? = nil,
                         difficulty: Double? = nil, competitors: Int? = nil) -> TrackedKeyword {
        var keyword = TrackedKeyword(id: 1, appId: "1", term: term,
                                     country: "us", addedAt: Date())
        keyword.currentRank = rank
        keyword.popularity = popularity
        keyword.difficulty = difficulty
        keyword.competitors = competitors
        return keyword
    }

    /// Ascending rank means best first, so unranked keywords must land last
    /// rather than at the top where they would hide the real positions.
    func testUnrankedSortsAfterEveryRealPosition() {
        let rows = [keyword("a"), keyword("b", rank: 52), keyword("c", rank: 3)]
        let sorted = rows.sorted(using: KeyPathComparator(\TrackedKeyword.sortRank,
                                                          order: .forward))
        XCTAssertEqual(sorted.map(\.term), ["c", "b", "a"])
    }

    /// Descending popularity is the default view; absent values must sink.
    func testAbsentPopularitySinksWhenDescending() {
        let rows = [keyword("a"), keyword("b", popularity: 5), keyword("c", popularity: 62)]
        let sorted = rows.sorted(using: KeyPathComparator(\TrackedKeyword.sortPopularity,
                                                          order: .reverse))
        XCTAssertEqual(sorted.map(\.term), ["c", "b", "a"])
    }

    func testDifficultyAndCompetitorSortKeys() {
        let rows = [keyword("a"), keyword("b", difficulty: 70), keyword("c", difficulty: 20)]
        XCTAssertEqual(rows.sorted(using: KeyPathComparator(\TrackedKeyword.sortDifficulty,
                                                            order: .reverse)).map(\.term),
                       ["b", "c", "a"])

        let byCompetitors = [keyword("a"), keyword("b", competitors: 90)]
            .sorted(using: KeyPathComparator(\TrackedKeyword.sortCompetitors, order: .reverse))
        XCTAssertEqual(byCompetitors.map(\.term), ["b", "a"])
    }

    func testDeltaSortTreatsUnknownAsNoMovement() {
        var improved = keyword("up", rank: 5); improved.previousRank = 20
        var dropped = keyword("down", rank: 30); dropped.previousRank = 10
        let rows = [keyword("flat"), improved, dropped]

        let sorted = rows.sorted(using: KeyPathComparator(\TrackedKeyword.sortDelta,
                                                          order: .reverse))
        XCTAssertEqual(sorted.first?.term, "up", "biggest gain first")
        XCTAssertEqual(sorted.last?.term, "down", "biggest drop last")
    }
}
