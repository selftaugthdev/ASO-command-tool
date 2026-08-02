import Foundation
import ASOCore
import ASOStore

/// Pulls RevenueCat events from the Firestore relay into the local store.
///
/// RevenueCat's REST API is per-customer lookup with no bulk historical export,
/// so a Cloud Function receives their webhooks and appends each event to a
/// Firestore collection. See `Firebase/functions/index.js`.
public final class RevenueCatSync: @unchecked Sendable {
    private let firestore: FirestoreClient
    private let store: ASOStore
    private let collection: String

    public init(firestore: FirestoreClient, store: ASOStore,
                collection: String = "revenuecat_events") {
        self.firestore = firestore
        self.store = store
        self.collection = collection
    }

    /// Fetches events newer than the most recent one already stored.
    @discardableResult
    public func sync(since: Date? = nil) async throws -> Int {
        let cutoff = since ?? Date().addingTimeInterval(-90 * 86_400)
        let documents = try await firestore.query(collection: collection,
                                                  whereFieldGreaterThan: "occurredAt",
                                                  timestamp: cutoff,
                                                  limit: 5000)

        let events = documents.compactMap(Self.event(from:))
        guard !events.isEmpty else { return 0 }
        try store.recordRevenue(events)
        return events.count
    }

    /// Maps one Firestore document to a revenue event.
    ///
    /// Attribution fields are read from several possible names because the
    /// keyword id can arrive either as a RevenueCat subscriber attribute or in
    /// the raw AdServices payload the app forwarded, depending on how the
    /// integration was wired.
    static func event(from fields: [String: FirestoreValue]) -> RevenueEvent? {
        guard let eventId = fields["eventId"]?.stringValue
                ?? fields["id"]?.stringValue else { return nil }

        let occurredAt = fields["occurredAt"]?.dateValue
            ?? fields["eventTimestampMs"]?.doubleValue.map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            ?? Date()

        let type = fields["type"]?.stringValue ?? "UNKNOWN"

        // RevenueCat reports proceeds in several fields depending on event type;
        // prefer the USD figure that is net of store commission when present.
        let revenueFieldNames = ["revenueUSD", "priceUSD", "price", "priceInPurchasedCurrency"]
        var revenueUSD: Double = 0
        for name in revenueFieldNames {
            if let value = fields[name]?.doubleValue {
                revenueUSD = value
                break
            }
        }

        let isTrial = fields["isTrialConversion"]?.boolValue
            ?? (fields["periodType"]?.stringValue == "TRIAL")

        func attribute(_ names: [String]) -> String? {
            for name in names {
                if let value = fields[name]?.stringValue, !value.isEmpty { return value }
            }
            return nil
        }

        return RevenueEvent(
            eventId: eventId,
            appId: attribute(["appId", "app_id", "ascAppId"]),
            appUserId: attribute(["appUserId", "app_user_id"]),
            type: type,
            productId: attribute(["productId", "product_id"]),
            store: attribute(["store"]),
            country: attribute(["countryCode", "country"]),
            revenueUSD: revenueUSD,
            isTrial: isTrial,
            occurredAt: occurredAt,
            asaCampaignId: attribute([
                "asaCampaignId", "campaignId", "attribution_campaign_id",
                "$campaignId", "adServicesCampaignId",
            ]),
            asaAdGroupId: attribute([
                "asaAdGroupId", "adGroupId", "attribution_ad_group_id", "$adGroupId",
            ]),
            asaKeywordId: attribute([
                "asaKeywordId", "keywordId", "attribution_keyword_id",
                "$keywordId", "adServicesKeywordId",
            ]))
    }
}

/// Reports whether keyword-level ROAS can be trusted for an app.
public struct AttributionDiagnostic: Sendable {
    public var appId: String
    public var totalEvents: Int
    public var attributedEvents: Int
    public var periodDays: Int

    public var coverage: Double {
        totalEvents > 0 ? Double(attributedEvents) / Double(totalEvents) : 0
    }

    public var status: String {
        if totalEvents == 0 { return "No revenue events synced yet" }
        if attributedEvents == 0 { return "No Search Ads attribution present" }
        if coverage > 0.8 { return "Attribution healthy" }
        return "Partial attribution"
    }

    /// Concrete next step, rather than just a percentage.
    public var advice: String {
        if totalEvents == 0 {
            return "Deploy the Cloud Function in Firebase/functions and point a RevenueCat "
                 + "webhook at it, then run Sync."
        }
        if attributedEvents == 0 {
            return "Your apps are not forwarding Apple Search Ads attribution to RevenueCat, "
                 + "so keyword ROAS is estimated from spend share. Add the AdServices snippet "
                 + "in Docs/AdServicesAttribution.md to each app to make it measured."
        }
        if coverage <= 0.8 {
            return "Only \(Int(coverage * 100))% of purchases carry a keyword id. This is normal "
                 + "if some installs are organic; investigate if it keeps falling."
        }
        return "Keyword-level ROAS is measured directly from attributed purchases."
    }

    public init(appId: String, totalEvents: Int, attributedEvents: Int, periodDays: Int) {
        self.appId = appId
        self.totalEvents = totalEvents
        self.attributedEvents = attributedEvents
        self.periodDays = periodDays
    }

    public static func run(store: ASOStore, appId: String, days: Int = 30) throws -> AttributionDiagnostic {
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let counts = try store.attributionCoverage(appId: appId, since: since)
        return AttributionDiagnostic(appId: appId,
                                     totalEvents: counts.total,
                                     attributedEvents: counts.attributed,
                                     periodDays: days)
    }
}
