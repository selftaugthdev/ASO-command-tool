import Foundation
import ASOCore

// MARK: - Domain types

public struct ASACampaign: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var adamId: String          // the App Store app id this promotes
    public var status: String
    public var dailyBudget: Double?
    public var countries: [String]

    public init(id: String, name: String, adamId: String, status: String,
                dailyBudget: Double? = nil, countries: [String] = []) {
        self.id = id
        self.name = name
        self.adamId = adamId
        self.status = status
        self.dailyBudget = dailyBudget
        self.countries = countries
    }
}

public struct ASAAdGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var campaignId: String
    public var name: String
    public var status: String
    public var defaultBidAmount: Double?

    public init(id: String, campaignId: String, name: String, status: String,
                defaultBidAmount: Double? = nil) {
        self.id = id
        self.campaignId = campaignId
        self.name = name
        self.status = status
        self.defaultBidAmount = defaultBidAmount
    }
}

public struct ASAKeyword: Identifiable, Hashable, Sendable {
    public var id: String
    public var adGroupId: String
    public var text: String
    public var matchType: String       // EXACT or BROAD
    public var status: String
    public var bidAmount: Double?

    public init(id: String, adGroupId: String, text: String, matchType: String,
                status: String, bidAmount: Double? = nil) {
        self.id = id
        self.adGroupId = adGroupId
        self.text = text
        self.matchType = matchType
        self.status = status
        self.bidAmount = bidAmount
    }
}

/// Performance for one keyword over one day.
public struct ASAKeywordReport: Hashable, Sendable {
    public var date: Date
    public var campaignId: String
    public var adGroupId: String?
    public var keywordId: String?
    public var keyword: String?
    public var countryCode: String?
    public var impressions: Int
    public var taps: Int
    public var installs: Int
    public var spend: Double

    public var cpa: Double? { installs > 0 ? spend / Double(installs) : nil }
    public var tapThroughRate: Double? {
        impressions > 0 ? Double(taps) / Double(impressions) : nil
    }
}

/// Apple's search-popularity signal for a term, 0–100 (their "SEARCH_VOLUME" index).
public struct ASAKeywordSuggestion: Hashable, Sendable {
    public var text: String
    public var popularity: Double?
    public var suggestedBid: Double?

    public init(text: String, popularity: Double? = nil, suggestedBid: Double? = nil) {
        self.text = text
        self.popularity = popularity
        self.suggestedBid = suggestedBid
    }
}

// MARK: - Wire types

private struct ASAEnvelope<T: Decodable>: Decodable {
    var data: T?
    var error: ASAErrorBody?
    var pagination: Pagination?

    struct Pagination: Decodable {
        var totalResults: Int?
        var startIndex: Int?
        var itemsPerPage: Int?
    }
}

private struct ASAErrorBody: Decodable {
    struct Item: Decodable {
        var messageCode: String?
        var message: String?
        var field: String?
    }
    var errors: [Item]?
}

private struct ASAReportEnvelope: Decodable {
    struct Reporting: Decodable {
        var row: [ReportRow]?
    }
    var reportingDataResponse: Reporting?
}

private struct ReportRow: Decodable {
    var metadata: Metadata?
    var granularity: [Granularity]?
    var total: Metrics?

    struct Metadata: Decodable {
        var campaignId: Int?
        var adGroupId: Int?
        var keywordId: Int?
        var keyword: String?
        var keywordDisplayStatus: String?
        var countryOrRegion: String?
        var campaignName: String?
    }
    struct Granularity: Decodable {
        var date: String?
        var impressions: Int?
        var taps: Int?
        var installs: Int?
        var totalInstalls: Int?
        var localSpend: Money?
    }
    struct Metrics: Decodable {
        var impressions: Int?
        var taps: Int?
        var installs: Int?
        var localSpend: Money?
    }
    struct Money: Decodable {
        var amount: String?
        var currency: String?
        var value: Double { Double(amount ?? "0") ?? 0 }
    }
}

// MARK: - Client

/// Apple Search Ads API v5 client.
public final class ASAClient: @unchecked Sendable {
    private let base = URL(string: "https://api.searchads.apple.com/api/v5")!
    private let tokens: ASATokenProvider
    private let http: HTTPClient

