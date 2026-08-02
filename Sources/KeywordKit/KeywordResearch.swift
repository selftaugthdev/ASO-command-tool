import Foundation
import ASOCore
import ASOStore
import ASAKit

/// Where a keyword metric came from, so the UI never presents an estimate as
/// if Apple had reported it.
public enum MetricSource: String, Sendable {
    /// Apple Search Ads popularity index — real Apple search data.
    case appleSearchAds
    /// Derived locally from store search results.
    case derived
    /// Carried in from another tool's export. Its scale is that vendor's, not
    /// Apple's, so it is never presented as an Apple figure.
    case imported
    case unknown

    public var shortLabel: String {
        switch self {
        case .appleSearchAds: return "Apple"
        case .derived: return "derived"
        case .imported: return "imported"
        case .unknown: return "—"
        }
    }

    public var explanation: String {
        switch self {
        case .appleSearchAds:
            return "Apple Search Ads popularity index (0–100)."
        case .derived:
            return "Calculated locally from store search results."
        case .imported:
            return "Volume carried in from another tool's export. That vendor's scale, "
                 + "not Apple's — useful for ordering keywords, not comparable with "
                 + "Apple's popularity index."
        case .unknown:
            return "No popularity data. Connect Apple Search Ads, or import a list "
                 + "that includes a volume column."
        }
    }
}

public struct KeywordInsight: Identifiable, Hashable, Sendable {
    public var id: String { "\(term)-\(country)" }
    public var term: String
    public var country: String
    /// Apple's search popularity, 0–100. Nil when Search Ads has no data.
    public var popularity: Double?
    public var popularitySource: MetricSource
    /// Locally derived competition score, 0–100, higher is harder to rank for.
    public var difficulty: Double
    public var competitorCount: Int
    /// Our app's position in results, nil when it does not appear at all.
    public var rank: Int?
    public var suggestedBid: Double?

    /// Rough opportunity heuristic: reward popularity, penalise difficulty.
    ///
    /// Only meaningful when popularity is real; returns nil otherwise rather
    /// than inventing a score from a guessed volume.
    public var opportunityScore: Double? {
        guard let popularity else { return nil }
        return max(0, min(100, popularity * (1 - difficulty / 130)))
    }
}

/// Scores keyword difficulty from public store data.
public enum DifficultyScorer {

    /// Combines three observable signals into a 0–100 difficulty score.
    ///
    /// Apple publishes no difficulty metric, so this is explicitly a local
    /// heuristic. The weights favour title matching because exact-title matches
    /// dominate Apple's ranking far more than review counts do.
    ///
    /// - `titleMatchRatio`: share of the top results with the full term in their
    ///   title, the strongest signal that a term is deliberately contested.
    /// - `ratingStrength`: log-scaled median rating count of the top results,
    ///   a proxy for how entrenched the incumbents are.
    /// - `saturation`: how full the result set is relative to what was asked for.
    public static func score(results: [StoreApp], term: String, requestedLimit: Int) -> Double {
        guard !results.isEmpty else { return 0 }

        let normalizedTerm = term.lowercased().trimmingCharacters(in: .whitespaces)
        let topResults = Array(results.prefix(10))

        let titleMatches = topResults.filter {
            $0.indexedTitleText.lowercased().contains(normalizedTerm)
        }.count
        let titleMatchRatio = Double(titleMatches) / Double(topResults.count)

        let ratingCounts = topResults.map { Double($0.ratingCount) }.sorted()
        let medianRatings = ratingCounts.isEmpty ? 0 : ratingCounts[ratingCounts.count / 2]
        // 100k ratings saturates the scale; log keeps small differences visible
        // at the low end where indie apps actually compete.
        let ratingStrength = min(1, log10(medianRatings + 1) / 5)

        let saturation = min(1, Double(results.count) / Double(max(1, requestedLimit)))

        let raw = 0.5 * titleMatchRatio + 0.35 * ratingStrength + 0.15 * saturation
        return (raw * 100).rounded()
    }
}

/// Keyword research and rank tracking.
public final class KeywordResearcher: @unchecked Sendable {
    private let search: iTunesSearchClient
    private let asa: ASAClient?
    private let store: ASOStore

    public init(store: ASOStore, search: iTunesSearchClient = iTunesSearchClient(),
                asa: ASAClient? = nil) {
        self.store = store
        self.search = search
        self.asa = asa
    }

