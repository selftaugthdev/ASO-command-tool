import Foundation
import ASOCore

/// A recorded metadata change.
public struct MetadataEvent: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        /// Pushed from this app, so the timestamp is exact.
        case push
        /// Noticed on a later pull, having been changed elsewhere. The
        /// timestamp is when it was seen, not when it happened.
        case detected
    }

    public var id: Int64
    public var appId: String
    public var locale: String
    public var field: MetadataField
    public var oldValue: String?
    public var newValue: String?
    public var source: Source
    public var occurredAt: Date

    public init(id: Int64, appId: String, locale: String, field: MetadataField,
                oldValue: String?, newValue: String?, source: Source, occurredAt: Date) {
        self.id = id
        self.appId = appId
        self.locale = locale
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.occurredAt = occurredAt
    }

    /// Short description of what moved, for a chart annotation.
    public var summary: String {
        switch field {
        case .keywords:
            let added = Self.terms(newValue).subtracting(Self.terms(oldValue))
            let removed = Self.terms(oldValue).subtracting(Self.terms(newValue))
            var parts: [String] = []
            if !added.isEmpty { parts.append("+\(added.sorted().joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("−\(removed.sorted().joined(separator: ", "))") }
            return parts.isEmpty ? "keywords edited" : parts.joined(separator: "  ")
        default:
            return "\(field.displayName) changed"
        }
    }

    private static func terms(_ value: String?) -> Set<String> {
        Set((value ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }
}

/// What happened to ranks around a metadata change.
///
/// The comparison a dashboard cannot make for you: not "where do I rank" but
/// "did the thing I did work". Deliberately reports the sample sizes alongside
/// the averages, because a two-position gain across four keywords is noise.
public struct ChangeImpact: Identifiable, Sendable {
    public var id: Int64 { event.id }
    public var event: MetadataEvent
    public var averageRankBefore: Double?
    public var averageRankAfter: Double?
    public var improved: Int
    public var declined: Int
    public var unchanged: Int
    /// Keywords that had a reading on both sides of the change.
    public var comparable: Int { improved + declined + unchanged }

    /// Positive means ranks got better, since lower positions are better.
    public var averageMovement: Double? {
        guard let before = averageRankBefore, let after = averageRankAfter else { return nil }
        return before - after
    }

    /// Whether there is enough evidence to say anything at all.
    ///
    /// Rank data is noisy and Apple reshuffles constantly; a handful of
    /// keywords moving proves nothing, so the UI is told to stay quiet rather
    /// than dressing up noise as a result.
    public var isConclusive: Bool {
        guard comparable >= 8, let movement = averageMovement else { return false }
        return abs(movement) >= 1.5
    }

    public var verdict: String {
        guard let movement = averageMovement else {
            return "Not enough rank history on both sides of this change yet."
        }
        guard comparable >= 8 else {
            return "Only \(comparable) keyword(s) have readings either side — too few to judge."
        }
        guard abs(movement) >= 1.5 else {
            return "No material movement (\(improved) up, \(declined) down). "
                 + "Within normal day-to-day noise."
        }
        let direction = movement > 0 ? "improved" : "declined"
        return String(format: "Average rank %@ by %.1f positions across %d keywords "
                            + "(%d up, %d down).",
                      direction, abs(movement), comparable, improved, declined)
    }
}

/// One competitor's grip on a keyword set.
public struct CompetitorPresence: Identifiable, Hashable, Sendable {
    public var id: String { appId }
    public var appId: String
    public var appName: String
    /// Tracked keywords where this app appears in the results at all.
    public var appearances: Int
    /// Of those, how many it holds a top-ten position for.
    public var topTen: Int
    public var averageRank: Double
    public var ratingCount: Int?
    /// Keywords where it outranks us, most contested first.
    public var beatsUsOn: [String]

    public var topTenShare: Double {
        appearances > 0 ? Double(topTen) / Double(appearances) : 0
    }
}

extension ASOStore {

    // MARK: - Metadata events

    @discardableResult
    public func recordMetadataEvent(appId: String, locale: String, field: MetadataField,
                                    oldValue: String?, newValue: String?,
                                    source: MetadataEvent.Source,
                                    at date: Date = Date()) throws -> Int64 {
        try database.run("""
            INSERT INTO metadata_events
                (app_id, locale, field, old_value, new_value, source, occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """, [.text(appId), .text(locale), .text(field.rawValue),
                  .text(oldValue), .text(newValue), .text(source.rawValue), .date(date)])
    }

    public func metadataEvents(appId: String, locale: String? = nil,
                               days: Int = 180) throws -> [MetadataEvent] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var sql = """
            SELECT id, app_id, locale, field, old_value, new_value, source, occurred_at
            FROM metadata_events WHERE app_id = ? AND occurred_at >= ?
            """
        var parameters: [SQLValue] = [.text(appId), .date(cutoff)]
        if let locale {
            sql += " AND locale = ?"
            parameters.append(.text(locale))
        }
        sql += " ORDER BY occurred_at DESC;"

        return try database.query(sql, parameters) { row in
            MetadataEvent(
                id: row.int(0) ?? 0,
                appId: row.string(1) ?? "",
                locale: row.string(2) ?? "",
                field: MetadataField(rawValue: row.string(3) ?? "") ?? .keywords,
                oldValue: row.string(4),
                newValue: row.string(5),
                source: MetadataEvent.Source(rawValue: row.string(6) ?? "push") ?? .push,
                occurredAt: row.date(7) ?? Date())
        }
    }

    /// Measures rank movement either side of a change.
    ///
    /// Uses the mean of each keyword's readings in the window rather than a
    /// single point, so one unusual day does not decide the verdict. Keywords
    /// lacking a reading on either side are excluded rather than defaulted,
    /// because an absent rank is not a bad rank.
    public func impact(of event: MetadataEvent, country: String,
                       windowDays: Int = 7) throws -> ChangeImpact {
        let window = Double(windowDays) * 86_400
        let before = event.occurredAt.addingTimeInterval(-window)
        let after = event.occurredAt.addingTimeInterval(window)

        let rows = try database.query("""
            SELECT k.id,
                   AVG(CASE WHEN r.captured_at <  ? AND r.captured_at >= ?
                            THEN r.rank END),
                   AVG(CASE WHEN r.captured_at >= ? AND r.captured_at <= ?
                            THEN r.rank END)
            FROM keywords k
            JOIN rank_snapshots r ON r.keyword_id = k.id
            WHERE k.app_id = ? AND k.country = ?
            GROUP BY k.id;
            """, [.date(event.occurredAt), .date(before),
                  .date(event.occurredAt), .date(after),
                  .text(event.appId), .text(country)]) { row in
            (before: row.double(1), after: row.double(2))
        }

        var beforeTotal = 0.0, afterTotal = 0.0, counted = 0
        var improved = 0, declined = 0, unchanged = 0

        for row in rows {
            guard let rankBefore = row.before, let rankAfter = row.after else { continue }
            beforeTotal += rankBefore
            afterTotal += rankAfter
            counted += 1
            // Lower is better, so a decrease is an improvement.
            if rankAfter < rankBefore - 0.5 { improved += 1 }
            else if rankAfter > rankBefore + 0.5 { declined += 1 }
            else { unchanged += 1 }
        }

        return ChangeImpact(
            event: event,
            averageRankBefore: counted > 0 ? beforeTotal / Double(counted) : nil,
            averageRankAfter: counted > 0 ? afterTotal / Double(counted) : nil,
            improved: improved, declined: declined, unchanged: unchanged)
    }

    // MARK: - Competitor presence

    /// Replaces the stored result set for one keyword.
    public func recordSERP(keywordId: Int64,
                           entries: [(rank: Int, appId: String, name: String,
                                      ratingCount: Int?)],
                           at date: Date = Date()) throws {
        try database.transaction {
            try database.run("DELETE FROM serp_entries WHERE keyword_id = ?;",
                             [.int(keywordId)])
            for entry in entries {
                try database.run("""
                    INSERT INTO serp_entries
                        (keyword_id, rank, app_id, app_name, rating_count, captured_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """, [.int(keywordId), .int(Int64(entry.rank)), .text(entry.appId),
                          .text(entry.name), .int(entry.ratingCount), .date(date)])
            }
        }
    }

    /// Which apps dominate the keyword set already being tracked.
    ///
    /// Costs nothing extra: it reads results captured during the ordinary rank
    /// refresh, rather than probing competitors against a keyword universe.
    public func competitorPresence(appId: String, country: String,
                                   limit: Int = 25) throws -> [CompetitorPresence] {
        let rows = try database.query("""
            SELECT s.app_id, s.app_name, COUNT(*) AS appearances,
                   SUM(CASE WHEN s.rank <= 10 THEN 1 ELSE 0 END) AS top_ten,
                   AVG(s.rank) AS avg_rank,
                   MAX(s.rating_count) AS ratings
            FROM serp_entries s
            JOIN keywords k ON k.id = s.keyword_id
            WHERE k.app_id = ? AND k.country = ? AND s.app_id <> ?
            GROUP BY s.app_id
            ORDER BY top_ten DESC, appearances DESC
            LIMIT ?;
            """, [.text(appId), .text(country), .text(appId), .int(Int64(limit))]) { row in
            (id: row.string(0) ?? "", name: row.string(1) ?? "",
             appearances: Int(row.int(2) ?? 0), topTen: Int(row.int(3) ?? 0),
             avgRank: row.double(4) ?? 0, ratings: row.int(5).map(Int.init))
        }

        return try rows.map { row in
            // Terms where they place above us, or where we do not appear at all.
            let beats = try database.query("""
                SELECT k.term
                FROM serp_entries s
                JOIN keywords k ON k.id = s.keyword_id
                LEFT JOIN serp_entries mine
                       ON mine.keyword_id = k.id AND mine.app_id = ?
                WHERE k.app_id = ? AND k.country = ? AND s.app_id = ?
                  AND (mine.rank IS NULL OR s.rank < mine.rank)
                ORDER BY s.rank
                LIMIT 12;
                """, [.text(appId), .text(appId), .text(country), .text(row.id)]) {
                $0.string(0) ?? ""
            }

            return CompetitorPresence(appId: row.id, appName: row.name,
                                      appearances: row.appearances, topTen: row.topTen,
                                      averageRank: row.avgRank, ratingCount: row.ratings,
                                      beatsUsOn: beats)
        }
    }
}
