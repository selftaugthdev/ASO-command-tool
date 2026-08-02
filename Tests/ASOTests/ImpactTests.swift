import XCTest
import Foundation
@testable import ASOCore
@testable import ASOStore

final class LocaleMappingTests: XCTestCase {

    /// Ranks are per storefront, metadata per locale. Getting this wrong would
    /// judge a Dutch edit against US ranks.
    func testKnownLocalesMapToStorefronts() {
        XCTAssertEqual(Locales.country(for: "en-US"), "us")
        XCTAssertEqual(Locales.country(for: "nl-NL"), "nl")
        XCTAssertEqual(Locales.country(for: "nl-BE"), "be")
        XCTAssertEqual(Locales.country(for: "de-DE"), "de")
        XCTAssertEqual(Locales.country(for: "pt-BR"), "br")
        XCTAssertEqual(Locales.country(for: "ja"), "jp")
        XCTAssertEqual(Locales.country(for: "ko"), "kr")
    }

    /// Dutch is one language but two separate storefronts, and they must not
    /// collapse together.
    func testDutchLocalesStaySeparate() {
        XCTAssertNotEqual(Locales.country(for: "nl-NL"), Locales.country(for: "nl-BE"))
    }

    func testUnknownLocaleFallsBackToRegionSubtag() {
        XCTAssertEqual(Locales.country(for: "de-AT"), "at")
    }

    func testBareLanguageFallsBackToItself() {
        XCTAssertEqual(Locales.country(for: "it"), "it")
    }
}

final class MetadataEventTests: XCTestCase {

    private func event(old: String?, new: String?,
                       field: MetadataField = .keywords) -> MetadataEvent {
        MetadataEvent(id: 1, appId: "1", locale: "en-US", field: field,
                      oldValue: old, newValue: new, source: .push, occurredAt: Date())
    }

    func testKeywordSummaryShowsAdditionsAndRemovals() {
        let summary = event(old: "migraine,aura,diary", new: "migraine,dagboek").summary
        XCTAssertTrue(summary.contains("dagboek"), "added term must show")
        XCTAssertTrue(summary.contains("aura"), "removed term must show")
        XCTAssertTrue(summary.contains("+"))
        XCTAssertTrue(summary.contains("−"))
    }

    func testKeywordSummaryIgnoresReordering() {
        let summary = event(old: "a,b,c", new: "c,b,a").summary
        XCTAssertEqual(summary, "keywords edited",
                       "reordering is not an addition or removal")
    }

    func testKeywordSummaryIsCaseAndSpaceInsensitive() {
        let summary = event(old: "Migraine, Aura", new: "migraine,aura").summary
        XCTAssertEqual(summary, "keywords edited")
    }

    func testNonKeywordFieldsGetAGenericSummary() {
        XCTAssertEqual(event(old: "a", new: "b", field: .subtitle).summary,
                       "Subtitle changed")
    }
}

final class ChangeImpactTests: XCTestCase {
    private var store: ASOStore!

    override func setUpWithError() throws {
        store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "1", bundleId: "b", name: "App"))
    }

    /// Builds a keyword whose rank was `before` for several days, then `after`.
    @discardableResult
    private func keyword(_ term: String, before: Int?, after: Int?,
                         changeDate: Date) throws -> Int64 {
        let id = try store.addKeyword(appId: "1", term: term, country: "us")
        if let before {
            for offset in 1...3 {
                try store.recordRank(keywordId: id, rank: before,
                                     at: changeDate.addingTimeInterval(-Double(offset) * 86_400))
            }
        }
        if let after {
            for offset in 1...3 {
                try store.recordRank(keywordId: id, rank: after,
                                     at: changeDate.addingTimeInterval(Double(offset) * 86_400))
            }
        }
        return id
    }

    private func recordChange(at date: Date) throws -> MetadataEvent {
        _ = try store.recordMetadataEvent(appId: "1", locale: "en-US", field: .keywords,
                                          oldValue: "old", newValue: "new",
                                          source: .push, at: date)
        return try XCTUnwrap(try store.metadataEvents(appId: "1").first)
    }

    func testImprovementIsDetected() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        for index in 0..<10 {
            try keyword("k\(index)", before: 40, after: 20, changeDate: changeDate)
        }
        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")

        XCTAssertEqual(impact.improved, 10)
        XCTAssertEqual(impact.declined, 0)
        XCTAssertEqual(try XCTUnwrap(impact.averageMovement), 20, accuracy: 0.01)
        XCTAssertTrue(impact.isConclusive)
        XCTAssertTrue(impact.verdict.contains("improved"))
    }

    func testDeclineIsDetected() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        for index in 0..<10 {
            try keyword("k\(index)", before: 20, after: 45, changeDate: changeDate)
        }
        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")

        XCTAssertEqual(impact.declined, 10)
        XCTAssertLessThan(try XCTUnwrap(impact.averageMovement), 0)
        XCTAssertTrue(impact.verdict.contains("declined"))
    }

    /// The property that keeps this honest: a big move across three keywords
    /// must not be presented as a result.
    func testSmallSampleIsInconclusive() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        for index in 0..<3 {
            try keyword("k\(index)", before: 50, after: 10, changeDate: changeDate)
        }
        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")

        XCTAssertEqual(impact.comparable, 3)
        XCTAssertFalse(impact.isConclusive, "three keywords is not evidence")
        XCTAssertTrue(impact.verdict.contains("too few"))
    }

    /// Nor should day-to-day jitter be reported as an effect.
    func testTinyMovementIsInconclusive() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        for index in 0..<12 {
            try keyword("k\(index)", before: 30, after: 31, changeDate: changeDate)
        }
        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")

        XCTAssertGreaterThanOrEqual(impact.comparable, 8)
        XCTAssertFalse(impact.isConclusive)
        XCTAssertTrue(impact.verdict.contains("noise"))
    }

    /// A keyword with no reading on one side carries no information and must be
    /// excluded rather than counted as zero.
    func testKeywordsMissingOneSideAreExcluded() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        try keyword("has-both", before: 40, after: 20, changeDate: changeDate)
        try keyword("before-only", before: 40, after: nil, changeDate: changeDate)
        try keyword("after-only", before: nil, after: 20, changeDate: changeDate)

        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")
        XCTAssertEqual(impact.comparable, 1)
    }

    func testNoRankHistoryYieldsNoVerdict() throws {
        let changeDate = Date()
        _ = try store.addKeyword(appId: "1", term: "lonely", country: "us")
        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")

        XCTAssertNil(impact.averageMovement)
        XCTAssertFalse(impact.isConclusive)
        XCTAssertTrue(impact.verdict.contains("Not enough rank history"))
    }

    /// Ranks in another storefront must not be attributed to this change.
    func testOtherCountriesAreNotCounted() throws {
        let changeDate = Date().addingTimeInterval(-10 * 86_400)
        let dutch = try store.addKeyword(appId: "1", term: "dagboek", country: "nl")
        try store.recordRank(keywordId: dutch, rank: 5,
                             at: changeDate.addingTimeInterval(-86_400))
        try store.recordRank(keywordId: dutch, rank: 5,
                             at: changeDate.addingTimeInterval(86_400))

        let impact = try store.impact(of: try recordChange(at: changeDate), country: "us")
        XCTAssertEqual(impact.comparable, 0)
    }
}