    /// Researches a batch of terms for one app.
    ///
    /// Search Ads is queried once for the whole batch rather than per term,
    /// because its recommendations endpoint returns popularity for many terms
    /// in a single call.
    public func research(terms: [String], for app: TrackedApp,
                         country: String = "us",
                         onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> [KeywordInsight] {
        var popularityByTerm: [String: (popularity: Double?, bid: Double?)] = [:]
        if let asa {
            // A Search Ads failure must not sink the whole research run; the
            // derived signals are still useful on their own.
            if let suggestions = try? await asa.keywordSuggestions(
                adamId: app.id,
                countries: [country.uppercased()],
                seedTerms: terms) {
                for suggestion in suggestions {
                    popularityByTerm[suggestion.text.lowercased()] =
                        (suggestion.popularity, suggestion.suggestedBid)
                }
            }
        }

        var insights: [KeywordInsight] = []
        await onProgress?(0, terms.count)

        for (index, term) in terms.enumerated() {
            try Task.checkCancellation()

            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }

            let results = try await search.search(term: normalized, country: country, limit: 100)
            let difficulty = DifficultyScorer.score(results: results,
                                                    term: normalized,
                                                    requestedLimit: 100)
            let rank = results.firstIndex { $0.id == app.id }.map { $0 + 1 }
            let apple = popularityByTerm[normalized]

            insights.append(KeywordInsight(
                term: normalized,
                country: country,
                popularity: apple?.popularity,
                popularitySource: apple?.popularity != nil ? .appleSearchAds : .unknown,
                difficulty: difficulty,
                competitorCount: results.count,
                rank: rank,
                suggestedBid: apple?.bid))

            await onProgress?(index + 1, terms.count)
        }
        return insights
    }

    /// Persists research output as tracked keywords with metrics and a rank point.
    public func persist(_ insights: [KeywordInsight], appId: String) throws {
        for insight in insights {
            let keywordId = try store.addKeyword(appId: appId,
                                                 term: insight.term,
                                                 country: insight.country)
            try store.updateMetrics(keywordId: keywordId,
                                    popularity: insight.popularity,
                                    difficulty: insight.difficulty,
                                    competitors: insight.competitorCount,
                                    source: insight.popularitySource.rawValue)
            try store.recordRank(keywordId: keywordId, rank: insight.rank)
        }
    }

    /// Re-checks rank for every tracked keyword of an app. Used by the daily job.
    ///
    /// Records a nil rank when the app is absent from results, which is
    /// meaningful data: it distinguishes "dropped out of the top 100" from
    /// "we did not check today".
    @discardableResult
    public func refreshRanks(
        for app: TrackedApp,
        country: String,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> [TrackedKeyword] {
        let keywords = try store.keywords(appId: app.id, country: country)
        await onProgress?(0, keywords.count)

        for (index, keyword) in keywords.enumerated() {
            // Checked per iteration so a stop takes effect within one request
            // rather than at the end of a twenty-minute run. Everything already
            // written stays written.
            try Task.checkCancellation()

            let results = try await search.search(term: keyword.term,
                                                 country: country, limit: 100)
            let rank = results.firstIndex { $0.id == app.id }.map { $0 + 1 }
            try store.recordRank(keywordId: keyword.id, rank: rank)

            // The same search result set already answers difficulty, so scoring
            // it here costs no extra request. Imported keywords otherwise stay
            // blank forever, because nothing else backfills them.
            let difficulty = DifficultyScorer.score(results: results,
                                                    term: keyword.term,
                                                    requestedLimit: 100)
            try store.updateCompetition(keywordId: keyword.id,
                                        difficulty: difficulty,
                                        competitors: results.count)

            await onProgress?(index + 1, keywords.count)
        }
        return try store.keywords(appId: app.id, country: country)
    }

    /// Roughly how long one keyword lookup takes, for an up-front estimate.
    ///
    /// Apple soft-limits the unauthenticated search endpoint, and the client's
    /// rate limiter paces requests to stay under it, so throughput is close to
    /// constant and this is a fair predictor before any samples exist.
    public static let secondsPerKeywordLookup: Double = 3.6
}

// MARK: - Competitor analysis

public struct CompetitorOverlap: Sendable {
    public var competitor: StoreApp
    /// Terms the competitor ranks for that we also track.
    public var sharedTerms: [String]
    /// Terms they rank for and we do not track at all.
    public var gapTerms: [String]
    /// Terms where they outrank us, with both positions.
    public var losingTerms: [(term: String, ours: Int?, theirs: Int)]

