import Foundation
import ASOCore

// MARK: - Domain types

public struct TrackedKeyword: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var appId: String
    public var term: String
    public var country: String
    public var addedAt: Date

    public var popularity: Double?   // 0–100; scale depends on popularitySource
    public var difficulty: Double?   // derived 0–100, higher is harder
    public var competitors: Int?
    public var currentRank: Int?
    public var previousRank: Int?
    /// Raw source string for `popularity`, so the UI can label where it came
    /// from rather than implying every number is Apple's.
    public var popularitySource: String = "unknown"

    /// Positive means the app moved up (toward rank 1).
    public var rankDelta: Int? {
        guard let currentRank, let previousRank else { return nil }
        return previousRank - currentRank
    }

    // MARK: Sort keys
    //
    // SwiftUI's `TableColumn(value:)` needs a non-optional Comparable, and every
    // interesting metric here is optional until it has been fetched. These map
    // "no data" to a value that lands at the far end of the direction you would
    // actually sort in, so unranked and unmeasured rows sink to the bottom
    // rather than crowding out the results.

    /// Unranked sorts after every real position, since ascending means best first.
    public var sortRank: Int { currentRank ?? Int.max }
    public var sortDelta: Int { rankDelta ?? 0 }
    /// Descending is the useful direction for these, so absent sorts as below zero.
    public var sortPopularity: Double { popularity ?? -1 }
    public var sortDifficulty: Double { difficulty ?? -1 }
    public var sortCompetitors: Int { competitors ?? -1 }

    public init(id: Int64, appId: String, term: String, country: String, addedAt: Date) {
        self.id = id
        self.appId = appId
        self.term = term
        self.country = country
        self.addedAt = addedAt
    }
}

public struct RankPoint: Hashable, Sendable, Identifiable {
    public var id: String { "\(keywordId)-\(capturedAt.timeIntervalSince1970)" }
    public var keywordId: Int64
    public var rank: Int?
    public var capturedAt: Date

    public init(keywordId: Int64, rank: Int?, capturedAt: Date) {
        self.keywordId = keywordId
        self.rank = rank
        self.capturedAt = capturedAt
    }
}

public struct SpendRow: Hashable, Sendable {
    public var appId: String
    public var campaignId: String
    public var campaignName: String?
    public var adGroupId: String?
    public var keywordId: String?
    public var keywordText: String?
    public var country: String?
    public var day: Date
    public var spend: Double
    public var impressions: Int
    public var taps: Int
    public var installs: Int

    public init(appId: String, campaignId: String, campaignName: String? = nil,
                adGroupId: String? = nil, keywordId: String? = nil,
                keywordText: String? = nil, country: String? = nil,
                day: Date, spend: Double, impressions: Int, taps: Int, installs: Int) {
        self.appId = appId
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.adGroupId = adGroupId
        self.keywordId = keywordId
        self.keywordText = keywordText
        self.country = country
        self.day = day
        self.spend = spend
        self.impressions = impressions
        self.taps = taps
        self.installs = installs
    }
}

public struct RevenueEvent: Hashable, Sendable {
    public var eventId: String
    public var appId: String?
    public var appUserId: String?
    public var type: String
    public var productId: String?
    public var store: String?
    public var country: String?
    public var revenueUSD: Double
    public var isTrial: Bool
    public var occurredAt: Date
    public var asaCampaignId: String?
    public var asaAdGroupId: String?
    public var asaKeywordId: String?

    public init(eventId: String, appId: String? = nil, appUserId: String? = nil,
                type: String, productId: String? = nil, store: String? = nil,
                country: String? = nil, revenueUSD: Double = 0, isTrial: Bool = false,
                occurredAt: Date, asaCampaignId: String? = nil,
                asaAdGroupId: String? = nil, asaKeywordId: String? = nil) {
        self.eventId = eventId
        self.appId = appId
        self.appUserId = appUserId
        self.type = type
        self.productId = productId
        self.store = store
        self.country = country
        self.revenueUSD = revenueUSD
        self.isTrial = isTrial
        self.occurredAt = occurredAt
        self.asaCampaignId = asaCampaignId
        self.asaAdGroupId = asaAdGroupId
        self.asaKeywordId = asaKeywordId
    }
}

