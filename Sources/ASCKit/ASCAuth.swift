import Foundation
import CryptoKit
import ASOCore

/// App Store Connect API credentials, read from the Keychain.
public struct ASCCredentials: Sendable {
    public var issuerId: String
    public var keyId: String
    public var privateKeyPEM: String

    public init(issuerId: String, keyId: String, privateKeyPEM: String) {
        self.issuerId = issuerId
        self.keyId = keyId
        self.privateKeyPEM = privateKeyPEM
    }

    public init(store: CredentialStore) throws {
        self.issuerId = try store.get(.ascIssuerId)
        self.keyId = try store.get(.ascKeyId)
        self.privateKeyPEM = try store.get(.ascPrivateKey)
    }
}

/// Mints and caches App Store Connect bearer tokens.
public actor ASCTokenProvider {
    private let credentials: ASCCredentials
    private let cache = TokenCache()
    private let privateKey: P256.Signing.PrivateKey

    /// Apple rejects tokens with a lifetime over 20 minutes.
    private static let lifetime: TimeInterval = 20 * 60

    public init(credentials: ASCCredentials) throws {
        self.credentials = credentials
        self.privateKey = try JWTSigner.privateKey(fromPEM: credentials.privateKeyPEM)
    }

    public func bearerToken() async throws -> String {
        let issuerId = credentials.issuerId
        let keyId = credentials.keyId
        let key = privateKey
        return try await cache.token(lifetime: Self.lifetime) {
            let now = Date()
            let claims: [String: Any] = [
                "iss": issuerId,
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(Self.lifetime).timeIntervalSince1970),
                "aud": "appstoreconnect-v1",
            ]
            return try JWTSigner.sign(claims: claims, keyId: keyId, privateKey: key)
        }
    }

    public func invalidate() async {
        await cache.invalidate()
    }

    /// Signs a throwaway token to confirm the key parses and Apple accepts it.
    public func validate() async throws {
        _ = try await bearerToken()
    }
}
