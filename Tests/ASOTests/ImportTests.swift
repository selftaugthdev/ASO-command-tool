import XCTest
import ASOCore
import ASOStore
@testable import KeywordKit

final class KeywordImportTests: XCTestCase {

    // MARK: Plain lists

    func testPlainNewlineList() {
        let result = KeywordImporter.parse("migraine\nheadache\nmigraine tracker")
        XCTAssertEqual(result.keywords.map(\.term),
                       ["migraine", "headache", "migraine tracker"])
        XCTAssertFalse(result.hadHeader)
    }

    func testCommaSeparatedSingleLine() {
        let result = KeywordImporter.parse("migraine, headache, aura")
        XCTAssertEqual(result.keywords.count, 3)
        XCTAssertEqual(result.keywords.first?.term, "migraine")
    }

    func testTermsAreLowercasedAndTrimmed() {
        let result = KeywordImporter.parse("  Migraine Tracker  \nHEADACHE")
        XCTAssertEqual(result.keywords.map(\.term), ["migraine tracker", "headache"])
    }

    /// Importing the same list twice, or a list with repeats, must not create
    /// duplicate rows.
    func testDuplicatesAreSkipped() {
        let result = KeywordImporter.parse("migraine\nMigraine\nmigraine")
        XCTAssertEqual(result.keywords.count, 1)
        XCTAssertEqual(result.skippedRows, 2)
    }

    func testEmptyInput() {
        XCTAssertTrue(KeywordImporter.parse("").isEmpty)
        XCTAssertTrue(KeywordImporter.parse("   \n  \n").isEmpty)
    }

    // MARK: CSV with headers

    func testCSVWithKeywordAndVolumeColumns() {
        let csv = """
        Keyword,Volume,Difficulty
        migraine,45,72
        headache relief,30,55
        """
        let result = KeywordImporter.parse(csv)

        XCTAssertTrue(result.hadHeader)
        XCTAssertEqual(result.keywords.count, 2)
        XCTAssertEqual(result.keywords[0].term, "migraine")
        XCTAssertEqual(result.keywords[0].volume, 45)
        XCTAssertEqual(result.keywords[0].difficulty, 72)
        XCTAssertEqual(result.keywords[1].term, "headache relief")
    }

