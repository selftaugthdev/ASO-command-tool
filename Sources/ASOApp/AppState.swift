import Foundation
import SwiftUI
import ASOCore
import ASOStore
import ASCKit
import ASAKit
import KeywordKit
import RevenueKit

/// A user-visible operation result, surfaced as a banner.
struct StatusMessage: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var text: String
}

/// Central app state. Owns the store and lazily builds API clients from
/// whatever credentials are present in the Keychain.
@MainActor
@Observable
final class AppState {
    var apps: [TrackedApp] = []
    var selectedAppId: String?
    var selectedCountry: String = "us"

    var keywords: [TrackedKeyword] = []
    var rankHistory: [Int64: [RankPoint]] = [:]
    var roasRows: [KeywordROAS] = []
    var alerts: [ASOAlert] = []
    var diagnostic: AttributionDiagnostic?

    /// Metadata pulled from ASC, and the user's in-progress edits.
    var snapshot: AppMetadataSnapshot?
    var edits: [String: LocalizedMetadata] = [:]
    var pendingPlan: PushPlan?

    var isBusy = false
    var busyLabel = ""
    var status: StatusMessage?

    let store: ASOStore
    let credentials = CredentialStore()

    var selectedApp: TrackedApp? {
        apps.first { $0.id == selectedAppId }
    }

    init(store: ASOStore) {
        self.store = store
        reloadApps()
    }

    // MARK: - Credential presence

    // These are plain stored properties, deliberately not computed.
    //
    // Reading the Keychain is a synchronous call that blocks until the user
    // answers an authorization prompt. When that happened inside a SwiftUI
    // body it blocked the main thread before the window was ever created, so
    // the app launched to no window at all. Presence is now sampled off the
    // main thread and cached here.
    private(set) var hasASCCredentials = false
    private(set) var hasASACredentials = false
    private(set) var hasFirebaseCredentials = false

    /// Samples the Keychain off the main thread and republishes the results.
    /// Call once at launch and again whenever Settings changes a credential.
    func refreshCredentialStatus() async {
        let store = credentials
        let status = await Task.detached(priority: .userInitiated) {
            (asc: store.isConfigured([.ascIssuerId, .ascKeyId, .ascPrivateKey]),
             asa: store.isConfigured([.asaClientId, .asaTeamId, .asaKeyId,
                                      .asaPrivateKey, .asaOrgId]),
             firebase: store.contains(.firebaseServiceAccount))
        }.value

        hasASCCredentials = status.asc
        hasASACredentials = status.asa
        hasFirebaseCredentials = status.firebase
    }

    // MARK: - Credential-derived clients

    func ascClient() throws -> ASCClient {
        try ASCClient(credentials: ASCCredentials(store: credentials))
    }

    func asaClient() throws -> ASAClient {
        try ASAClient(credentials: ASACredentials(store: credentials))
    }

    func firestoreClient() throws -> FirestoreClient {
        try FirestoreClient(serviceAccountJSON: credentials.get(.firebaseServiceAccount))
    }

    // MARK: - Local reads

    func reloadApps() {
        do {
            apps = try store.apps()
            if selectedAppId == nil { selectedAppId = apps.first?.id }
        } catch {
            report(.error, "Could not load apps: \(error.localizedDescription)")
        }
    }

    func reloadKeywords() {
        guard let appId = selectedAppId else { keywords = []; return }
        do {
            keywords = try store.keywords(appId: appId, country: selectedCountry)
            rankHistory = try store.rankHistory(appId: appId, country: selectedCountry)
        } catch {
            report(.error, "Could not load keywords: \(error.localizedDescription)")
        }
    }

    func reloadAlerts() {
        alerts = (try? store.alerts(limit: 50)) ?? []
    }

    func reloadRevenue(days: Int = 30) {
        guard let appId = selectedAppId else { roasRows = []; return }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        do {
            let spend = try store.spend(appId: appId, since: since)
            let revenue = try store.revenue(appId: appId, since: since)
            roasRows = ROASCalculator.compute(spend: spend, revenue: revenue)
            diagnostic = try AttributionDiagnostic.run(store: store, appId: appId, days: days)
        } catch {
            report(.error, "Could not compute ROAS: \(error.localizedDescription)")
        }
    }

    // MARK: - Remote operations