/// Named `ASOAlert` rather than `Alert` because SwiftUI exports its own `Alert`,
/// and the collision makes every use in the app ambiguous.
public struct ASOAlert: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable { case info, warning, critical }

    public var id: Int64
    public var appId: String?
    public var kind: String
    public var title: String
    public var body: String
    public var severity: Severity
    public var createdAt: Date
    public var acknowledged: Bool

    public init(id: Int64, appId: String?, kind: String, title: String, body: String,
                severity: Severity, createdAt: Date, acknowledged: Bool) {
        self.id = id
        self.appId = appId
        self.kind = kind
        self.title = title
        self.body = body
        self.severity = severity
        self.createdAt = createdAt
        self.acknowledged = acknowledged
    }
}

// MARK: - Store

/// The local data store. Everything persists to a single SQLite file under
/// Application Support; nothing leaves the machine.
public final class ASOStore: @unchecked Sendable {
    public let database: Database

    public init(database: Database) throws {
        self.database = database
        try Schema.migrate(database)
    }

    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(database: Database(path: url.path))
    }

    /// The default on-disk location.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("ASOCommandCenter/aso.sqlite")
    }

    public static func standard() throws -> ASOStore {
        try ASOStore(url: defaultURL())
    }

    // MARK: Apps

    public func upsertApp(_ app: TrackedApp) throws {
        try database.run("""
            INSERT INTO apps (id, bundle_id, name, sku, primary_locale, countries)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                bundle_id = excluded.bundle_id,
                name = excluded.name,
                sku = excluded.sku,
                primary_locale = excluded.primary_locale,
                countries = excluded.countries;
            """, [.text(app.id), .text(app.bundleId), .text(app.name),
                  .text(app.sku), .text(app.primaryLocale),
                  .text(app.countries.joined(separator: ","))])
    }

    public func apps() throws -> [TrackedApp] {
        try database.query("""
            SELECT id, bundle_id, name, sku, primary_locale, countries
            FROM apps WHERE is_tracked = 1 ORDER BY name;
            """) { row in
            TrackedApp(id: row.string(0) ?? "",
                       bundleId: row.string(1) ?? "",
                       name: row.string(2) ?? "",
                       sku: row.string(3),
                       primaryLocale: row.string(4) ?? "en-US",
                       countries: (row.string(5) ?? "us")
                           .split(separator: ",").map(String.init))
        }
    }

    public func setTracked(_ tracked: Bool, appId: String) throws {
        try database.run("UPDATE apps SET is_tracked = ? WHERE id = ?;",
                         [.int(Int64(tracked ? 1 : 0)), .text(appId)])
    }

    // MARK: Metadata snapshots

    /// Records the live values so a push is always reversible.
    public func recordSnapshot(appId: String, metadata: [String: LocalizedMetadata],
                               at date: Date = Date()) throws {
        try database.transaction {
            for (locale, entry) in metadata {
                for (field, value) in entry.values {
                    try database.run("""
                        INSERT INTO metadata_snapshots (app_id, locale, field, value, captured_at)
                        VALUES (?, ?, ?, ?, ?);
                        """, [.text(appId), .text(locale), .text(field.rawValue),
                              .text(value), .date(date)])
                }
            }
        }
    }

    /// The most recent stored value for one field, used to offer a rollback.
    public func lastSnapshot(appId: String, locale: String,
                             field: MetadataField) throws -> (value: String, at: Date)? {
        try database.query("""
            SELECT value, captured_at FROM metadata_snapshots
            WHERE app_id = ? AND locale = ? AND field = ?
            ORDER BY captured_at DESC LIMIT 1;
            """, [.text(appId), .text(locale), .text(field.rawValue)]) { row in
            (row.string(0) ?? "", row.date(1) ?? Date())
        }.first
    }

    // MARK: Keywords

    @discardableResult
    public func addKeyword(appId: String, term: String, country: String,
                           at date: Date = Date()) throws -> Int64 {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try database.run("""
            INSERT INTO keywords (app_id, term, country, added_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(app_id, term, country) DO UPDATE SET is_tracked = 1;
            """, [.text(appId), .text(normalized), .text(country), .date(date)])
        return try keywordId(appId: appId, term: normalized, country: country) ?? 0
    }

    public func keywordId(appId: String, term: String, country: String) throws -> Int64? {
        try database.query(
            "SELECT id FROM keywords WHERE app_id = ? AND term = ? AND country = ?;",
            [.text(appId), .text(term.lowercased()), .text(country)]) { $0.int(0) }
            .compactMap { $0 }.first
    }

    public func removeKeyword(id: Int64) throws {
        try database.run("DELETE FROM keywords WHERE id = ?;", [.int(id)])
    }

    /// Keywords whose popularity falls below a threshold.
    ///
    /// `includeUnknown` is separate and defaults to false because a missing
    /// popularity means "never measured", not "measured as low" — sweeping
    /// those away by default would silently delete everything that has not been
    /// researched yet.
    public func lowPopularityKeywords(appId: String?, below threshold: Double,
                                      includeUnknown: Bool) throws -> [TrackedKeyword] {
        var sql = """
            SELECT k.id, k.app_id, k.term, k.country, k.added_at,
                   m.popularity, m.difficulty, m.competitors,
                   (SELECT rank FROM rank_snapshots r WHERE r.keyword_id = k.id
                     ORDER BY r.captured_at DESC LIMIT 1),
                   (SELECT rank FROM rank_snapshots r WHERE r.keyword_id = k.id
                     ORDER BY r.captured_at DESC LIMIT 1 OFFSET 1),
                   m.source
            FROM keywords k
            LEFT JOIN keyword_metrics m ON m.keyword_id = k.id
            WHERE k.is_tracked = 1
            """
        var parameters: [SQLValue] = []
        if let appId {
            sql += " AND k.app_id = ?"
            parameters.append(.text(appId))
        }
        sql += includeUnknown
            ? " AND (m.popularity IS NULL OR m.popularity < ?)"
            : " AND m.popularity IS NOT NULL AND m.popularity < ?"
        parameters.append(.double(threshold))
        sql += " ORDER BY m.popularity, k.term;"

        return try database.query(sql, parameters) { row in
            var keyword = TrackedKeyword(id: row.int(0) ?? 0,
                                         appId: row.string(1) ?? "",
                                         term: row.string(2) ?? "",
                                         country: row.string(3) ?? "us",
                                         addedAt: row.date(4) ?? Date())
            keyword.popularity = row.double(5)
            keyword.difficulty = row.double(6)
            keyword.competitors = row.int(7).map(Int.init)
            keyword.currentRank = row.int(8).map(Int.init)
            keyword.previousRank = row.int(9).map(Int.init)
            keyword.popularitySource = row.string(10) ?? "unknown"
            return keyword
        }
    }

    /// Deletes the given keywords and their rank history.
    @discardableResult
    public func removeKeywords(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        try database.transaction {
            for id in ids {
                try database.run("DELETE FROM keywords WHERE id = ?;", [.int(id)])
            }
        }
        return ids.count
    }

    /// Every (app, country) pair that actually has tracked keywords.
    ///
    /// Drives the scheduled sweep: refreshing a country an app has no keywords
    /// in would burn rate limit for nothing.
    public func trackedAppCountryPairs() throws -> [(appId: String, country: String, count: Int)] {
        try database.query("""
            SELECT k.app_id, k.country, COUNT(*)
            FROM keywords k
            JOIN apps a ON a.id = k.app_id
            WHERE k.is_tracked = 1 AND a.is_tracked = 1
            GROUP BY k.app_id, k.country
            ORDER BY k.app_id, k.country;
            """) { row in
            (row.string(0) ?? "", row.string(1) ?? "us", Int(row.int(2) ?? 0))
        }
    }

    /// Keywords with their cached metrics and latest two ranks joined in.
    public func keywords(appId: String, country: String? = nil) throws -> [TrackedKeyword] {
        var sql = """
            SELECT k.id, k.app_id, k.term, k.country, k.added_at,
                   m.popularity, m.difficulty, m.competitors,
                   (SELECT rank FROM rank_snapshots r WHERE r.keyword_id = k.id
                     ORDER BY r.captured_at DESC LIMIT 1),
                   (SELECT rank FROM rank_snapshots r WHERE r.keyword_id = k.id
                     ORDER BY r.captured_at DESC LIMIT 1 OFFSET 1),
                   m.source
            FROM keywords k
            LEFT JOIN keyword_metrics m ON m.keyword_id = k.id
            WHERE k.app_id = ? AND k.is_tracked = 1
            """
        var parameters: [SQLValue] = [.text(appId)]
        if let country {
            sql += " AND k.country = ?"
            parameters.append(.text(country))
        }
        sql += " ORDER BY k.term;"

        return try database.query(sql, parameters) { row in
            var keyword = TrackedKeyword(id: row.int(0) ?? 0,
                                         appId: row.string(1) ?? "",
                                         term: row.string(2) ?? "",
                                         country: row.string(3) ?? "us",
                                         addedAt: row.date(4) ?? Date())
            keyword.popularity = row.double(5)
            keyword.difficulty = row.double(6)
            keyword.competitors = row.int(7).map(Int.init)
            keyword.currentRank = row.int(8).map(Int.init)
            keyword.previousRank = row.int(9).map(Int.init)
            keyword.popularitySource = row.string(10) ?? "unknown"
            return keyword
        }
    }

    public func updateMetrics(keywordId: Int64, popularity: Double?, difficulty: Double?,
                              competitors: Int?, source: String,
                              at date: Date = Date()) throws {
        try database.run("""
            INSERT INTO keyword_metrics (keyword_id, popularity, difficulty, competitors, source, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(keyword_id) DO UPDATE SET
                popularity = excluded.popularity,
                difficulty = excluded.difficulty,
                competitors = excluded.competitors,
                source = excluded.source,
                updated_at = excluded.updated_at;
            """, [.int(keywordId), .double(popularity), .double(difficulty),
                  .int(competitors), .text(source), .date(date)])
    }

    /// Updates only the competition signals, leaving popularity and its source
    /// untouched.
    ///
    /// A plain `updateMetrics` call with a nil popularity would overwrite a real
    /// Apple Search Ads figure with nothing, so rank refreshes use this instead.
    public func updateCompetition(keywordId: Int64, difficulty: Double?,
                                  competitors: Int?, at date: Date = Date()) throws {
        try database.run("""
            INSERT INTO keyword_metrics (keyword_id, difficulty, competitors, source, updated_at)
            VALUES (?, ?, ?, 'derived', ?)
            ON CONFLICT(keyword_id) DO UPDATE SET
                difficulty = excluded.difficulty,
                competitors = excluded.competitors,
                updated_at = excluded.updated_at;
            """, [.int(keywordId), .double(difficulty), .int(competitors), .date(date)])
    }

    // MARK: Ranks

    /// Stores a rank reading. Snapped to midnight UTC so one run per day
    /// overwrites rather than accumulating duplicate points.
    public func recordRank(keywordId: Int64, rank: Int?, at date: Date = Date()) throws {
        let day = Calendar.utc.startOfDay(for: date)
        try database.run("""
            INSERT INTO rank_snapshots (keyword_id, rank, captured_at)
            VALUES (?, ?, ?)
            ON CONFLICT(keyword_id, captured_at) DO UPDATE SET rank = excluded.rank;
            """, [.int(keywordId), .int(rank), .date(day)])
    }

    /// Rewrites implausible stored ranks to NULL.
    ///
    /// Repairs data imported before sentinel filtering existed, where an
    /// export's "not ranked" marker (1000, 999, …) was taken as a real position.
    @discardableResult
    public func clearSentinelRanks(above threshold: Int = 250) throws -> Int {
        let affected = try database.query(
            "SELECT COUNT(*) FROM rank_snapshots WHERE rank >= ?;",
            [.int(Int64(threshold))]) { Int($0.int(0) ?? 0) }.first ?? 0
        try database.run("UPDATE rank_snapshots SET rank = NULL WHERE rank >= ?;",
                         [.int(Int64(threshold))])
        return affected
    }

    /// Keyword ids that already have a rank reading on or after `since`.
    ///
    /// Makes a sweep resumable. A two-hour run interrupted by sleep, a dropped
    /// connection or a shutdown otherwise restarts from the beginning and
    /// re-does work that is already saved.
    public func keywordIdsWithRank(appId: String, country: String,
                                   since: Date) throws -> Set<Int64> {
        let ids = try database.query("""
            SELECT DISTINCT r.keyword_id
            FROM rank_snapshots r
            JOIN keywords k ON k.id = r.keyword_id
            WHERE k.app_id = ? AND k.country = ? AND r.captured_at >= ?;
            """, [.text(appId), .text(country), .date(since)]) { $0.int(0) }
        return Set(ids.compactMap { $0 })
    }

    public func rankHistory(keywordId: Int64, days: Int = 90) throws -> [RankPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try database.query("""
            SELECT keyword_id, rank, captured_at FROM rank_snapshots
            WHERE keyword_id = ? AND captured_at >= ?
            ORDER BY captured_at;
            """, [.int(keywordId), .date(cutoff)]) { row in
            RankPoint(keywordId: row.int(0) ?? 0,
                      rank: row.int(1).map(Int.init),
                      capturedAt: row.date(2) ?? Date())
        }
    }

    /// Rank history for every tracked keyword of an app, for the trend chart.
    public func rankHistory(appId: String, country: String,
                            days: Int = 90) throws -> [Int64: [RankPoint]] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let points = try database.query("""
            SELECT r.keyword_id, r.rank, r.captured_at
            FROM rank_snapshots r
            JOIN keywords k ON k.id = r.keyword_id
            WHERE k.app_id = ? AND k.country = ? AND r.captured_at >= ?
            ORDER BY r.captured_at;
            """, [.text(appId), .text(country), .date(cutoff)]) { row in
            RankPoint(keywordId: row.int(0) ?? 0,
                      rank: row.int(1).map(Int.init),
                      capturedAt: row.date(2) ?? Date())
        }
        return Dictionary(grouping: points, by: \.keywordId)
    }

    // MARK: Spend

    public func recordSpend(_ rows: [SpendRow]) throws {
        try database.transaction {
            for row in rows {
                try database.run("""
                    INSERT INTO ad_spend
                        (app_id, campaign_id, campaign_name, ad_group_id, keyword_id,
                         keyword_text, country, day, spend, impressions, taps, installs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(app_id, campaign_id, ad_group_id, keyword_id, day)
                    DO UPDATE SET
                        spend = excluded.spend,
                        impressions = excluded.impressions,
                        taps = excluded.taps,
                        installs = excluded.installs,
                        campaign_name = excluded.campaign_name,
                        keyword_text = excluded.keyword_text;
                    """, [.text(row.appId), .text(row.campaignId), .text(row.campaignName),
                          .text(row.adGroupId ?? ""), .text(row.keywordId ?? ""),
                          .text(row.keywordText), .text(row.country),
                          .date(Calendar.utc.startOfDay(for: row.day)),
                          .double(row.spend), .int(row.impressions),
                          .int(row.taps), .int(row.installs)])
            }
        }
    }

    public func spend(appId: String, since: Date) throws -> [SpendRow] {
        try database.query("""
            SELECT app_id, campaign_id, campaign_name, ad_group_id, keyword_id,
                   keyword_text, country, day, spend, impressions, taps, installs
            FROM ad_spend WHERE app_id = ? AND day >= ? ORDER BY day DESC;
            """, [.text(appId), .date(Calendar.utc.startOfDay(for: since))]) { row in
            SpendRow(appId: row.string(0) ?? "",
                     campaignId: row.string(1) ?? "",
                     campaignName: row.string(2),
                     adGroupId: row.string(3),
                     keywordId: row.string(4),
                     keywordText: row.string(5),
                     country: row.string(6),
                     day: row.date(7) ?? Date(),
                     spend: row.double(8) ?? 0,
                     impressions: Int(row.int(9) ?? 0),
                     taps: Int(row.int(10) ?? 0),
                     installs: Int(row.int(11) ?? 0))
        }
    }

    // MARK: Revenue

    public func recordRevenue(_ events: [RevenueEvent]) throws {
        try database.transaction {
            for event in events {
                try database.run("""
                    INSERT INTO revenue_events
                        (event_id, app_id, app_user_id, type, product_id, store, country,
                         revenue_usd, is_trial, occurred_at,
                         asa_campaign_id, asa_ad_group_id, asa_keyword_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(event_id) DO UPDATE SET
                        revenue_usd = excluded.revenue_usd,
                        asa_campaign_id = COALESCE(excluded.asa_campaign_id, asa_campaign_id),
                        asa_ad_group_id = COALESCE(excluded.asa_ad_group_id, asa_ad_group_id),
                        asa_keyword_id = COALESCE(excluded.asa_keyword_id, asa_keyword_id);
                    """, [.text(event.eventId), .text(event.appId), .text(event.appUserId),
                          .text(event.type), .text(event.productId), .text(event.store),
                          .text(event.country), .double(event.revenueUSD),
                          .int(Int64(event.isTrial ? 1 : 0)), .date(event.occurredAt),
                          .text(event.asaCampaignId), .text(event.asaAdGroupId),
                          .text(event.asaKeywordId)])
            }
        }
    }

    public func revenue(appId: String, since: Date) throws -> [RevenueEvent] {
        try database.query("""
            SELECT event_id, app_id, app_user_id, type, product_id, store, country,
                   revenue_usd, is_trial, occurred_at,
                   asa_campaign_id, asa_ad_group_id, asa_keyword_id
            FROM revenue_events WHERE app_id = ? AND occurred_at >= ?
            ORDER BY occurred_at DESC;
            """, [.text(appId), .date(since)]) { row in
            RevenueEvent(eventId: row.string(0) ?? "",
                         appId: row.string(1),
                         appUserId: row.string(2),
                         type: row.string(3) ?? "",
                         productId: row.string(4),
                         store: row.string(5),
                         country: row.string(6),
                         revenueUSD: row.double(7) ?? 0,
                         isTrial: (row.int(8) ?? 0) == 1,
                         occurredAt: row.date(9) ?? Date(),
                         asaCampaignId: row.string(10),
                         asaAdGroupId: row.string(11),
                         asaKeywordId: row.string(12))
        }
    }

    /// Share of revenue events carrying Search Ads attribution.
    ///
    /// Drives the diagnostic that tells you whether keyword-level ROAS is real
    /// or estimated, rather than silently showing an estimate as if it were fact.
    public func attributionCoverage(appId: String, since: Date) throws -> (total: Int, attributed: Int) {
        let result = try database.query("""
            SELECT COUNT(*), SUM(CASE WHEN asa_keyword_id IS NOT NULL
                                       AND asa_keyword_id <> '' THEN 1 ELSE 0 END)
            FROM revenue_events WHERE app_id = ? AND occurred_at >= ?;
            """, [.text(appId), .date(since)]) { row in
            (Int(row.int(0) ?? 0), Int(row.int(1) ?? 0))
        }.first
        return result ?? (0, 0)
    }

    // MARK: Competitors

    @discardableResult
    public func addCompetitor(appId: String, competitorId: String, name: String,
                              country: String, at date: Date = Date()) throws -> Int64 {
        try database.run("""
            INSERT INTO competitors (app_id, competitor_id, name, country, added_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(app_id, competitor_id, country) DO UPDATE SET name = excluded.name;
            """, [.text(appId), .text(competitorId), .text(name), .text(country), .date(date)])
    }

    public func competitors(appId: String) throws -> [(id: String, name: String, country: String)] {
        try database.query("""
            SELECT competitor_id, name, country FROM competitors
            WHERE app_id = ? ORDER BY name;
            """, [.text(appId)]) { row in
            (row.string(0) ?? "", row.string(1) ?? "", row.string(2) ?? "us")
        }
    }

    public func recordCompetitorSnapshot(competitorId: String, country: String,
                                         title: String?, subtitle: String?,
                                         description: String?, version: String?,
                                         screenshotHash: String?,
                                         at date: Date = Date()) throws {
        try database.run("""
            INSERT INTO competitor_snapshots
                (competitor_id, country, title, subtitle, description, version,
                 screenshot_hash, captured_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(competitorId), .text(country), .text(title), .text(subtitle),
                  .text(description), .text(version), .text(screenshotHash), .date(date)])
    }

    /// The two most recent snapshots, for change detection.
    public func latestCompetitorSnapshots(competitorId: String, country: String, limit: Int = 2)
        throws -> [(title: String?, subtitle: String?, description: String?,
                    version: String?, screenshotHash: String?, at: Date)] {
        try database.query("""
            SELECT title, subtitle, description, version, screenshot_hash, captured_at
            FROM competitor_snapshots WHERE competitor_id = ? AND country = ?
            ORDER BY captured_at DESC LIMIT ?;
            """, [.text(competitorId), .text(country), .int(Int64(limit))]) { row in
            (row.string(0), row.string(1), row.string(2), row.string(3),
             row.string(4), row.date(5) ?? Date())
        }
    }

    // MARK: Alerts

    @discardableResult
    public func recordAlert(appId: String?, kind: String, title: String, body: String,
                            severity: ASOAlert.Severity, at date: Date = Date()) throws -> Int64 {
        try database.run("""
            INSERT INTO alerts (app_id, kind, title, body, severity, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """, [.text(appId), .text(kind), .text(title), .text(body),
                  .text(severity.rawValue), .date(date)])
    }

    public func alerts(limit: Int = 100, unacknowledgedOnly: Bool = false) throws -> [ASOAlert] {
        let filter = unacknowledgedOnly ? "WHERE acknowledged = 0" : ""
        return try database.query("""
            SELECT id, app_id, kind, title, body, severity, created_at, acknowledged
            FROM alerts \(filter) ORDER BY created_at DESC LIMIT ?;
            """, [.int(Int64(limit))]) { row in
            ASOAlert(id: row.int(0) ?? 0,
                  appId: row.string(1),
                  kind: row.string(2) ?? "",
                  title: row.string(3) ?? "",
                  body: row.string(4) ?? "",
                  severity: ASOAlert.Severity(rawValue: row.string(5) ?? "info") ?? .info,
                  createdAt: row.date(6) ?? Date(),
                  acknowledged: (row.int(7) ?? 0) == 1)
        }
    }

    public func acknowledgeAlert(id: Int64) throws {
        try database.run("UPDATE alerts SET acknowledged = 1 WHERE id = ?;", [.int(id)])
    }
}

extension Calendar {
    /// Days are bucketed in UTC so a rank captured at 23:00 local time does not
    /// land on a different day than one captured at 01:00.
    public static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
