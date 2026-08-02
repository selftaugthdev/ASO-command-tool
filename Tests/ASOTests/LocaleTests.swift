import XCTest
import Foundation
@testable import ASOCore
@testable import ASOStore
@testable import KeywordKit

final class LocaleOpportunityTests: XCTestCase {

    private func app(name: String, description: String = "") -> StoreApp {
        StoreApp(id: UUID().uuidString, bundleId: "com.x", name: name, subtitle: nil,
                 description: description, sellerName: "S", genres: [],
                 averageRating: 4.5, ratingCount: 100, price: 0, version: "1",
                 screenshotURLs: [], releaseDate: nil, currentVersionReleaseDate: nil)
    }

    // MARK: Candidate extraction

    func testGermanStopwordsAreStripped() {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "Der Migräne Tracker für Sie"),
            stopwords: Stopwords.forLanguage("de"))
        let terms = candidates.map(\.0)

        XCTAssertTrue(terms.contains("migräne"))
        XCTAssertFalse(terms.contains("der"))
        XCTAssertFalse(terms.contains("für"))
        XCTAssertFalse(terms.contains("sie"))
    }

    func testDutchStopwordsAreStripped() {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "De Migraine Dagboek voor jou"),
            stopwords: Stopwords.forLanguage("nl"))
        let terms = candidates.map(\.0)

        XCTAssertTrue(terms.contains("migraine"))
        XCTAssertTrue(terms.contains("dagboek"))
        XCTAssertFalse(terms.contains("voor"))
        XCTAssertFalse(terms.contains("jou"))
    }

    /// Accented and non-ASCII characters must survive tokenising, or every
    /// German, French and Turkish term would be mangled.
    func testAccentedCharactersSurvive() {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "Migräne Kopfschmerz Tagebuch"),
            stopwords: Stopwords.forLanguage("de"))
        XCTAssertTrue(candidates.map(\.0).contains("migräne"))
    }

    func testCyrillicSurvives() {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "мигрень дневник"),
            stopwords: Stopwords.forLanguage("ru"))
        XCTAssertTrue(candidates.map(\.0).contains("мигрень"))
    }

    /// Title terms must outweigh description terms: that is where Apple's
    /// ranking weight is, and a 30-character title is a deliberate choice.
    func testTitleOutweighsDescription() throws {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "Migräne Tagebuch",
                      description: "wellness wellness wellness wellness"),
            stopwords: Stopwords.forLanguage("de"))
        let byTerm = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0, $0.1) })
        let migraene = try XCTUnwrap(byTerm["migräne"])
        let wellness = try XCTUnwrap(byTerm["wellness"])
        XCTAssertGreaterThan(migraene, wellness)
    }

    func testTitleBigramsAreProduced() {
        let candidates = LocaleOpportunityFinder.candidates(
            from: app(name: "Migräne Tagebuch"),
            stopwords: Stopwords.forLanguage("de"))
        XCTAssertTrue(candidates.map(\.0).contains("migräne tagebuch"))
    }

    // MARK: Scoring

    private func opportunity(popularity: Double?, difficulty: Double,
                             targeting: Int = 5, ourRank: Int? = nil) -> LocaleOpportunity {
        LocaleOpportunity(term: "t", country: "de", storefrontName: "Germany",
                          popularity: popularity, difficulty: difficulty,
                          titleTargeting: targeting, ourRank: ourRank,
                          competitorCount: 50)
    }

    /// The whole premise: same demand, lower difficulty scores higher.
    func testLowerDifficultyScoresHigher() {
        let easy = opportunity(popularity: 50, difficulty: 30)
        let hard = opportunity(popularity: 50, difficulty: 90)
        XCTAssertGreaterThan(easy.score, hard.score)
    }

    func testHigherDemandScoresHigher() {
        let strong = opportunity(popularity: 60, difficulty: 50)
        let weak = opportunity(popularity: 10, difficulty: 50)
        XCTAssertGreaterThan(strong.score, weak.score)
    }

    /// Being absent is headroom and should rank above a term already held.
    func testAbsenceIsRewardedOverAnExistingGoodPosition() {
        let absent = opportunity(popularity: 50, difficulty: 40, ourRank: nil)
        let held = opportunity(popularity: 50, difficulty: 40, ourRank: 3)
        XCTAssertGreaterThan(absent.score, held.score)
    }

    func testScoreIsNeverNegative() {
        XCTAssertGreaterThanOrEqual(opportunity(popularity: 5, difficulty: 100).score, 0)
    }

    /// Without Search Ads the proxy must still order sensibly, and must never
    /// be reported as measured.
    func testProxyDemandIsUsedAndLabelledWhenPopularityIsAbsent() {
        let many = opportunity(popularity: nil, difficulty: 40, targeting: 9)
        let few = opportunity(popularity: nil, difficulty: 40, targeting: 1)

        XCTAssertGreaterThan(many.score, few.score)
        XCTAssertFalse(many.demandIsMeasured)
        XCTAssertTrue(opportunity(popularity: 50, difficulty: 40).demandIsMeasured)
    }

    // MARK: Planning

    func testRequestEstimateScalesWithStorefronts() {
        let one = LocaleOpportunityFinder.estimatedRequests(
            seedCount: 5, storefronts: 1, candidatesPerStorefront: 25)
        let four = LocaleOpportunityFinder.estimatedRequests(
            seedCount: 5, storefronts: 4, candidatesPerStorefront: 25)
        XCTAssertEqual(one, 31)
        XCTAssertEqual(four, 124)
    }

    func testProspectStorefrontsAreWellFormed() {
        XCTAssertFalse(Storefront.prospects.isEmpty)
        for storefront in Storefront.prospects {
            XCTAssertEqual(storefront.country.count, 2, "\(storefront.name) country code")
            XCTAssertFalse(storefront.languageCode.isEmpty)
            XCTAssertFalse(storefront.locale.isEmpty)
        }
        // Belgium and the Netherlands share a language but are separate stores.
        let dutch = Storefront.prospects.filter { $0.languageCode == "nl" }
        XCTAssertEqual(Set(dutch.map(\.country)), ["nl", "be"])
    }

    func testNoDuplicateStorefronts() {
        let countries = Storefront.prospects.map(\.country)
        XCTAssertEqual(Set(countries).count, countries.count)
    }
}
