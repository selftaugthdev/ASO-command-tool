import Foundation
import ASOCore

/// Client for the App Store Connect API.
///
/// Read paths are safe to call freely. Every write goes through `push`, which
/// requires a `PushPlan` the caller has explicitly confirmed.
public final class ASCClient: @unchecked Sendable {
    private let base = URL(string: "https://api.appstoreconnect.apple.com/v1")!
    private let tokens: ASCTokenProvider
    private let http: HTTPClient

    public init(credentials: ASCCredentials, http: HTTPClient? = nil) throws {
        self.tokens = try ASCTokenProvider(credentials: credentials)
        // Apple documents 7200 requests/hour for the App Store Connect API.
        // The local pace is set just under that; the real governor is the
        // `X-Rate-Limit` header on each response, which reports the actual
        // remaining budget and accounts for consumption by anything else using
        // the same key. Apple also applies undocumented per-endpoint and
        // per-minute limits, so the header is the only trustworthy signal.
        self.http = http ?? HTTPClient(config: HTTPClientConfig(requestsPerHour: 7000))
    }

    // MARK: - Request plumbing

    private func request(_ path: String,
                         method: String = "GET",
                         query: [String: String] = [:],
                         body: Data? = nil) async throws -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokens.bearerToken())",
                         forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Absolute-URL variant used to follow pagination links.
    private func request(absolute url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await tokens.bearerToken())",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// Fetches every page of a collection.
    ///
    /// ASC pages at 50 items by default. app-agent reads only the first page,
    /// which silently truncates apps and localizations once an account grows —
    /// a bug that only shows up after you ship your ninth locale.
    private func getAll<T: Decodable>(_ path: String,
                                      query: [String: String] = [:],
                                      as type: T.Type) async throws -> [T] {
        var results: [T] = []
        var query = query
        query["limit"] = query["limit"] ?? "200"

        var request = try await request(path, query: query)
        while true {
            let page = try await http.send(request, as: ASCResponse<[T]>.self)
            results.append(contentsOf: page.data)
            guard let next = page.links?.next, let url = URL(string: next) else { break }
            request = try await self.request(absolute: url)
        }
        return results
    }

    private func getOne<T: Decodable>(_ path: String,
                                      query: [String: String] = [:],
                                      as type: T.Type) async throws -> T {
        let request = try await request(path, query: query)
        return try await http.send(request, as: ASCResponse<T>.self).data
    }

    // MARK: - Reads

    /// Lists every app on the account.
    public func listApps() async throws -> [TrackedApp] {
        let apps = try await getAll("apps",
                                    query: ["fields[apps]": "name,bundleId,sku,primaryLocale"],
                                    as: ASCApp.self)
        return apps.map {
            TrackedApp(id: $0.id,
                       bundleId: $0.attributes?.bundleId ?? "",
                       name: $0.attributes?.name ?? "Untitled",
                       sku: $0.attributes?.sku,
                       primaryLocale: $0.attributes?.primaryLocale ?? "en-US")
        }
    }

    /// Pulls the full metadata snapshot for one app.
    ///
    /// Reads title/subtitle from the editable appInfo when there is one so the
    /// diff compares against what a push would actually overwrite, falling back
    /// to the live appInfo for apps with no version in flight.
    public func fetchMetadata(for app: TrackedApp) async throws -> AppMetadataSnapshot {
        let appInfos = try await getAll("apps/\(app.id)/appInfos", as: ASCAppInfo.self)
        let versions = try await getAll(
            "apps/\(app.id)/appStoreVersions",
            query: ["fields[appStoreVersions]": "versionString,appStoreState,platform,createdDate,releaseType"],
            as: ASCVersion.self)

        let iosVersions = versions.filter { ($0.attributes?.platform ?? "IOS") == "IOS" }
        let editableRaw = iosVersions.first { $0.resolvedState.isDraft }
        let liveRaw = iosVersions.first { $0.resolvedState.isPublic }

        func domain(_ raw: ASCVersion?) -> AppStoreVersion? {
            guard let raw else { return nil }
            return AppStoreVersion(id: raw.id,
                                   versionString: raw.attributes?.versionString ?? "?",
                                   state: raw.resolvedState,
                                   platform: raw.attributes?.platform ?? "IOS",
                                   createdDate: raw.attributes?.createdDate)
        }

        let appInfo = appInfos.first { $0.resolvedState.isDraft }
            ?? appInfos.first { $0.resolvedState.isPublic }
            ?? appInfos.first

        var metadata: [String: LocalizedMetadata] = [:]

        if let appInfo {
            let localizations = try await getAll(
                "appInfos/\(appInfo.id)/appInfoLocalizations",
                as: ASCAppInfoLocalization.self)
            for localization in localizations {
                guard let locale = localization.attributes?.locale else { continue }
                var entry = metadata[locale] ?? LocalizedMetadata(locale: locale)
                entry.appInfoLocalizationId = localization.id
                entry[.name] = localization.attributes?.name ?? ""
                entry[.subtitle] = localization.attributes?.subtitle ?? ""
                entry[.privacyPolicyUrl] = localization.attributes?.privacyPolicyUrl ?? ""
                metadata[locale] = entry
            }
        }

        // Version-scoped fields come from the editable version when one exists,
        // otherwise from the live version so the user can still read them.
        if let versionId = (editableRaw ?? liveRaw)?.id {
            let localizations = try await getAll(
                "appStoreVersions/\(versionId)/appStoreVersionLocalizations",
                as: ASCVersionLocalization.self)
            for localization in localizations {
                guard let locale = localization.attributes?.locale else { continue }
                var entry = metadata[locale] ?? LocalizedMetadata(locale: locale)
                entry.versionLocalizationId = localization.id
                entry[.description] = localization.attributes?.description ?? ""
                entry[.keywords] = localization.attributes?.keywords ?? ""
                entry[.promotionalText] = localization.attributes?.promotionalText ?? ""
                entry[.marketingUrl] = localization.attributes?.marketingUrl ?? ""
                entry[.supportUrl] = localization.attributes?.supportUrl ?? ""
                entry[.whatsNew] = localization.attributes?.whatsNew ?? ""
                metadata[locale] = entry
            }
        }

        return AppMetadataSnapshot(app: app,
                                   editableVersion: domain(editableRaw),
                                   liveVersion: domain(liveRaw),
                                   appInfoId: appInfo?.id,
                                   metadata: metadata)
    }

    // MARK: - Writes

    /// Applies a confirmed plan, one field group at a time.
    ///
    /// Returns a per-operation result rather than throwing on the first failure:
    /// a rejected keyword string in one locale should not silently abandon the
    /// other locales that already succeeded.
    public func push(_ plan: PushPlan) async throws -> PushReport {
        guard plan.isConfirmed else {
            throw APIError(kind: .conflict,
                           message: "Refusing to push an unconfirmed plan")
        }
        var outcomes: [PushOutcome] = []

        for operation in plan.operations {
            do {
                switch operation.container {
                case .appInfo:
                    try await writeAppInfoLocalization(operation, appInfoId: plan.appInfoId)
                case .version:
                    try await writeVersionLocalization(operation,
                                                       versionId: plan.editableVersionId)
                }
                outcomes.append(PushOutcome(operation: operation, error: nil))
            } catch {
                outcomes.append(PushOutcome(operation: operation, error: error))
            }
        }
        return PushReport(appId: plan.appId, outcomes: outcomes)
    }

    private func writeAppInfoLocalization(_ operation: PushOperation,
                                          appInfoId: String?) async throws {
        var attributes: [String: String?] = [:]
        for (field, value) in operation.values { attributes[field.rawValue] = value }

        if let localizationId = operation.localizationId {
            let payload = ASCWritePayload(data: .init(
                type: "appInfoLocalizations",
                id: localizationId,
                attributes: attributes,
                relationships: nil))
            let request = try await request("appInfoLocalizations/\(localizationId)",
                                            method: "PATCH",
                                            body: try JSONEncoder().encode(payload))
            _ = try await http.send(request)
        } else {
            // New locale: must POST with a relationship to the parent appInfo.
            // app-agent PATCHes to `/appInfoLocalizations/null` here instead,
            // which fails for any locale not already present.
            guard let appInfoId else {
                throw APIError(kind: .conflict,
                               message: "Cannot create \(operation.locale): no editable appInfo")
            }
            attributes["locale"] = operation.locale
            let payload = ASCWritePayload(data: .init(
                type: "appInfoLocalizations",
                id: nil,
                attributes: attributes,
                relationships: ["appInfo": .init(data: .init(type: "appInfos", id: appInfoId))]))
            let request = try await request("appInfoLocalizations",
                                            method: "POST",
                                            body: try JSONEncoder().encode(payload))
            _ = try await http.send(request)
        }
    }

    private func writeVersionLocalization(_ operation: PushOperation,
                                          versionId: String?) async throws {
        var attributes: [String: String?] = [:]
        for (field, value) in operation.values { attributes[field.rawValue] = value }

        if let localizationId = operation.localizationId {
            let payload = ASCWritePayload(data: .init(
                type: "appStoreVersionLocalizations",
                id: localizationId,
                attributes: attributes,
                relationships: nil))
            let request = try await request("appStoreVersionLocalizations/\(localizationId)",
                                            method: "PATCH",
                                            body: try JSONEncoder().encode(payload))
            _ = try await http.send(request)
        } else {
            guard let versionId else {
                throw APIError(kind: .conflict,
                               message: "Cannot create \(operation.locale): no editable version. "
                                      + "Create a new version in App Store Connect first.")
            }
            attributes["locale"] = operation.locale
            let payload = ASCWritePayload(data: .init(
                type: "appStoreVersionLocalizations",
                id: nil,
                attributes: attributes,
                relationships: ["appStoreVersion": .init(
                    data: .init(type: "appStoreVersions", id: versionId))]))
            let request = try await request("appStoreVersionLocalizations",
                                            method: "POST",
                                            body: try JSONEncoder().encode(payload))
            _ = try await http.send(request)
        }
    }
}
