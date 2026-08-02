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
    var opportunities: [LocaleOpportunity] = []
    var impacts: [ChangeImpact] = []
    var presence: [CompetitorPresence] = []
    var diagnostic: AttributionDiagnostic?

    /// Metadata pulled from ASC, and the user's in-progress edits.
    var snapshot: AppMetadataSnapshot?
    var edits: [String: LocalizedMetadata] = [:]
    var pendingPlan: PushPlan?

    var isBusy = false
    var busyLabel = ""
    var status: StatusMessage?
    var progress: OperationProgress?
    var schedule = SchedulePreferences.load()

    /// Handle for the running long operation, so it can be cancelled.
    private var runningTask: Task<Void, Never>?
    private var scheduleTimer: Timer?

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

    /// Change events for the selected app, each scored against rank movement.
    func reloadImpacts() {
        guard let appId = selectedAppId else { impacts = []; return }
        let country = selectedCountry
        // Only events for locales served by the selected storefront can be
        // judged against its ranks; a German edit says nothing about US ranks.
        let events = ((try? store.metadataEvents(appId: appId)) ?? [])
            .filter { Locales.country(for: $0.locale) == country }
        impacts = events.compactMap { try? store.impact(of: $0, country: country) }
    }

    func reloadCompetitorPresence() {
        guard let appId = selectedAppId else { presence = []; return }
        presence = (try? store.competitorPresence(appId: appId,
                                                  country: selectedCountry)) ?? []
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

            // Anything that differs from the last snapshot but was not pushed
            // from here was changed in App Store Connect directly. Recording it
            // as `detected` keeps the timeline honest: the value is right, the
            // timestamp is when it was noticed, not when it happened.
            var detected = 0
            for (locale, entry) in snapshot.metadata {
                for (field, newValue) in entry.values {
                    guard let previous = try self.store.lastSnapshot(
                        appId: app.id, locale: locale, field: field) else { continue }
                    guard previous.value != newValue else { continue }
                    try self.store.recordMetadataEvent(
                        appId: app.id, locale: locale, field: field,
                        oldValue: previous.value, newValue: newValue, source: .detected)
                    detected += 1
                }
            }

            // Record what was live, so any push can be reversed later.
            try self.store.recordSnapshot(appId: app.id, metadata: snapshot.metadata)
            self.reloadImpacts()

            if detected > 0 {
                return .info("Pulled \(snapshot.locales.count) locale(s). Noticed "
                           + "\(detected) field(s) changed outside this app — added to "
                           + "the change timeline.")
            }

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

            // Record what changed, at the moment it changed. This is the one
            // thing a tool that only observes cannot know: it made the change,
            // so the timestamp and the exact before/after are exact rather
            // than inferred from a version number appearing later.
            let succeeded = Set(report.succeeded.map(\.operation.id))
            for diff in plan.diffs where diff.isChanged {
                let operationId = "\(diff.locale).\(diff.field.container == .appInfo ? "info" : "version")"
                guard succeeded.contains(operationId) else { continue }
                try self.store.recordMetadataEvent(
                    appId: plan.appId, locale: diff.locale, field: diff.field,
                    oldValue: diff.remote, newValue: diff.local, source: .push)
            }
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
        beginProgress(label: "Researching \(terms.count) keyword(s)", total: terms.count)

        await run("Researching \(terms.count) keyword(s)") {
            let researcher = KeywordResearcher(
                store: self.store,
                asa: self.hasASACredentials ? try? self.asaClient() : nil)
            let insights = try await researcher.research(
                terms: terms, for: app, country: self.selectedCountry,
                onProgress: { [weak self] completed, total in
                    await self?.updateProgress(completed: completed, total: total)
                })
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
        let total = keywords.count
        guard total > 0 else { return }

        beginProgress(label: "Refreshing ranks for \(app.name)", total: total)

        await run("Refreshing ranks for \(app.name)") {
            let researcher = KeywordResearcher(store: self.store)
            let outcome = try await researcher.refreshRanks(
                for: app,
                country: self.selectedCountry,
                onProgress: { [weak self] completed, total in
                    await self?.updateProgress(completed: completed, total: total)
                })
            self.reloadKeywords()
            return Self.describe(outcome, label: "Ranks updated")
        }
    }

    /// Turns a sweep outcome into an honest one-line summary.
    ///
    /// Partial results are reported as partial rather than as success, so an
    /// interrupted run is never mistaken for a complete one.
    private static func describe(_ outcome: KeywordResearcher.RefreshOutcome,
                                 label: String) -> Outcome {
        var parts: [String] = ["\(label): \(outcome.refreshed) keyword(s)"]
        if outcome.alreadyFresh > 0 {
            parts.append("\(outcome.alreadyFresh) already current")
        }
        if outcome.failed > 0 {
            parts.append("\(outcome.failed) failed")
        }
        let summary = parts.joined(separator: ", ") + "."

        if outcome.abortedOffline {
            return .warning(summary + " Stopped early after repeated network "
                          + "failures. Everything done so far is saved; run it "
                          + "again when you are back online and it will pick up "
                          + "where it left off.")
        }
        if outcome.failed > 0 {
            return .warning(summary + " The failures are saved as unchecked and "
                          + "will be retried on the next run.")
        }
        return .success(summary)
    }

    /// Refreshes every tracked keyword across every app and country.
    ///
    /// This is what the scheduled job runs, and what the toolbar's "Refresh All"
    /// does. Ranks are compared against the previous reading and material drops
    /// are recorded as alerts, so a sweep produces something to act on rather
    /// than just refreshed numbers.
    func refreshAllApps(isScheduled: Bool = false) async {
        let pairs = (try? store.trackedAppCountryPairs()) ?? []
        let total = pairs.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            if !isScheduled { report(.info, "No tracked keywords to refresh") }
            return
        }

        let appsById = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        beginProgress(label: isScheduled ? "Daily refresh" : "Refreshing all apps",
                      total: total)

        // Anything already checked since midnight is skipped, so a sweep cut
        // short by sleep, a dropped connection or a shutdown resumes rather
        // than repeating hours of work.
        let today = Calendar.utc.startOfDay(for: Date())

        await run("Refreshing all apps") {
            let researcher = KeywordResearcher(store: self.store)
            var completedOverall = 0
            var alertsRaised = 0
            var appsCovered = 0
            var combined = KeywordResearcher.RefreshOutcome()

            for pair in pairs {
                guard let app = appsById[pair.appId] else {
                    completedOverall += pair.count
                    continue
                }
                // Snapshot the ranks before the sweep so movement can be
                // attributed afterwards.
                let before = Dictionary(
                    uniqueKeysWithValues: (try self.store.keywords(appId: pair.appId,
                                                                   country: pair.country))
                        .map { ($0.id, $0.currentRank) })

                let baseline = completedOverall
                let outcome = try await researcher.refreshRanks(
                    for: app,
                    country: pair.country,
                    skipRefreshedSince: today,
                    onProgress: { [weak self] completed, _ in
                        await self?.updateProgress(completed: baseline + completed,
                                                   total: total)
                    })
                completedOverall += pair.count
                appsCovered += 1

                combined.refreshed += outcome.refreshed
                combined.alreadyFresh += outcome.alreadyFresh
                combined.failed += outcome.failed
                combined.abortedOffline = combined.abortedOffline || outcome.abortedOffline

                alertsRaised += try self.raiseRankAlerts(appId: pair.appId,
                                                        country: pair.country,
                                                        previousRanks: before)

                // Give up the whole sweep once the network is clearly gone,
                // instead of failing through every remaining app.
                if outcome.abortedOffline { break }
            }

            // Only count the day as done if the sweep actually completed;
            // otherwise it stays due and resumes on the next check.
            if !combined.abortedOffline {
                self.schedule.lastRun = Date()
                SchedulePreferences.save(self.schedule)
            }
            self.reloadKeywords()
            self.reloadAlerts()

            let alertNote = alertsRaised > 0
                ? " \(alertsRaised) alert(s) raised."
                : " Nothing moved enough to flag."
            let base = Self.describe(combined,
                                     label: "Swept \(appsCovered) app/country combination(s)")
            switch base {
            case .success(let text): return .success(text + alertNote)
            case .warning(let text): return .warning(text + alertNote)
            case .info(let text): return .info(text + alertNote)
            }
        }
    }

    /// Compares post-refresh ranks against a pre-refresh snapshot and records
    /// alerts for material drops.
    private func raiseRankAlerts(appId: String, country: String,
                                 previousRanks: [Int64: Int?]) throws -> Int {
        let threshold = schedule.alertDropThreshold
        let appName = apps.first { $0.id == appId }?.name ?? appId
        var raised = 0

        for keyword in try store.keywords(appId: appId, country: country) {
            guard let previous = previousRanks[keyword.id] ?? nil else { continue }

            if let current = keyword.currentRank {
                let drop = current - previous
                guard drop >= threshold else { continue }
                try store.recordAlert(
                    appId: appId,
                    kind: "rank_drop",
                    title: "\(appName): \"\(keyword.term)\" dropped \(drop) places",
                    body: "Now #\(current) in \(country.uppercased()), was #\(previous).",
                    severity: drop >= threshold * 3 ? .critical : .warning)
                raised += 1
            } else {
                // Falling out of the results entirely is the most severe case
                // and has no numeric drop to compare, so it is checked
                // separately rather than being skipped as a nil.
                try store.recordAlert(
                    appId: appId,
                    kind: "rank_lost",
                    title: "\(appName): \"\(keyword.term)\" left the top 100",
                    body: "Was #\(previous) in \(country.uppercased()), now unranked.",
                    severity: .critical)
                raised += 1
            }
        }
        return raised
    }

    // MARK: - Cross-locale discovery

    /// Searches non-English storefronts for keyword openings.
    func findOpportunities(storefronts: [Storefront], seeds: [String],
                           maxCandidates: Int) async {
        guard let app = selectedApp, !storefronts.isEmpty, !seeds.isEmpty else { return }

        let totalRequests = LocaleOpportunityFinder.estimatedRequests(
            seedCount: seeds.count,
            storefronts: storefronts.count,
            candidatesPerStorefront: maxCandidates)
        beginProgress(label: "Searching \(storefronts.count) storefront(s)",
                      total: totalRequests)

        await run("Finding localized openings") {
            let finder = LocaleOpportunityFinder(
                asa: self.hasASACredentials ? try? self.asaClient() : nil)

            var found: [LocaleOpportunity] = []
            var completed = 0

            for storefront in storefronts {
                let baseline = completed
                let results = try await finder.discover(
                    for: app,
                    storefront: storefront,
                    seedTerms: seeds,
                    maxCandidates: maxCandidates,
                    onProgress: { [weak self] done, _ in
                        await self?.updateProgress(completed: baseline + done,
                                                   total: totalRequests)
                    })
                found.append(contentsOf: results)
                completed += seeds.count + maxCandidates
            }

            self.opportunities = found.sorted { $0.score > $1.score }

            let measured = found.filter(\.demandIsMeasured).count
            let winnable = found.filter { $0.difficulty < 40 && $0.ourRank == nil }.count
            var note = "Found \(found.count) candidate(s), \(winnable) with low "
                     + "difficulty and no current position."
            if measured == 0 && !self.hasASACredentials {
                note += " Demand is the title-targeting proxy, not Apple's index — "
                      + "connect Search Ads for measured popularity."
            }
            return found.isEmpty ? .info("No candidates found.") : .success(note)
        }
    }

    /// Adds a discovered term to tracking for its own storefront.
    func trackOpportunity(_ opportunity: LocaleOpportunity) {
        guard let app = selectedApp else { return }
        do {
            let id = try store.addKeyword(appId: app.id, term: opportunity.term,
                                          country: opportunity.country)
            // The discovery run already measured these, so store them rather
            // than making the next refresh recompute what is known.
            try store.updateMetrics(keywordId: id,
                                    popularity: opportunity.popularity,
                                    difficulty: opportunity.difficulty,
                                    competitors: opportunity.competitorCount,
                                    source: opportunity.demandIsMeasured
                                        ? MetricSource.appleSearchAds.rawValue
                                        : MetricSource.derived.rawValue)
            try store.recordRank(keywordId: id, rank: opportunity.ourRank)
            opportunities.removeAll { $0.id == opportunity.id }
            reloadKeywords()
            report(.success, "Tracking \"\(opportunity.term)\" in "
                           + opportunity.country.uppercased())
        } catch {
            report(.error, "Could not track: \(error.localizedDescription)")
        }
    }

    // MARK: - Pruning

    /// Keywords that a prune would delete, for the confirmation preview.
    func lowPopularityPreview(threshold: Double, allApps: Bool,
                              includeUnknown: Bool) -> [TrackedKeyword] {
        (try? store.lowPopularityKeywords(appId: allApps ? nil : selectedAppId,
                                          below: threshold,
                                          includeUnknown: includeUnknown)) ?? []
    }

    /// Deletes the given keywords. Called only after explicit confirmation.
    func removeKeywords(_ keywords: [TrackedKeyword]) {
        guard !keywords.isEmpty else { return }
        do {
            let removed = try store.removeKeywords(ids: keywords.map(\.id))
            reloadKeywords()
            report(.success, "Removed \(removed) keyword(s).")
        } catch {
            report(.error, "Could not remove keywords: \(error.localizedDescription)")
        }
    }

    // MARK: - Progress and cancellation

    private func beginProgress(label: String, total: Int) {
        progress = OperationProgress(label: label, completed: 0, total: total,
                                     startedAt: Date())
    }

    func updateProgress(completed: Int, total: Int) {
        guard progress != nil else { return }
        progress?.completed = completed
        progress?.total = total
    }

    /// Runs a long operation in a cancellable task.
    ///
    /// Views call this instead of wrapping the call in their own `Task`, so the
    /// handle is retained here and a Stop button has something to cancel.
    func start(_ operation: @escaping @MainActor () async -> Void) {
        runningTask?.cancel()
        runningTask = Task { @MainActor in
            await operation()
            self.runningTask = nil
        }
    }

    /// Requests cancellation. The loop stops at its next iteration boundary, so
    /// work already written to the database is kept rather than rolled back.
    func cancelCurrentOperation() {
        progress?.isCancelling = true
        runningTask?.cancel()
    }

    var canCancel: Bool { runningTask != nil && progress != nil }

    // MARK: - Scheduling

    /// Starts the schedule watcher and catches up on a missed run.
    ///
    /// The catch-up matters more than the timer: the Mac is usually asleep or
    /// the app closed at whatever hour was picked, so most days the run is owed
    /// at launch rather than fired live.
    func startScheduler() {
        scheduleTimer?.invalidate()

        // Checked every five minutes rather than scheduled for the exact
        // moment, so the schedule survives sleep, wake and clock changes
        // without needing to reason about any of them.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.runScheduledRefreshIfDue() }
        }
        runScheduledRefreshIfDue()
    }

    func stopScheduler() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
    }

    func runScheduledRefreshIfDue() {
        guard schedule.isDue() else { return }
        // Never interrupt work already in flight; the run stays due and the
        // next check picks it up.
        guard runningTask == nil, !isBusy else { return }
        start { await self.refreshAllApps(isScheduled: true) }
    }

    func updateSchedule(_ newValue: DailySchedule) {
        schedule = newValue
        SchedulePreferences.save(schedule)
        if schedule.isEnabled {
            startScheduler()
        } else {
            stopScheduler()
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
        defer { isBusy = false; busyLabel = ""; progress = nil }

        do {
            switch try await body() {
            case .success(let text): report(.success, text)
            case .warning(let text): report(.warning, text)
            case .info(let text): report(.info, text)
            }
        } catch is CancellationError {
            // Stopping is a normal outcome, not a failure. Whatever completed
            // before the stop is already saved.
            let done = progress?.completed ?? 0
            report(.info, done > 0
                   ? "Stopped after \(done) keyword(s). Progress so far is saved."
                   : "Stopped.")
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