    public var overlapRatio: Double {
        let total = sharedTerms.count + gapTerms.count
        return total > 0 ? Double(sharedTerms.count) / Double(total) : 0
    }
}

/// Estimates a competitor's keyword set and compares it with ours.
public final class CompetitorAnalyzer: @unchecked Sendable {
    private let search: iTunesSearchClient
    private let store: ASOStore

    public init(store: ASOStore, search: iTunesSearchClient = iTunesSearchClient()) {
        self.store = store
        self.search = search
    }

    /// Extracts candidate keywords from a competitor's visible metadata.
    ///
    /// Apple's keywords field is not public, so this reconstructs a likely set
    /// from title, subtitle and description. It is an estimate by construction —
    /// there is no API that returns a competitor's real keyword field.
    public static func extractKeywords(from app: StoreApp, maxTerms: Int = 40) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "your", "you", "are", "our", "all", "can",
            "get", "app", "from", "this", "that", "has", "have", "will", "more",
            "out", "use", "new", "now", "not", "but", "its", "their", "them", "they",
            "when", "what", "into", "over", "just", "also", "than", "then", "been",
        ]

        // Title and subtitle carry the most ranking weight, so terms appearing
        // there are counted more heavily than description-only terms.
        func tokenize(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) && Int($0) == nil }
        }

        var weights: [String: Double] = [:]
        for token in tokenize(app.indexedTitleText) { weights[token, default: 0] += 5 }
        for token in tokenize(app.description) { weights[token, default: 0] += 1 }

        // Two-word phrases from the title often are the real target term
        // ("migraine tracker" rather than "migraine" and "tracker").
        let titleTokens = tokenize(app.indexedTitleText)
        for pair in zip(titleTokens, titleTokens.dropFirst()) {
            weights["\(pair.0) \(pair.1)", default: 0] += 4
        }

        return weights.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(maxTerms)
            .map(\.key)
    }

    /// Compares a competitor's estimated keyword set against our tracked terms.
    public func overlap(competitorId: String, app: TrackedApp,
                        country: String = "us") async throws -> CompetitorOverlap {
        guard let competitor = try await search.lookup(ids: [competitorId],
                                                      country: country).first else {
            throw APIError(kind: .notFound,
                           message: "No app found for id \(competitorId) in \(country)")
        }

        let theirTerms = Set(Self.extractKeywords(from: competitor))
        let ourTerms = Set(try store.keywords(appId: app.id, country: country).map(\.term))

        let shared = theirTerms.intersection(ourTerms).sorted()
        let gaps = theirTerms.subtracting(ourTerms).sorted()

        // Only the shared terms are rank-checked: each check is a search call,
        // and the gap terms have no "ours" position to compare against yet.
        var losing: [(term: String, ours: Int?, theirs: Int)] = []
        for term in shared {
            let results = try await search.search(term: term, country: country, limit: 100)
            let ourRank = results.firstIndex { $0.id == app.id }.map { $0 + 1 }
            let theirRank = results.firstIndex { $0.id == competitor.id }.map { $0 + 1 }
            if let theirRank, ourRank == nil || ourRank! > theirRank {
                losing.append((term, ourRank, theirRank))
            }
        }

        return CompetitorOverlap(competitor: competitor,
                                 sharedTerms: shared,
                                 gapTerms: gaps,
                                 losingTerms: losing)
    }

    /// Stores a competitor snapshot for later change detection.
    public func snapshot(competitorId: String, country: String = "us") async throws {
        guard let app = try await search.lookup(ids: [competitorId], country: country).first else {
            return
        }
        // Hashing the URL list detects a screenshot swap without downloading
        // the images; Apple changes the filename whenever the asset changes.
        let screenshotHash = String(app.screenshotURLs.joined(separator: "|").hashValue)
        try store.recordCompetitorSnapshot(competitorId: competitorId,
                                           country: country,
                                           title: app.name,
                                           subtitle: app.subtitle,
                                           description: app.description,
                                           version: app.version,
                                           screenshotHash: screenshotHash)
    }
}
