import Foundation
import ASOCore

// MARK: - JSON:API envelopes

struct ASCResponse<T: Decodable>: Decodable {
    var data: T
    var included: [ASCIncluded]?
    var links: ASCLinks?
}

struct ASCLinks: Decodable {
    var next: String?
}

/// A minimally-typed included resource, enough to pick out localizations
/// returned alongside their parent.
struct ASCIncluded: Decodable {
    var id: String
    var type: String
    var attributes: [String: ASCValue]?
}

/// ASC attribute values are strings, numbers, booleans or null depending on field.
enum ASCValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        self = .null
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return nil
        }
    }
}

// MARK: - Resources

struct ASCApp: Decodable {
    struct Attributes: Decodable {
        var name: String?
        var bundleId: String?
        var sku: String?
        var primaryLocale: String?
    }
    var id: String
    var attributes: Attributes?
}

struct ASCAppInfo: Decodable {
    struct Attributes: Decodable {
        var appStoreState: String?
        var state: String?
    }
    var id: String
    var attributes: Attributes?

    /// Newer ASC payloads moved this field from `appStoreState` to `state`;
    /// accept whichever is present so the app keeps working across the change.
    var resolvedState: AppStoreState {
        let raw = attributes?.appStoreState ?? attributes?.state ?? ""
        return AppStoreState(rawValue: raw) ?? .unknown
    }
}

struct ASCVersion: Decodable {
    struct Attributes: Decodable {
        var versionString: String?
        var appStoreState: String?
        var appVersionState: String?
        var platform: String?
        var createdDate: Date?
        var releaseType: String?
    }
    var id: String
    var attributes: Attributes?

    var resolvedState: AppStoreState {
        let raw = attributes?.appStoreState ?? attributes?.appVersionState ?? ""
        return AppStoreState(rawValue: raw) ?? .unknown
    }
}

struct ASCAppInfoLocalization: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var name: String?
        var subtitle: String?
        var privacyPolicyUrl: String?
    }
    var id: String
    var attributes: Attributes?
}

struct ASCVersionLocalization: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var description: String?
        var keywords: String?
        var promotionalText: String?
        var marketingUrl: String?
        var supportUrl: String?
        var whatsNew: String?
    }
    var id: String
    var attributes: Attributes?
}

// MARK: - Write payloads

struct ASCWritePayload: Encodable {
    struct Data: Encodable {
        var type: String
        var id: String?
        var attributes: [String: String?]
        var relationships: [String: Relationship]?
    }
    struct Relationship: Encodable {
        struct Ref: Encodable {
            var type: String
            var id: String
        }
        var data: Ref
    }
    var data: Data
}

// MARK: - Domain results

/// Everything the app needs about one App Store Connect app in one pull.
public struct AppMetadataSnapshot: Sendable {
    public var app: TrackedApp
    /// The version metadata edits will be written to, if one exists.
    public var editableVersion: AppStoreVersion?
    /// The version currently live on the store.
    public var liveVersion: AppStoreVersion?
    /// appInfo id backing the editable (or live) title/subtitle.
    public var appInfoId: String?
    public var metadata: [String: LocalizedMetadata]   // keyed by locale
    public var fetchedAt: Date

    public init(app: TrackedApp,
                editableVersion: AppStoreVersion? = nil,
                liveVersion: AppStoreVersion? = nil,
                appInfoId: String? = nil,
                metadata: [String: LocalizedMetadata] = [:],
                fetchedAt: Date = Date()) {
        self.app = app
        self.editableVersion = editableVersion
        self.liveVersion = liveVersion
        self.appInfoId = appInfoId
        self.metadata = metadata
        self.fetchedAt = fetchedAt
    }

    /// Whether metadata can be pushed right now.
    ///
    /// Without an editable version, keywords and description have nowhere to go;
    /// the user must create a new version in App Store Connect first. Title and
    /// subtitle may still be writable via the editable appInfo.
    public var canPushVersionFields: Bool { editableVersion != nil }

    public var locales: [String] { metadata.keys.sorted() }
}