final class CompetitorPresenceTests: XCTestCase {
    private var store: ASOStore!

    override func setUpWithError() throws {
        store = try ASOStore(database: Database())
        try store.upsertApp(TrackedApp(id: "mine", bundleId: "b", name: "Mine"))
    }

    private func addSERP(_ term: String,
                         _ entries: [(Int, String, String)]) throws {
        let id = try store.addKeyword(appId: "mine", term: term, country: "us")
        try store.recordSERP(keywordId: id,
                             entries: entries.map {
                                 (rank: $0.0, appId: $0.1, name: $0.2, ratingCount: 100)
                             })
    }

    func testPresenceCountsAppearancesAndTopTen() throws {
        try addSERP("a", [(1, "rival", "Rival"), (2, "mine", "Mine")])
        try addSERP("b", [(3, "rival", "Rival"), (9, "mine", "Mine")])

        let presence = try store.competitorPresence(appId: "mine", country: "us")
        let rival = try XCTUnwrap(presence.first { $0.appId == "rival" })
        XCTAssertEqual(rival.appearances, 2)
        XCTAssertEqual(rival.topTen, 2)
        XCTAssertEqual(rival.averageRank, 2, accuracy: 0.01)
    }

    /// Our own app must never appear in its own competitor list.
    func testOwnAppIsExcluded() throws {
        try addSERP("a", [(1, "mine", "Mine"), (2, "rival", "Rival")])
        let presence = try store.competitorPresence(appId: "mine", country: "us")
        XCTAssertFalse(presence.contains { $0.appId == "mine" })
    }

    func testBeatsUsListsTermsWhereTheyOutrankUs() throws {
        try addSERP("they-win", [(1, "rival", "Rival"), (5, "mine", "Mine")])
        try addSERP("we-win", [(1, "mine", "Mine"), (5, "rival", "Rival")])

        let rival = try XCTUnwrap(
            try store.competitorPresence(appId: "mine", country: "us").first)
        XCTAssertTrue(rival.beatsUsOn.contains("they-win"))
        XCTAssertFalse(rival.beatsUsOn.contains("we-win"))
    }

    /// Absence is worse than a poor position, so a term we do not appear for
    /// counts as them beating us.
    func testTermsWeAreAbsentFromCountAsLosses() throws {
        try addSERP("absent", [(1, "rival", "Rival")])
        let rival = try XCTUnwrap(
            try store.competitorPresence(appId: "mine", country: "us").first)
        XCTAssertTrue(rival.beatsUsOn.contains("absent"))
    }

    /// Only the latest reading is kept, so a refresh replaces rather than
    /// accumulating a new set of rows every day.
    func testRecordingReplacesPreviousResults() throws {
        let id = try store.addKeyword(appId: "mine", term: "a", country: "us")
        try store.recordSERP(keywordId: id,
                             entries: [(rank: 1, appId: "old", name: "Old", ratingCount: 1)])
        try store.recordSERP(keywordId: id,
                             entries: [(rank: 1, appId: "new", name: "New", ratingCount: 1)])

        let presence = try store.competitorPresence(appId: "mine", country: "us")
        XCTAssertEqual(presence.count, 1)
        XCTAssertEqual(presence.first?.appId, "new")
    }
}
