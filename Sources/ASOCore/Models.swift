import Foundation

/// An app tracked by the command center, keyed by its App Store Connect id.
public struct TrackedApp: Identifiable, Hashable, Codable, Sendable {
    public var id: String            // App Store Connect app id
    public var bundleId: String
    public var name: String
    public var sku: String?
    public var primaryLocale: String
    /// Storefronts we track ranks in, e.g. ["us", "nl", "be"].
    public var countries: [String]

    public init(id: String, bundleId: String, name: String, sku: String? = nil,
                primaryLocale: String = "en-US", countries: [String] = ["us"]) {
        self.id = id
        self.bundleId = bundleId
        self.name = name
        self.sku = sku
        self.primaryLocale = primaryLocale
        self.countries = countries
    }
}

/// Where a piece of metadata lives in App Store Connect determines how it is written.
///
/// This split is the single most common source of failed metadata pushes: title and
/// subtitle hang off `appInfoLocalizations`, everything else off
/// `appStoreVersionLocalizations`. They are different objects with different ids.
public enum MetadataField: String, CaseIterable, Codable, Sendable {
    case name              // appInfoLocalizations
    case subtitle          // appInfoLocalizations
    case privacyPolicyUrl  // appInfoLocalizations
    case description       // appStoreVersionLocalizations
    case keywords          // appStoreVersionLocalizations
    case promotionalText   // appStoreVersionLocalizations
    case marketingUrl      // appStoreVersionLocalizations
    case supportUrl        // appStoreVersionLocalizations
    case whatsNew          // appStoreVersionLocalizations

    public enum Container: Sendable { case appInfo, version }

    public var container: Container {
        switch self {
        case .name, .subtitle, .privacyPolicyUrl: return .appInfo
        case .description, .keywords, .promotionalText, .marketingUrl, .supportUrl, .whatsNew:
            return .version
        }
    }

    /// Apple's hard character limits. Exceeding these fails the PATCH with a 409.
    public var characterLimit: Int? {
        switch self {
        case .name: return 30
        case .subtitle: return 30
        case .keywords: return 100
        case .description: return 4000
        case .promotionalText: return 170
        case .whatsNew: return 4000
        case .marketingUrl, .supportUrl, .privacyPolicyUrl: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .name: return "Title"
        case .subtitle: return "Subtitle"
        case .privacyPolicyUrl: return "Privacy Policy URL"
        case .description: return "Description"
        case .keywords: return "Keywords"
        case .promotionalText: return "Promotional Text"
        case .marketingUrl: return "Marketing URL"
        case .supportUrl: return "Support URL"
        case .whatsNew: return "What's New"
        }
    }
}

/// The full metadata set for one app in one locale.
public struct LocalizedMetadata: Hashable, Codable, Sendable {
    public var locale: String
    /// id of the appInfoLocalizations object; nil when the locale does not exist yet.
    public var appInfoLocalizationId: String?
    /// id of the appStoreVersionLocalizations object; nil when it does not exist yet.
    public var versionLocalizationId: String?
    public var values: [MetadataField: String]

    public init(locale: String,
                appInfoLocalizationId: String? = nil,
                versionLocalizationId: String? = nil,
                values: [MetadataField: String] = [:]) {
        self.locale = locale
        self.appInfoLocalizationId = appInfoLocalizationId
        self.versionLocalizationId = versionLocalizationId
        self.values = values
    }

    public subscript(field: MetadataField) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }
}

/// App Store version states, as returned by ASC.
public enum AppStoreState: String, Codable, Sendable {
    case readyForDistribution = "READY_FOR_DISTRIBUTION"
    case readyForSale = "READY_FOR_SALE"
    case replacedWithNewVersion = "REPLACED_WITH_NEW_VERSION"
    case prepareForSubmission = "PREPARE_FOR_SUBMISSION"
    case waitingForReview = "WAITING_FOR_REVIEW"
    case inReview = "IN_REVIEW"
    case pendingDeveloperRelease = "PENDING_DEVELOPER_RELEASE"
    case rejected = "REJECTED"
    case developerRejected = "DEVELOPER_REJECTED"
    case metadataRejected = "METADATA_REJECTED"
    case pendingAppleRelease = "PENDING_APPLE_RELEASE"
    case processingForDistribution = "PROCESSING_FOR_DISTRIBUTION"
    case unknown = "UNKNOWN"

    /// A version currently visible on the store.
    public var isPublic: Bool {
        self == .readyForDistribution || self == .readyForSale
    }

    /// A version that can still be edited. Superseded versions are excluded, matching
    /// app-agent's classification, because they are immutable history.
    public var isDraft: Bool {
        !isPublic && self != .replacedWithNewVersion
    }

    /// Whether ASC will accept metadata writes against this version.
    ///
    /// Writing to a live version silently fails or 409s; the user must have an
    /// editable version present. We surface that as a precondition rather than
    /// discovering it during a push.
    public var acceptsMetadataWrites: Bool { isDraft }
}

public struct AppStoreVersion: Hashable, Codable, Sendable {
    public var id: String
    public var versionString: String
    public var state: AppStoreState
    public var platform: String
    public var createdDate: Date?

    public init(id: String, versionString: String, state: AppStoreState,
                platform: String, createdDate: Date? = nil) {
        self.id = id
        self.versionString = versionString
        self.state = state
        self.platform = platform
        self.createdDate = createdDate
    }
}

/// One field-level difference between local edits and what is live on App Store Connect.
public struct MetadataDiff: Identifiable, Hashable, Sendable {
    public var id: String { "\(locale).\(field.rawValue)" }
    public var locale: String
    public var field: MetadataField
    public var remote: String
    public var local: String

    public var isChanged: Bool { remote != local }

    /// Set when the new value violates Apple's character limit; blocks the push.
    public var limitViolation: String? {
        guard let limit = field.characterLimit, local.count > limit else { return nil }
        return "\(field.displayName) is \(local.count) characters, limit is \(limit)"
    }

    public init(locale: String, field: MetadataField, remote: String, local: String) {
        self.locale = locale
        self.field = field
        self.remote = remote
        self.local = local
    }
}
