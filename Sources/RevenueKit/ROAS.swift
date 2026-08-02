import Foundation
import ASOCore
import ASOStore

/// How a revenue figure was arrived at.
///
/// The distinction matters: a keyword-level ROAS built by allocating campaign
/// revenue across keywords is a modelling assumption, and presenting it beside
/// measured numbers without saying so would invite bad bid decisions.
public enum AttributionQuality: String, Sendable {
    /// Every revenue event carried an ASA keyword id. Directly measured.
    case measured
    /// Revenue was attributed at campaign or ad-group level and allocated down
    /// to keywords in proportion to spend.
    case estimated
    /// Some events carry keyword ids and some do not.
    case mixed

    public var label: String {
        switch self {
        case .measured: return "Measured"
        case .estimated: return "Estimated"
        case .mixed: return "Partly measured"
        }
    }

    public var explanation: String {
        switch self {
        case .measured:
            return "Every purchase in this period carried an Apple Search Ads keyword id."
        case .estimated:
            return "No purchases carried a keyword id, so campaign revenue was allocated "
                 + "across keywords in proportion to spend. Treat differences between "
                 + "keywords in the same campaign as unproven."
        case .mixed:
            return "Some purchases carried a keyword id and some did not. Measured revenue "
                 + "is used where available; the remainder is allocated by spend share."
        }
    }
}

/// Spend joined to revenue for one keyword over a period.
public struct KeywordROAS: Identifiable, Hashable, Sendable {
    public var id: String { "\(campaignId)-\(keywordId ?? keyword)" }
    public var keyword: String
    public var keywordId: String?
    public var campaignId: String
    public var campaignName: String?
    public var country: String?

    public var spend: Double
    public var impressions: Int
    public var taps: Int
    public var installs: Int

    public var revenue: Double
    public var trials: Int
    public var purchases: Int
    public var quality: AttributionQuality

    /// Return on ad spend. Nil when nothing was spent, since x/0 is not "infinite ROAS".
    public var roas: Double? { spend > 0 ? revenue / spend : nil }
    public var cpa: Double? { installs > 0 ? spend / Double(installs) : nil }
    public var arpu: Double? { installs > 0 ? revenue / Double(installs) : nil }
    public var profit: Double { revenue - spend }

    /// Conversion from tap to install.
    public var conversionRate: Double? {
        taps > 0 ? Double(installs) / Double(taps) : nil
    }

    // Sort keys: `TableColumn(value:)` requires a non-optional Comparable, and
    // an undefined ratio sorts below any real one rather than being unsortable.
    public var sortROAS: Double { roas ?? -1 }
    public var sortCPA: Double { cpa ?? Double.greatestFiniteMagnitude }
    public var sortQuality: String { quality.rawValue }
}

/// Joins Apple Search Ads spend with RevenueCat revenue.
public enum ROASCalculator {

