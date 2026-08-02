import Foundation

/// One keyword row recovered from an external export.
/// Ranks at or beyond this are treated as "not ranked".
///
/// Export formats signal "outside the charts" with a sentinel rather than an
/// empty cell — 1000, 999 and -1 are all common — and importing those literally
/// puts a fake "#1000" on every unranked keyword. Apple's search results are
/// capped well below this, so anything above it cannot be a real position.
let unrankedSentinelThreshold = 250

public struct ImportedKeyword: Identifiable, Hashable, Sendable {
    public var id: String { "\(term)|\(country ?? "")" }
    public var term: String
    /// Volume or popularity from the source tool, kept only for display.
    public var volume: Double?
    public var difficulty: Double?
    public var rank: Int?
    public var country: String?

    public init(term: String, volume: Double? = nil, difficulty: Double? = nil,
                rank: Int? = nil, country: String? = nil) {
        self.term = term
        self.volume = volume
        self.difficulty = difficulty
        self.rank = rank
        self.country = country
    }
}

public struct ImportResult: Sendable {
    public var keywords: [ImportedKeyword]
    /// Which column each field was read from, so the user can sanity-check the
    /// guess before committing the import.
    public var detectedColumns: [String: String]
    public var skippedRows: Int
    public var hadHeader: Bool

    public var isEmpty: Bool { keywords.isEmpty }
}

/// Parses keyword exports from other ASO tools.
///
/// Written against no single vendor's format on purpose: TryAstro, AppTweak,
/// Appfigures and Sensor Tower all export CSVs with different column names and
/// delimiters, and a hardcoded parser breaks the first time one of them renames
/// a column. This detects the delimiter and matches columns by keyword rather
/// than position.
public enum KeywordImporter {

    /// Column-name synonyms, lowercased. First match wins.
    private static let termNames = [
        "keyword", "keywords", "term", "terms", "query", "search term",
        "phrase", "kw", "search query", "zoekterm", "trefwoord",
    ]
    private static let volumeNames = [
        "volume", "search volume", "popularity", "traffic", "searches",
        "search popularity", "vol", "monthly searches",
    ]
    private static let difficultyNames = [
        "difficulty", "competition", "kd", "chance", "difficulty score",
        "competitiveness",
    ]
    private static let rankNames = ["rank", "position", "current rank", "pos"]
    private static let countryNames = ["country", "storefront", "market", "region", "locale"]

    /// Parses CSV, TSV, or a plain newline/comma-separated list.
    public static func parse(_ raw: String) -> ImportResult {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else {
            return ImportResult(keywords: [], detectedColumns: [:],
                                skippedRows: 0, hadHeader: false)
        }

        let delimiter = detectDelimiter(in: lines)

        // A single column with no delimiter is just a list of terms; treat the
        // whole thing as keywords, including comma-separated on one line.
        guard let delimiter else {
            let terms = lines.flatMap { line in
                line.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return buildResult(terms: terms, detected: ["keyword": "(plain list)"],
                               hadHeader: false)
        }

        let rows = lines.map { splitRow($0, delimiter: delimiter) }
        guard let firstRow = rows.first else {
            return ImportResult(keywords: [], detectedColumns: [:],
                                skippedRows: 0, hadHeader: false)
        }

        let header = firstRow.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let termIndex = index(of: termNames, in: header)

        // A lone delimited line with no recognisable keyword column is a
        // comma-separated list of terms, not a header — treating it as a header
        // would consume the only row and import nothing.
        if rows.count == 1 && termIndex == nil {
            return buildResult(terms: firstRow, detected: ["keyword": "(plain list)"],
                               hadHeader: false)
        }

        let hadHeader = termIndex != nil || looksLikeHeader(header)

        // With no recognisable header, assume the first column holds the terms.
        let columnFor: (Int?) -> Int? = { $0 }
        let term = termIndex ?? 0
        let volume = index(of: volumeNames, in: header)
        let difficulty = index(of: difficultyNames, in: header)
        let rank = index(of: rankNames, in: header)
        let country = index(of: countryNames, in: header)

        var detected: [String: String] = [
            "keyword": hadHeader && termIndex != nil ? firstRow[term] : "column 1",
        ]
        if let volume { detected["volume"] = firstRow[volume] }
        if let difficulty { detected["difficulty"] = firstRow[difficulty] }
        if let rank { detected["rank"] = firstRow[rank] }
        if let country { detected["country"] = firstRow[country] }

        var keywords: [ImportedKeyword] = []
        var skipped = 0
        var seen = Set<String>()

        for row in rows.dropFirst(hadHeader ? 1 : 0) {
            guard term < row.count else { skipped += 1; continue }
            let value = row[term].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else { skipped += 1; continue }

            let normalized = value.lowercased()
            guard !seen.contains(normalized) else { skipped += 1; continue }
            seen.insert(normalized)

            func number(_ index: Int?) -> Double? {
                guard let index, index < row.count else { return nil }
                // Strip thousands separators and stray symbols such as "%".
                let cleaned = row[index]
                    .replacingOccurrences(of: ",", with: ".")
                    .filter { $0.isNumber || $0 == "." || $0 == "-" }
                return Double(cleaned)
            }

            keywords.append(ImportedKeyword(
                term: normalized,
                volume: number(columnFor(volume)),
                difficulty: number(columnFor(difficulty)),
                rank: number(columnFor(rank)).map { Int($0) }
                    .flatMap { $0 > 0 && $0 < unrankedSentinelThreshold ? $0 : nil },
                country: country.flatMap { index -> String? in
                    guard index < row.count else { return nil }
                    let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value.lowercased()
                }))
        }

        return ImportResult(keywords: keywords, detectedColumns: detected,
                            skippedRows: skipped, hadHeader: hadHeader)
    }

    private static func buildResult(terms: [String], detected: [String: String],
                                    hadHeader: Bool) -> ImportResult {
        var keywords: [ImportedKeyword] = []
        var skipped = 0
        var seen = Set<String>()
        for term in terms {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                skipped += 1
                continue
            }
            seen.insert(normalized)
            keywords.append(ImportedKeyword(term: normalized))
        }
        return ImportResult(keywords: keywords, detectedColumns: detected,
                            skippedRows: skipped, hadHeader: hadHeader)
    }

    /// Picks the delimiter that yields the most consistent column count.
    private static func detectDelimiter(in lines: [String]) -> Character? {
        let candidates: [Character] = ["\t", ";", ","]
        let sample = Array(lines.prefix(10))

        var best: (delimiter: Character, columns: Int)?
        for candidate in candidates {
            let counts = sample.map { splitRow($0, delimiter: candidate).count }
            guard let first = counts.first, first > 1 else { continue }
            // Every sampled row must agree, otherwise this is not the delimiter.
            guard counts.allSatisfy({ $0 == first }) else { continue }
            if best == nil || first > best!.columns {
                best = (candidate, first)
            }
        }
        return best?.delimiter
    }

    /// Splits one CSV row, honouring double-quoted fields containing delimiters.
    static func splitRow(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")   // escaped quote
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func index(of names: [String], in header: [String]) -> Int? {
        // Exact match first so "volume" does not lose to "search volume rank".
        for (offset, column) in header.enumerated() where names.contains(column) {
            return offset
        }
        for (offset, column) in header.enumerated() {
            if names.contains(where: { column.contains($0) }) { return offset }
        }
        return nil
    }

    /// A row of mostly non-numeric short strings is probably a header.
    private static func looksLikeHeader(_ row: [String]) -> Bool {
        let numeric = row.filter { Double($0) != nil }.count
        return numeric == 0 && row.count > 1
    }
}