    /// Column order must not matter; detection is by name.
    func testColumnOrderIsIrrelevant() {
        let csv = """
        Difficulty,Search Volume,Term
        72,45,migraine
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.first?.term, "migraine")
        XCTAssertEqual(result.keywords.first?.volume, 45)
        XCTAssertEqual(result.keywords.first?.difficulty, 72)
    }

    func testAlternateColumnNames() {
        for header in ["keyword", "term", "query", "phrase", "search term", "zoekterm"] {
            let result = KeywordImporter.parse("\(header),volume\nmigraine,10")
            XCTAssertEqual(result.keywords.first?.term, "migraine",
                           "header '\(header)' should be recognised")
        }
    }

    func testRankAndCountryColumns() {
        let csv = """
        Keyword,Rank,Country
        migraine,12,US
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.first?.rank, 12)
        XCTAssertEqual(result.keywords.first?.country, "us")
    }

    // MARK: Delimiters

    func testTabSeparated() {
        let tsv = "Keyword\tVolume\nmigraine\t45"
        let result = KeywordImporter.parse(tsv)
        XCTAssertEqual(result.keywords.first?.term, "migraine")
        XCTAssertEqual(result.keywords.first?.volume, 45)
    }

    func testSemicolonSeparated() {
        let csv = "Keyword;Volume\nmigraine;45"
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.first?.term, "migraine")
        XCTAssertEqual(result.keywords.first?.volume, 45)
    }

    /// European exports often use ';' as delimiter and ',' as decimal separator.
    func testEuropeanDecimalComma() {
        let csv = "Keyword;Volume\nmigraine;45,5"
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.first?.volume ?? 0, 45.5, accuracy: 0.01)
    }

    // MARK: Quoting

    func testQuotedFieldContainingDelimiter() {
        let csv = """
        Keyword,Volume
        "migraine, chronic",45
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.first?.term, "migraine, chronic")
        XCTAssertEqual(result.keywords.first?.volume, 45)
    }

    func testEscapedQuotesInsideField() {
        let fields = KeywordImporter.splitRow("\"say \"\"hi\"\"\",2", delimiter: ",")
        XCTAssertEqual(fields, ["say \"hi\"", "2"])
    }

    func testSplitRowHandlesEmptyFields() {
        XCTAssertEqual(KeywordImporter.splitRow("a,,c", delimiter: ","), ["a", "", "c"])
    }

    // MARK: Headerless data

    /// A CSV whose first row is already data must not lose that row.
    func testHeaderlessCSVKeepsFirstRow() {
        let csv = """
        migraine,45
        headache,30
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.count, 2, "first data row must not be eaten")
        XCTAssertEqual(result.keywords.first?.term, "migraine")
    }

    func testRowsShorterThanExpectedAreSkipped() {
        let csv = """
        Keyword,Volume
        migraine,45

        headache,30
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.count, 2)
    }

    // MARK: Line endings

    func testWindowsLineEndings() {
        let result = KeywordImporter.parse("Keyword,Volume\r\nmigraine,45\r\nheadache,30")
        XCTAssertEqual(result.keywords.count, 2)
    }

    func testClassicMacLineEndings() {
        let result = KeywordImporter.parse("migraine\rheadache")
        XCTAssertEqual(result.keywords.count, 2)
    }

    // MARK: Realistic shapes

    /// A wide export with many extra columns must still find the right ones.
    func testWideExportWithExtraColumns() {
        let csv = """
        App,Keyword,Search Volume,Difficulty,Chance,Rank,Country,Updated
        MigraineCast,migraine tracker,52,68,31,7,US,2026-01-01
        MigraineCast,headache diary,41,55,44,15,US,2026-01-01
        """
        let result = KeywordImporter.parse(csv)

        XCTAssertEqual(result.keywords.count, 2)
        XCTAssertEqual(result.keywords[0].term, "migraine tracker")
        XCTAssertEqual(result.keywords[0].volume, 52)
        XCTAssertEqual(result.keywords[0].rank, 7)
        XCTAssertEqual(result.keywords[0].country, "us")
        XCTAssertEqual(result.keywords[1].term, "headache diary")
    }

    func testDetectedColumnsAreReported() {
        let result = KeywordImporter.parse("Keyword,Volume\nmigraine,45")
        XCTAssertNotNil(result.detectedColumns["keyword"])
        XCTAssertNotNil(result.detectedColumns["volume"])
    }
}

final class RefreshBackfillTests: XCTestCase {

    /// Imported keywords arrive with no difficulty. A rank refresh must fill it
    /// in, since nothing else does, and must not clobber a real Apple
    /// popularity figure while doing so.
    func testUpdateCompetitionPreservesPopularity() throws {
        let store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
        let id = try store.addKeyword(appId: "1", term: "migraine", country: "us")

        try store.updateMetrics(keywordId: id, popularity: 62, difficulty: nil,
                                competitors: nil, source: "appleSearchAds")
        try store.updateCompetition(keywordId: id, difficulty: 48, competitors: 90)

        let keyword = try XCTUnwrap(try store.keywords(appId: "1").first)
        XCTAssertEqual(keyword.popularity, 62, "Apple popularity must survive a rank refresh")
        XCTAssertEqual(keyword.difficulty, 48)
        XCTAssertEqual(keyword.competitors, 90)
    }

    func testCompetitionUpdateOnFreshKeywordWorks() throws {
        let store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
        let id = try store.addKeyword(appId: "1", term: "migraine", country: "us")

        try store.updateCompetition(keywordId: id, difficulty: 33, competitors: 40)

        let keyword = try XCTUnwrap(try store.keywords(appId: "1").first)
        XCTAssertEqual(keyword.difficulty, 33)
        XCTAssertNil(keyword.popularity)
    }

    /// An imported volume must be tagged so the UI never shows it as Apple's.
    func testImportedVolumeCarriesItsSource() throws {
        let store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
        let id = try store.addKeyword(appId: "1", term: "migraine", country: "us")

        try store.updateMetrics(keywordId: id, popularity: 52, difficulty: nil,
                                competitors: nil, source: MetricSource.imported.rawValue)

        let keyword = try XCTUnwrap(try store.keywords(appId: "1").first)
        XCTAssertEqual(keyword.popularity, 52)
        XCTAssertEqual(keyword.popularitySource, "imported")
        XCTAssertNotEqual(keyword.popularitySource, MetricSource.appleSearchAds.rawValue)
    }
}

final class SentinelRankTests: XCTestCase {

    /// Export formats mark "not ranked" with a sentinel number rather than an
    /// empty cell. Importing it literally puts a fake "#1000" on every
    /// unranked keyword, which reads as real data.
    func testSentinelRanksBecomeUnranked() throws {
        let csv = """
        Keyword,Position
        calm harm,52
        stop panic,1000
        calm free,999
        anxiety,-1
        breathing,0
        """
        let result = KeywordImporter.parse(csv)
        let byTerm = Dictionary(uniqueKeysWithValues: result.keywords.map { ($0.term, $0) })

        // Unwrap each keyword first: asserting on a missing key would also
        // read as nil and pass without the row ever being imported.
        XCTAssertEqual(result.keywords.count, 5, "every row must still import")
        XCTAssertEqual(try XCTUnwrap(byTerm["calm harm"]).rank, 52,
                       "a real position must survive")
        for term in ["stop panic", "calm free", "anxiety", "breathing"] {
            XCTAssertNil(try XCTUnwrap(byTerm[term]).rank,
                         "\(term) carried a sentinel and must import as unranked")
        }
    }

    /// A position just inside the plausible range is still real data.
    func testPlausibleDeepRankIsKept() {
        let result = KeywordImporter.parse("Keyword,Rank\ncalm urge,181")
        XCTAssertEqual(result.keywords.first?.rank, 181)
    }

    func testStoreRepairsPreviouslyImportedSentinels() throws {
        let store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
        let good = try store.addKeyword(appId: "1", term: "calm harm", country: "us")
        let bad = try store.addKeyword(appId: "1", term: "stop panic", country: "us")

        try store.recordRank(keywordId: good, rank: 52)
        try store.recordRank(keywordId: bad, rank: 1000)

        let repaired = try store.clearSentinelRanks()
        XCTAssertEqual(repaired, 1)

        let keywords = Dictionary(uniqueKeysWithValues:
            try store.keywords(appId: "1").map { ($0.term, $0) })
        XCTAssertEqual(keywords["calm harm"]?.currentRank, 52)
        XCTAssertNil(keywords["stop panic"]?.currentRank)
    }

    /// Astro's own export shape: popularity floors at 5 and unranked rows
    /// carry a sentinel position.
    func testAstroShapedExport() throws {
        let csv = """
        Keyword,Popularity,Difficulty,Position
        calm harm,6,64,52
        instant panic button,5,17,155
        calm free,21,77,1000
        anxiety relief,33,68,1000
        """
        let result = KeywordImporter.parse(csv)
        XCTAssertEqual(result.keywords.count, 4)

        let byTerm = Dictionary(uniqueKeysWithValues: result.keywords.map { ($0.term, $0) })
        let calmHarm = try XCTUnwrap(byTerm["calm harm"])
        XCTAssertEqual(calmHarm.volume, 6)
        XCTAssertEqual(calmHarm.difficulty, 64)
        XCTAssertEqual(calmHarm.rank, 52)

        XCTAssertEqual(try XCTUnwrap(byTerm["instant panic button"]).rank, 155)
        XCTAssertNil(try XCTUnwrap(byTerm["calm free"]).rank)
        XCTAssertNil(try XCTUnwrap(byTerm["anxiety relief"]).rank)
    }
}

final class OperationProgressTests: XCTestCase {

    private func progress(completed: Int, total: Int, elapsed: TimeInterval) -> OperationProgress {
        OperationProgress(label: "Refreshing", completed: completed, total: total,
                          startedAt: Date().addingTimeInterval(-elapsed))
    }

    func testFractionIsBounded() {
        XCTAssertEqual(progress(completed: 0, total: 100, elapsed: 0).fraction, 0)
        XCTAssertEqual(progress(completed: 50, total: 100, elapsed: 1).fraction, 0.5)
        XCTAssertEqual(progress(completed: 150, total: 100, elapsed: 1).fraction, 1,
                       "must not exceed 1 if callbacks overshoot")
    }

    func testFractionWithZeroTotalDoesNotDivideByZero() {
        XCTAssertEqual(progress(completed: 0, total: 0, elapsed: 0).fraction, 0)
    }

    /// One or two samples give a wild figure, so no estimate is shown until the
    /// rate has settled.
    func testNoEstimateUntilEnoughSamples() {
        XCTAssertNil(progress(completed: 1, total: 100, elapsed: 4).estimatedRemaining)
        XCTAssertNotNil(progress(completed: 10, total: 100, elapsed: 36).estimatedRemaining)
    }

    func testEstimateExtrapolatesMeasuredRate() throws {
        // 10 done in 36s is 3.6s each; 90 left should read as about 324s.
        let remaining = try XCTUnwrap(
            progress(completed: 10, total: 100, elapsed: 36).estimatedRemaining)
        XCTAssertEqual(remaining, 324, accuracy: 5)
    }

    func testNoEstimateOnceComplete() {
        XCTAssertNil(progress(completed: 100, total: 100, elapsed: 360).estimatedRemaining)
    }

    func testDurationWording() {
        XCTAssertEqual(OperationProgress.describe(30), "under a minute")
        XCTAssertEqual(OperationProgress.describe(300), "about 5 min")
        XCTAssertEqual(OperationProgress.describe(1080), "about 18 min")
        XCTAssertTrue(OperationProgress.describe(7200).contains("hr"))
    }

    /// The up-front estimate is what sets expectations before the click.
    func testInitialEstimateMatchesLimiterPace() {
        let seconds = OperationProgress.initialEstimate(itemCount: 302, secondsPerItem: 3.6)
        XCTAssertEqual(seconds, 1087.2, accuracy: 0.1)
        XCTAssertEqual(OperationProgress.describe(seconds), "about 18 min")
    }

    func testCancellingStateOverridesDetail() {
        var p = progress(completed: 5, total: 100, elapsed: 18)
        p.isCancelling = true
        XCTAssertEqual(p.detail, "Stopping…")
    }

    func testDetailShowsCountAndEstimate() {
        let detail = progress(completed: 10, total: 100, elapsed: 36).detail
        XCTAssertTrue(detail.contains("10 of 100"))
        XCTAssertTrue(detail.contains("left"))
    }
}
