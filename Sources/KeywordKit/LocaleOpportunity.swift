import Foundation
import ASOCore
import ASOStore
import ASAKit

/// A storefront worth prospecting, with the language its metadata is written in.
public struct Storefront: Identifiable, Hashable, Sendable {
    public var id: String { country }
    public var country: String       // iTunes country code, e.g. "de"
    public var name: String
    public var languageCode: String  // for stopword filtering, e.g. "de"
    public var locale: String        // App Store Connect locale, e.g. "de-DE"

    public init(country: String, name: String, languageCode: String, locale: String) {
        self.country = country
        self.name = name
        self.languageCode = languageCode
        self.locale = locale
    }

    /// Storefronts where a localized listing is usually worth the effort:
    /// large enough to matter, and not English-speaking, so the keyword space
    /// is far less contested than the US store.
    public static let prospects: [Storefront] = [
        Storefront(country: "de", name: "Germany", languageCode: "de", locale: "de-DE"),
        Storefront(country: "fr", name: "France", languageCode: "fr", locale: "fr-FR"),
        Storefront(country: "es", name: "Spain", languageCode: "es", locale: "es-ES"),
        Storefront(country: "it", name: "Italy", languageCode: "it", locale: "it-IT"),
        Storefront(country: "nl", name: "Netherlands", languageCode: "nl", locale: "nl-NL"),
        Storefront(country: "be", name: "Belgium", languageCode: "nl", locale: "nl-NL"),
        Storefront(country: "br", name: "Brazil", languageCode: "pt", locale: "pt-BR"),
        Storefront(country: "mx", name: "Mexico", languageCode: "es", locale: "es-MX"),
        Storefront(country: "jp", name: "Japan", languageCode: "ja", locale: "ja"),
        Storefront(country: "kr", name: "South Korea", languageCode: "ko", locale: "ko"),
        Storefront(country: "tr", name: "Turkey", languageCode: "tr", locale: "tr"),
        Storefront(country: "pl", name: "Poland", languageCode: "pl", locale: "pl"),
        Storefront(country: "se", name: "Sweden", languageCode: "sv", locale: "sv"),
        Storefront(country: "ru", name: "Russia", languageCode: "ru", locale: "ru"),
    ]
}

/// Very common words per language, which carry no ranking value.
///
/// Short lists on purpose. The goal is to strip articles and filler, not to do
/// real linguistics; anything genuinely generic is caught later by the
/// title-density check, which is language-agnostic.
enum Stopwords {
    static func forLanguage(_ code: String) -> Set<String> {
        switch code {
        case "de": return ["der", "die", "das", "und", "für", "mit", "den", "dem", "ein",
                           "eine", "ist", "auf", "app", "von", "zum", "zur", "sie", "ihr",
                           "des", "als", "auch", "nicht", "bei", "aus", "sich", "dein"]
        case "fr": return ["le", "la", "les", "de", "des", "du", "et", "pour", "avec",
                           "une", "un", "est", "sur", "app", "vos", "votre", "dans",
                           "par", "au", "aux", "ce", "cette", "plus", "pas"]
        case "es": return ["el", "la", "los", "las", "de", "del", "y", "para", "con",
                           "una", "un", "es", "en", "app", "tu", "su", "por", "que",
                           "al", "lo", "más", "como"]
        case "it": return ["il", "lo", "la", "i", "gli", "le", "di", "del", "e", "per",
                           "con", "una", "un", "è", "in", "app", "tuo", "tua", "che",
                           "da", "su", "più", "come"]
        // "jou" and "jouw" are different words, as are "u"/"uw" — a list that
        // covers only one of each pair leaks the other into every candidate set.
        case "nl": return ["de", "het", "een", "en", "voor", "met", "van", "je", "jij",
                           "jou", "jouw", "uw", "op", "is", "zijn", "app", "die", "dat",
                           "aan", "bij", "uit", "naar", "als", "ook", "niet", "meer",
                           "over", "door", "wat", "kan", "wordt", "worden", "heeft"]
        case "pt": return ["o", "a", "os", "as", "de", "do", "da", "e", "para", "com",
                           "uma", "um", "é", "em", "app", "seu", "sua", "que", "no",
                           "na", "por", "mais", "como"]
        case "tr": return ["ve", "ile", "için", "bir", "bu", "da", "de", "en", "app",
                           "olarak", "daha", "çok", "her", "ne"]
        case "pl": return ["i", "w", "na", "do", "z", "dla", "to", "jest", "app", "nie",
                           "się", "po", "od", "za", "o", "przez"]
        case "sv": return ["och", "att", "det", "en", "ett", "för", "med", "på", "av",
                           "app", "som", "till", "den", "de", "är", "inte"]
        case "ru": return ["и", "в", "на", "с", "для", "не", "что", "это", "как", "по",
                           "app", "из", "от", "за", "к", "у"]
        // Japanese and Korean are not whitespace-delimited, so token filtering
        // does not apply; candidates there come through unfiltered and the
        // density check does the work.
        case "ja", "ko": return []
        default: return ["the", "and", "for", "with", "your", "you", "app", "from",
                         "this", "that", "are", "our", "all", "can", "get", "new"]
        }
    }
}