    public init(credentials: ASACredentials, http: HTTPClient? = nil) throws {
        self.tokens = try ASATokenProvider(credentials: credentials)
        self.http = http ?? HTTPClient(config: HTTPClientConfig(requestsPerHour: 2000))
    }

    private func request(_ path: String, method: String = "GET",
                         query: [String: String] = [:],
                         body: Data? = nil) async throws -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.token())", forHTTPHeaderField: "Authorization")
        request.setValue(await tokens.contextHeader, forHTTPHeaderField: "X-AP-Context")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: Reads

    public func campaigns() async throws -> [ASACampaign] {
        struct Wire: Decodable {
            var id: Int
            var name: String?
            var adamId: Int?
            var status: String?
            var displayStatus: String?
            var dailyBudgetAmount: Amount?
            var countriesOrRegions: [String]?
            struct Amount: Decodable { var amount: String?; var currency: String? }
        }
        let request = try await request("campaigns", query: ["limit": "1000"])
        let response = try await http.send(request, as: ASAEnvelope<[Wire]>.self)
        return (response.data ?? []).map {
            ASACampaign(id: String($0.id),
                        name: $0.name ?? "Untitled",
                        adamId: $0.adamId.map(String.init) ?? "",
                        status: $0.displayStatus ?? $0.status ?? "UNKNOWN",
                        dailyBudget: $0.dailyBudgetAmount?.amount.flatMap(Double.init),
                        countries: $0.countriesOrRegions ?? [])
        }
    }

    public func adGroups(campaignId: String) async throws -> [ASAAdGroup] {
        struct Wire: Decodable {
            var id: Int
            var campaignId: Int?
            var name: String?
            var status: String?
            var displayStatus: String?
            var defaultBidAmount: Amount?
            struct Amount: Decodable { var amount: String? }
        }
        let request = try await request("campaigns/\(campaignId)/adgroups",
                                        query: ["limit": "1000"])
        let response = try await http.send(request, as: ASAEnvelope<[Wire]>.self)
        return (response.data ?? []).map {
            ASAAdGroup(id: String($0.id),
                       campaignId: $0.campaignId.map(String.init) ?? campaignId,
                       name: $0.name ?? "Untitled",
                       status: $0.displayStatus ?? $0.status ?? "UNKNOWN",
                       defaultBidAmount: $0.defaultBidAmount?.amount.flatMap(Double.init))
        }
    }

    public func keywords(campaignId: String, adGroupId: String) async throws -> [ASAKeyword] {
        struct Wire: Decodable {
            var id: Int
            var adGroupId: Int?
            var text: String?
            var matchType: String?
            var status: String?
            var bidAmount: Amount?
            struct Amount: Decodable { var amount: String? }
        }
        let request = try await request(
            "campaigns/\(campaignId)/adgroups/\(adGroupId)/targetingkeywords",
            query: ["limit": "1000"])
        let response = try await http.send(request, as: ASAEnvelope<[Wire]>.self)
        return (response.data ?? []).map {
            ASAKeyword(id: String($0.id),
                       adGroupId: $0.adGroupId.map(String.init) ?? adGroupId,
                       text: $0.text ?? "",
                       matchType: $0.matchType ?? "EXACT",
                       status: $0.status ?? "ACTIVE",
                       bidAmount: $0.bidAmount?.amount.flatMap(Double.init))
        }
    }

    /// Daily keyword-level performance for a campaign.
    ///
    /// This is the spend side of the ROAS join. Apple returns installs as
    /// tap-through + view-through; we use the reported total.
    public func keywordReport(campaignId: String,
                              from: Date, to: Date) async throws -> [ASAKeywordReport] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let body: [String: Any] = [
            "startTime": formatter.string(from: from),
            "endTime": formatter.string(from: to),
            "granularity": "DAILY",
            "selector": [
                "orderBy": [["field": "localSpend", "sortOrder": "DESCENDING"]],
                "pagination": ["offset": 0, "limit": 1000],
            ],
            "returnRowTotals": true,
            "returnRecordsWithNoMetrics": false,
        ]

        let request = try await request(
            "reports/campaigns/\(campaignId)/keywords",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body))
        let response = try await http.send(request, as: ASAReportEnvelope.self)

        var reports: [ASAKeywordReport] = []
        for row in response.reportingDataResponse?.row ?? [] {
            let metadata = row.metadata
            for point in row.granularity ?? [] {
                guard let raw = point.date, let date = formatter.date(from: raw) else { continue }
                reports.append(ASAKeywordReport(
                    date: date,
                    campaignId: metadata?.campaignId.map(String.init) ?? campaignId,
                    adGroupId: metadata?.adGroupId.map(String.init),
                    keywordId: metadata?.keywordId.map(String.init),
                    keyword: metadata?.keyword,
                    countryCode: metadata?.countryOrRegion,
                    impressions: point.impressions ?? 0,
                    taps: point.taps ?? 0,
                    installs: point.totalInstalls ?? point.installs ?? 0,
                    spend: point.localSpend?.value ?? 0))
            }
        }
        return reports
    }

    /// Apple's keyword suggestions with their search-popularity index.
    ///
    /// This is the only official source of Apple search volume. Coverage depends
    /// on the account having campaign history for the app, so terms far outside
    /// your existing targeting may come back without a popularity value.
    public func keywordSuggestions(adamId: String,
                                   countries: [String] = ["US"],
                                   seedTerms: [String] = []) async throws -> [ASAKeywordSuggestion] {
        struct Wire: Decodable {
            var keyword: String?
            var matchType: String?
            var suggestedAmount: Amount?
            var bidIndex: Double?
            var searchVolumeIndex: Double?
            var popularity: Double?
            struct Amount: Decodable { var amount: String? }
        }

        var selector: [String: Any] = [
            "pagination": ["offset": 0, "limit": 1000],
        ]
        if !seedTerms.isEmpty {
            selector["conditions"] = [[
                "field": "text",
                "operator": "CONTAINS_ANY",
                "values": seedTerms,
            ]]
        }
        let body: [String: Any] = [
            "adamId": Int(adamId) ?? 0,
            "countriesOrRegions": countries,
            "selector": selector,
        ]

        let request = try await request("keywords/recommendations",
                                        method: "POST",
                                        body: try JSONSerialization.data(withJSONObject: body))
        let response = try await http.send(request, as: ASAEnvelope<[Wire]>.self)
        return (response.data ?? []).compactMap { wire in
            guard let text = wire.keyword else { return nil }
            return ASAKeywordSuggestion(
                text: text,
                popularity: wire.popularity ?? wire.searchVolumeIndex,
                suggestedBid: wire.suggestedAmount?.amount.flatMap(Double.init))
        }
    }

    // MARK: Writes

    /// Updates a keyword bid. Callers must confirm before calling, matching the
    /// read-then-confirm-then-write rule used for metadata.
    public func updateKeywordBid(campaignId: String, adGroupId: String,
                                 keywordId: String, bid: Double,
                                 currency: String = "EUR") async throws {
        let body: [String: Any] = [
            "bidAmount": ["amount": String(format: "%.2f", bid), "currency": currency],
        ]
        let request = try await request(
            "campaigns/\(campaignId)/adgroups/\(adGroupId)/targetingkeywords/\(keywordId)",
            method: "PUT",
            body: try JSONSerialization.data(withJSONObject: body))
        _ = try await http.send(request)
    }

    /// Adds keywords to an ad group.
    public func addKeywords(campaignId: String, adGroupId: String,
                            keywords: [(text: String, matchType: String, bid: Double)],
                            currency: String = "EUR") async throws {
        let payload = keywords.map { keyword in
            [
                "text": keyword.text,
                "matchType": keyword.matchType,
                "bidAmount": ["amount": String(format: "%.2f", keyword.bid),
                              "currency": currency],
            ] as [String: Any]
        }
        let request = try await request(
            "campaigns/\(campaignId)/adgroups/\(adGroupId)/targetingkeywords/bulk",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: payload))
        _ = try await http.send(request)
    }
}