    /// Imports the app list from App Store Connect.
    func importApps() async {
        await run("Importing apps from App Store Connect") {
            let client = try self.ascClient()
            let remote = try await client.listApps()
            for var app in remote {
                // Preserve locally chosen tracking countries on re-import.
                if let existing = self.apps.first(where: { $0.id == app.id }) {
                    app.countries = existing.countries
                }
                try self.store.upsertApp(app)
            }
            self.reloadApps()
            return .success("Imported \(remote.count) app(s)")
        }
    }

    /// Pulls live metadata for the selected app and resets local edits to match.
    func pullMetadata() async {
        guard let app = selectedApp else { return }
        await run("Pulling metadata for \(app.name)") {
            let client = try self.ascClient()
            let snapshot = try await client.fetchMetadata(for: app)
            self.snapshot = snapshot
            self.edits = snapshot.metadata
            // Record what was live, so any push can be reversed later.
            try self.store.recordSnapshot(appId: app.id, metadata: snapshot.metadata)

            if snapshot.editableVersion == nil {
                return .warning("Pulled \(snapshot.locales.count) locale(s). No editable "
                              + "version, so keywords and description are read-only until "
                              + "you create one in App Store Connect.")
            }
            return .success("Pulled \(snapshot.locales.count) locale(s) from "
                          + "version \(snapshot.editableVersion?.versionString ?? "?")")
        }
    }

    /// Builds a plan from current edits. Does not write anything.
    func preparePush() {
        guard let snapshot else { return }
        let plan = MetadataDiffer.plan(remote: snapshot, local: edits)
        if plan.isEmpty {
            report(.info, "No changes to push")
            return
        }
        pendingPlan = plan
    }

    /// Sends a plan the user has explicitly confirmed in the review sheet.
    func confirmPush() async {
        guard let plan = pendingPlan, plan.canPush else { return }
        pendingPlan = nil
        await run("Pushing metadata") {
            let client = try self.ascClient()
            let report = try await client.push(plan.confirmed())
            // Re-pull so the diff view reflects what Apple actually stored.
            if let app = self.selectedApp {
                let fresh = try await client.fetchMetadata(for: app)
                self.snapshot = fresh
                self.edits = fresh.metadata
            }
            return report.allSucceeded ? .success(report.summary) : .warning(report.summary)
        }
    }

    /// Researches new terms and stores them.
    func research(terms: [String]) async {
        guard let app = selectedApp, !terms.isEmpty else { return }
        await run("Researching \(terms.count) keyword(s)") {
            let researcher = KeywordResearcher(
                store: self.store,
                asa: self.hasASACredentials ? try? self.asaClient() : nil)
            let insights = try await researcher.research(terms: terms, for: app,
                                                         country: self.selectedCountry)
            try researcher.persist(insights, appId: app.id)
            self.reloadKeywords()

            let withPopularity = insights.filter { $0.popularity != nil }.count
            if withPopularity == 0 && self.hasASACredentials {
                return .warning("Added \(insights.count) keyword(s). Search Ads returned no "
                              + "popularity for these terms; difficulty and rank are still live.")
            }
            return .success("Added \(insights.count) keyword(s), "
                          + "\(withPopularity) with Apple popularity data")
        }
    }

    /// Adds imported terms without contacting any API.
    ///
    /// Importing a few hundred keywords from another tool would otherwise mean
    /// a few hundred store lookups up front; this lets the terms land instantly
    /// and defers the lookups to the next rank refresh.
    ///
    /// Any volume figure from the source tool is stored tagged as `imported`, so
    /// the table can show it while making clear it is not Apple's index.
    func importKeywords(_ imported: [ImportedKeyword]) async {
        guard let app = selectedApp, !imported.isEmpty else { return }
        await run("Importing \(imported.count) keyword(s)") {
            var withVolume = 0
            for keyword in imported {
                let id = try self.store.addKeyword(appId: app.id, term: keyword.term,
                                                   country: self.selectedCountry)
                if let volume = keyword.volume {
                    try self.store.updateMetrics(keywordId: id,
                                                 popularity: volume,
                                                 difficulty: keyword.difficulty,
                                                 competitors: nil,
                                                 source: MetricSource.imported.rawValue)
                    withVolume += 1
                }
                if let rank = keyword.rank {
                    try self.store.recordRank(keywordId: id, rank: rank)
                }
            }
            self.reloadKeywords()

            let volumeNote = withVolume > 0
                ? " \(withVolume) came with a volume figure, shown as \"imported\"."
                : ""
            return .success("Imported \(imported.count) keyword(s).\(volumeNote) "
                          + "Run Refresh Ranks to fill in live rank and difficulty.")
        }
    }