/// A localized keyword worth considering, with the evidence behind it.
public struct LocaleOpportunity: Identifiable, Hashable, Sendable {
    public var id: String { "\(country)|\(term)" }
    public var term: String
    public var country: String
    public var storefrontName: String

    /// Apple Search Ads popularity for this term in this storefront. Nil when
    /// Search Ads is not connected — the honest state, not a zero.
    public var popularity: Double?
    /// Locally computed competition score, 0–100.
    public var difficulty: Double
    /// How many of the top ten apps put this term in their title or subtitle.
    ///
    /// Used as a demand proxy when Search Ads is unavailable: developers do not
    /// spend title characters on words nobody searches, so a term several
    /// competitors localized for is one they believe converts. It is revealed
    /// preference, not measured volume, and is labelled as such.
    public var titleTargeting: Int
    /// Our current position in that storefront, nil when absent.
    public var ourRank: Int?
    public var competitorCount: Int

    /// Higher is better. Rewards demand and headroom, penalises difficulty.
    ///
    /// Uses real popularity when available and falls back to the targeting
    /// proxy otherwise, so the ordering stays useful without Search Ads while
    /// never presenting the proxy as if it were Apple's number.
    public var score: Double {
        let demand = popularity ?? (Double(titleTargeting) / 10 * 60)
        let headroom = ourRank == nil ? 1.15 : (ourRank! > 50 ? 1.05 : 0.85)
        return max(0, demand * (1 - difficulty / 120) * headroom)
    }

    public var demandIsMeasured: Bool { popularity != nil }
}

/// Finds localized keyword openings in non-English storefronts.
///
/// The premise, which this app's own data supports: an English term with real
/// demand is usually contested by every well-funded competitor, while its
/// translation in a smaller storefront often is not. Ranking fifth for a German
/// term nobody optimised for beats ranking nowhere for an English one everyone did.
public final class LocaleOpportunityFinder: @unchecked Sendable {
    private let search: iTunesSearchClient
    private let asa: ASAClient?

    public init(search: iTunesSearchClient = iTunesSearchClient(), asa: ASAClient? = nil) {
        self.search = search
        self.asa = asa
    }

    /// Rough request count, so the UI can predict how long a run takes before
    /// the user commits to it.
    public static func estimatedRequests(seedCount: Int, storefronts: Int,
                                         candidatesPerStorefront: Int) -> Int {
        // Per storefront: one search per seed to find local incumbents, one
        // lookup batch for their localized metadata, one search per candidate.
        storefronts * (seedCount + 1 + candidatesPerStorefront)
    }

