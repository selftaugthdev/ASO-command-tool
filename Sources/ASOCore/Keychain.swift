import Foundation
import Security

/// Credentials live in the macOS Keychain and nowhere else.
///
/// Nothing in this type is ever logged or sent anywhere except directly to the
/// owning vendor's API. `CredentialStore` deliberately has no `description`
/// conformance that could leak a secret into a crash log.
public enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)
    case notFound(String)
    case malformedData(String)

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .notFound(let account):
            return "No credential stored for \(account)"
        case .malformedData(let account):
            return "Stored credential for \(account) is not valid UTF-8"
        }
    }
}

public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "com.thierry.asocommandcenter") {
        self.service = service
    }

    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try update first; SecItemAdd fails with errSecDuplicateItem otherwise.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    public func get(_ account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound(account) }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedData(account)
        }
        return string
    }

    public func contains(_ account: String) -> Bool {
        (try? get(account)) != nil
    }

    public func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

/// Named slots for every secret the app holds.
public enum CredentialKey: String, CaseIterable, Sendable {
    case ascPrivateKey = "asc.p8"
    case ascKeyId = "asc.keyId"
    case ascIssuerId = "asc.issuerId"

    case asaClientId = "asa.clientId"
    case asaTeamId = "asa.teamId"
    case asaKeyId = "asa.keyId"
    case asaPrivateKey = "asa.p8"
    case asaOrgId = "asa.orgId"

    case revenueCatSecretKey = "revenuecat.secret"
    case revenueCatProjectId = "revenuecat.projectId"

    case firebaseProjectId = "firebase.projectId"
    case firebaseServiceAccount = "firebase.serviceAccount"

    case alertWebhookURL = "alerts.webhook"

    public var displayName: String {
        switch self {
        case .ascPrivateKey: return "App Store Connect .p8 key"
        case .ascKeyId: return "App Store Connect Key ID"
        case .ascIssuerId: return "App Store Connect Issuer ID"
        case .asaClientId: return "Search Ads Client ID"
        case .asaTeamId: return "Search Ads Team ID"
        case .asaKeyId: return "Search Ads Key ID"
        case .asaPrivateKey: return "Search Ads .p8 key"
        case .asaOrgId: return "Search Ads Org ID"
        case .revenueCatSecretKey: return "RevenueCat secret key"
        case .revenueCatProjectId: return "RevenueCat project ID"
        case .firebaseProjectId: return "Firebase project ID"
        case .firebaseServiceAccount: return "Firebase service account JSON"
        case .alertWebhookURL: return "Alert webhook URL"
        }
    }
}

public struct CredentialStore: Sendable {
    private let keychain: Keychain

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    public func set(_ value: String, for key: CredentialKey) throws {
        try keychain.set(value, for: key.rawValue)
    }

    public func get(_ key: CredentialKey) throws -> String {
        try keychain.get(key.rawValue)
    }

    public func optional(_ key: CredentialKey) -> String? {
        try? keychain.get(key.rawValue)
    }

    public func contains(_ key: CredentialKey) -> Bool {
        keychain.contains(key.rawValue)
    }

    public func delete(_ key: CredentialKey) throws {
        try keychain.delete(key.rawValue)
    }

    /// Which credential groups are fully configured, for the settings UI.
    public func isConfigured(_ keys: [CredentialKey]) -> Bool {
        keys.allSatisfy { contains($0) }
    }
}