    /// Re-checks rank for every tracked keyword.
    func refreshRanks() async {
        guard let app = selectedApp else { return }
        await run("Refreshing ranks for \(app.name)") {
            let researcher = KeywordResearcher(store: self.store)
            _ = try await researcher.refreshRanks(for: app, country: self.selectedCountry)
            self.reloadKeywords()
            return .success("Ranks updated for \(self.keywords.count) keyword(s)")
        }
    }

    /// Pulls Search Ads spend for the selected app.
    func syncSpend(days: Int = 30) async {
        guard let app = selectedApp else { return }
        await run("Syncing Apple Search Ads spend") {
            let client = try self.asaClient()
            let campaigns = try await client.campaigns().filter { $0.adamId == app.id }
            guard !campaigns.isEmpty else {
                return .warning("No Search Ads campaigns found promoting \(app.name)")
            }

            let from = Date().addingTimeInterval(-Double(days) * 86_400)
            var rows: [SpendRow] = []
            for campaign in campaigns {
                let reports = try await client.keywordReport(campaignId: campaign.id,
                                                             from: from, to: Date())
                rows.append(contentsOf: reports.map { report in
                    SpendRow(appId: app.id,
                             campaignId: report.campaignId,
                             campaignName: campaign.name,
                             adGroupId: report.adGroupId,
                             keywordId: report.keywordId,
                             keywordText: report.keyword,
                             country: report.countryCode,
                             day: report.date,
                             spend: report.spend,
                             impressions: report.impressions,
                             taps: report.taps,
                             installs: report.installs)
                })
            }
            try self.store.recordSpend(rows)
            self.reloadRevenue()
            return .success("Synced \(rows.count) spend row(s) from "
                          + "\(campaigns.count) campaign(s)")
        }
    }

    /// Pulls RevenueCat events from the Firestore relay.
    func syncRevenue() async {
        await run("Syncing revenue from Firebase") {
            let firestore = try self.firestoreClient()
            let sync = RevenueCatSync(firestore: firestore, store: self.store)
            let count = try await sync.sync()
            self.reloadRevenue()
            return count > 0
                ? .success("Synced \(count) revenue event(s)")
                : .info("No new revenue events")
        }
    }

    // MARK: - Plumbing

    private enum Outcome {
        case success(String), warning(String), info(String)
    }

    /// Runs an async operation with a busy indicator and uniform error handling.
    private func run(_ label: String, _ body: @escaping () async throws -> Outcome) async {
        isBusy = true
        busyLabel = label
        defer { isBusy = false; busyLabel = "" }

        do {
            switch try await body() {
            case .success(let text): report(.success, text)
            case .warning(let text): report(.warning, text)
            case .info(let text): report(.info, text)
            }
        } catch let error as APIError {
            report(.error, Self.explain(error))
        } catch let error as KeychainError {
            report(.error, error.localizedDescription)
        } catch {
            report(.error, "\(label) failed: \(error.localizedDescription)")
        }
    }

    /// Turns an API failure into something actionable rather than a raw status code.
    private static func explain(_ error: APIError) -> String {
        switch error.kind {
        case .unauthorized:
            return "Apple rejected the credentials. Check the Key ID, Issuer ID and .p8 "
                 + "in Settings, and that the key has the right role. (\(error.message))"
        case .agreementExpired:
            return error.message
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " Retry in \(Int($0))s." } ?? ""
            return "Hit Apple's rate limit after several retries.\(wait)"
        case .conflict:
            return "Apple rejected the change: \(error.message)"
        case .notFound:
            return "Not found: \(error.message)"
        case .decoding:
            return "Unexpected response shape from Apple: \(error.message)"
        case .transport:
            return "Network error: \(error.message)"
        case .server(let status):
            return "Apple returned \(status): \(error.message)"
        }
    }

    func report(_ kind: StatusMessage.Kind, _ text: String) {
        status = StatusMessage(kind: kind, text: text)
    }
}