    /// Computes per-keyword ROAS for one app over a period.
    ///
    /// Revenue is matched to keywords directly when events carry an ASA keyword
    /// id. Unattributed revenue within a campaign is allocated across that
    /// campaign's keywords by spend share, and the result is flagged so the UI
    /// can say which is which.
    public static func compute(spend: [SpendRow],
                               revenue: [RevenueEvent]) -> [KeywordROAS] {
        // Aggregate spend per keyword.
        struct Accumulator {
            var keyword: String = ""
            var keywordId: String?
            var campaignId: String = ""
            var campaignName: String?
            var country: String?
            var spend: Double = 0
            var impressions: Int = 0
            var taps: Int = 0
            var installs: Int = 0
        }

        var byKeyword: [String: Accumulator] = [:]
        for row in spend {
            // Rows with no keyword id are campaign-level totals; they still carry
            // spend that must be allocated, so keep them under a synthetic key.
            let key = "\(row.campaignId)|\(row.keywordId ?? row.keywordText ?? "_campaign")"
            var accumulator = byKeyword[key] ?? Accumulator()
            accumulator.keyword = row.keywordText ?? accumulator.keyword
            accumulator.keywordId = row.keywordId?.isEmpty == false ? row.keywordId : accumulator.keywordId
            accumulator.campaignId = row.campaignId
            accumulator.campaignName = row.campaignName ?? accumulator.campaignName
            accumulator.country = row.country ?? accumulator.country
            accumulator.spend += row.spend
            accumulator.impressions += row.impressions
            accumulator.taps += row.taps
            accumulator.installs += row.installs
            byKeyword[key] = accumulator
        }

        // Split revenue into keyword-attributed and campaign-only buckets.
        var revenueByKeywordId: [String: (revenue: Double, trials: Int, purchases: Int)] = [:]
        var unattributedByCampaign: [String: Double] = [:]
        var unattributedGlobal: Double = 0

        for event in revenue {
            let amount = event.revenueUSD
            if let keywordId = event.asaKeywordId, !keywordId.isEmpty {
                var bucket = revenueByKeywordId[keywordId] ?? (0, 0, 0)
                bucket.revenue += amount
                if event.isTrial { bucket.trials += 1 } else { bucket.purchases += 1 }
                revenueByKeywordId[keywordId] = bucket
            } else if let campaignId = event.asaCampaignId, !campaignId.isEmpty {
                unattributedByCampaign[campaignId, default: 0] += amount
            } else {
                // Organic or untracked; not allocated to any paid keyword.
                unattributedGlobal += amount
            }
        }

        // Spend totals per campaign, for proportional allocation.
        var spendByCampaign: [String: Double] = [:]
        for accumulator in byKeyword.values {
            spendByCampaign[accumulator.campaignId, default: 0] += accumulator.spend
        }

        return byKeyword.values.map { accumulator in
            let measured = accumulator.keywordId.flatMap { revenueByKeywordId[$0] }
            let campaignPool = unattributedByCampaign[accumulator.campaignId] ?? 0
            let campaignSpend = spendByCampaign[accumulator.campaignId] ?? 0

            // Allocate the campaign's unattributed revenue by spend share.
            let share = campaignSpend > 0 ? accumulator.spend / campaignSpend : 0
            let allocated = campaignPool * share

            let quality: AttributionQuality
            if measured != nil && allocated > 0 { quality = .mixed }
            else if measured != nil { quality = .measured }
            else { quality = .estimated }

            return KeywordROAS(
                keyword: accumulator.keyword.isEmpty ? "(campaign total)" : accumulator.keyword,
                keywordId: accumulator.keywordId,
                campaignId: accumulator.campaignId,
                campaignName: accumulator.campaignName,
                country: accumulator.country,
                spend: accumulator.spend,
                impressions: accumulator.impressions,
                taps: accumulator.taps,
                installs: accumulator.installs,
                revenue: (measured?.revenue ?? 0) + allocated,
                trials: measured?.trials ?? 0,
                purchases: measured?.purchases ?? 0,
                quality: quality)
        }
        .sorted { $0.spend > $1.spend }
    }

    /// Overall quality across a result set, for the header badge.
    public static func overallQuality(_ rows: [KeywordROAS]) -> AttributionQuality {
        let qualities = Set(rows.map(\.quality))
        if qualities == [.measured] { return .measured }
        if qualities == [.estimated] { return .estimated }
        return .mixed
    }
}

/// Blended performance for one channel, used by the Phase 2 cross-channel view.
public struct ChannelPerformance: Identifiable, Hashable, Sendable {
    public var id: String { channel }
    public var channel: String
    public var spend: Double
    public var installs: Int
    public var revenue: Double

    public var roas: Double? { spend > 0 ? revenue / spend : nil }
    public var cac: Double? { installs > 0 ? spend / Double(installs) : nil }

    public init(channel: String, spend: Double, installs: Int, revenue: Double) {
        self.channel = channel
        self.spend = spend
        self.installs = installs
        self.revenue = revenue
    }
}
