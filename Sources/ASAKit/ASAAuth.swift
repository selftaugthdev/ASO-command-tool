import Foundation
import CryptoKit
import ASOCore

/// Apple Search Ads API credentials.
///
/// Unlike App Store Connect, Search Ads does not accept a signed JWT as the
/// bearer directly. The JWT is a client-credentials *assertion* that is
/// exchanged at appleid.apple.com for a short-lived access token, and every
/// request additionally carries an `X-AP-Context` header naming the org.
public struct ASACredentials: Sendable {
    public var clientId: String
    public var teamId: String
    public var keyId: String
    public var privateKeyPEM: String
    public var orgId: String

    public init(clientId: String, teamId: String, keyId: String,
                privateKeyPEM: String, orgId: String) {
        self.clientId = clientId
        self.teamId = teamId
        self.keyId = keyId
        self.privateKeyPEM = privateKeyPEM
        self.orgId = orgId
    }

    public init(store: CredentialStore) throws {
        self.clientId = try store.get(.asaClientId)
        self.teamId = try store.get(.asaTeamId)
        self.keyId = try store.get(.asaKeyId)
        self.privateKeyPEM = try store.get(.asaPrivateKey)
        self.orgId = try store.get(.asaOrgId)
    }
}

struct ASATokenResponse: Decodable {
    var access_token: String
    var token_type: String
    var expires_in: Int
}

/// Obtains and caches Search Ads OAuth access tokens.
public actor ASATokenProvider {
    private let credentials: ASACredentials
    private let privateKey: P256.Signing.PrivateKey
    private let session: URLSession

    private var accessToken: String?
    private var expiresAt: Date = .distantPast

    /// Apple caps the client-secret assertion at 180 days; we only need minutes.
    private static let assertionLifetime: TimeInterval = 60 * 60

    public init(credentials: ASACredentials, session: URLSession = .shared) throws {
        self.credentials = credentials
        self.privateKey = try JWTSigner.privateKey(fromPEM: credentials.privateKeyPEM)
        self.session = session
    }

    /// The client secret assertion: signed with the team's private key, issued
    /// by the team, subject and audience fixed by Apple.
    private func clientSecret() throws -> String {
        let now = Date()
        let claims: [String: Any] = [
            "sub": credentials.clientId,
            "aud": "https://appleid.apple.com",
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.addingTimeInterval(Self.assertionLifetime).timeIntervalSince1970),
            "iss": credentials.teamId,
        ]
        // Search Ads requires the `alg`/`kid` header but no `typ`.
        return try JWTSigner.sign(claims: claims,
                                  keyId: credentials.keyId,
                                  privateKey: privateKey)
    }

    public func token() async throws -> String {
        if let accessToken, Date() < expiresAt.addingTimeInterval(-60) {
            return accessToken
        }

        var request = URLRequest(url: URL(string: "https://appleid.apple.com/auth/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: credentials.clientId),
            URLQueryItem(name: "client_secret", value: try clientSecret()),
            URLQueryItem(name: "scope", value: "searchadsorg"),
        ]
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport, message: "Non-HTTP response from Apple ID")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw APIError(
                kind: http.statusCode == 400 || http.statusCode == 401 ? .unauthorized
                                                                       : .server(status: http.statusCode),
                message: "Search Ads token exchange failed (\(http.statusCode)): \(body)")
        }

        let decoded = try JSONDecoder().decode(ASATokenResponse.self, from: data)
        accessToken = decoded.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        return decoded.access_token
    }

    public func invalidate() {
        accessToken = nil
        expiresAt = .distantPast
    }

    public var contextHeader: String { "orgId=\(credentials.orgId)" }
}