    /// Discovers and scores localized candidates for one storefront.
    public func discover(
        for app: TrackedApp,
        storefront: Storefront,
        seedTerms: [String],
        maxCandidates: Int = 25,
        onProgress: (@Sendable (Int, Int) async -> Void)? = nil
    ) async throws -> [LocaleOpportunity] {
        // 1. Find who ranks for the seeds in that storefront. Their localized
        //    metadata is the source of candidate terms: it is written by people
        //    who researched that market.
        var incumbents: [String: StoreApp] = [:]
        for (index, seed) in seedTerms.enumerated() {
            try Task.checkCancellation()
            let results = try await search.search(term: seed,
                                                  country: storefront.country,
                                                  limit: 20)
            for result in results.prefix(10) { incumbents[result.id] = result }
            await onProgress?(index + 1, seedTerms.count + maxCandidates)
        }
        guard !incumbents.isEmpty else { return [] }

        // 2. Harvest candidate terms from that localized metadata.
        let stopwords = Stopwords.forLanguage(storefront.languageCode)
        var weights: [String: Double] = [:]
        for incumbent in incumbents.values {
            for (term, weight) in Self.candidates(from: incumbent, stopwords: stopwords) {
                weights[term, default: 0] += weight
            }
        }

        // Terms already in the seed set are the ones we came from; drop them so
        // the result is genuinely new vocabulary.
        let seedSet = Set(seedTerms.map { $0.lowercased() })
        let ranked = weights
            .filter { !seedSet.contains($0.key) }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(maxCandidates)
            .map(\.key)

        // 3. Real popularity where Search Ads can supply it.
        var popularityByTerm: [String: Double] = [:]
        if let asa,
           let suggestions = try? await asa.keywordSuggestions(
               adamId: app.id,
               countries: [storefront.country.uppercased()],
               seedTerms: Array(ranked)) {
            for suggestion in suggestions where suggestion.popularity != nil {
                popularityByTerm[suggestion.text.lowercased()] = suggestion.popularity
            }
        }

        // 4. Score each candidate against that storefront's actual results.
        var opportunities: [LocaleOpportunity] = []
        for (index, term) in ranked.enumerated() {
            try Task.checkCancellation()
            let results = try await search.search(term: term,
                                                  country: storefront.country,
                                                  limit: 100)
            guard !results.isEmpty else { continue }

            let difficulty = DifficultyScorer.score(results: results, term: term,
                                                    requestedLimit: 100)
            let targeting = results.prefix(10).filter {
                $0.indexedTitleText.lowercased().contains(term)
            }.count

            opportunities.append(LocaleOpportunity(
                term: term,
                country: storefront.country,
                storefrontName: storefront.name,
                popularity: popularityByTerm[term],
                difficulty: difficulty,
                titleTargeting: targeting,
                ourRank: results.firstIndex { $0.id == app.id }.map { $0 + 1 },
                competitorCount: results.count))

            await onProgress?(seedTerms.count + index + 1,
                              seedTerms.count + ranked.count)
        }

        return opportunities.sorted { $0.score > $1.score }
    }

    /// Pulls weighted candidate terms out of one app's localized metadata.
    ///
    /// Title and subtitle are weighted far above description because that is
    /// where Apple's ranking weight sits, and because a developer who put a
    /// term in a 30-character title chose it deliberately.
    static func candidates(from app: StoreApp,
                           stopwords: Set<String>) -> [(String, Double)] {
        func tokenize(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { token in
                    token.count > 2 && !stopwords.contains(token) && Int(token) == nil
                }
        }

        var weights: [String: Double] = [:]
        let titleTokens = tokenize(app.indexedTitleText)
        for token in titleTokens { weights[token, default: 0] += 6 }
        for token in tokenize(app.description).prefix(120) { weights[token, default: 0] += 1 }

        // Two-word title phrases are frequently the real target term.
        for pair in zip(titleTokens, titleTokens.dropFirst()) {
            weights["\(pair.0) \(pair.1)", default: 0] += 5
        }
        return weights.map { ($0.key, $0.value) }
    }
}
