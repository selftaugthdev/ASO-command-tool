import Foundation
import Security
import ASOCore

/// A Google service account key file.
public struct ServiceAccount: Decodable, Sendable {
    public var project_id: String
    public var private_key: String
    public var private_key_id: String
    public var client_email: String
    public var token_uri: String?

    public static func load(json: String) throws -> ServiceAccount {
        guard let data = json.data(using: .utf8) else {
            throw APIError(kind: .decoding, message: "Service account JSON is not valid UTF-8")
        }
        return try JSONDecoder().decode(ServiceAccount.self, from: data)
    }
}

/// RS256 signing for Google service accounts.
///
/// Google requires RS256, which CryptoKit does not provide, so this drops to
/// the Security framework. Apple's own APIs use ES256 and are handled by
/// `JWTSigner` in ASOCore instead.
enum RSASigner {

    static func privateKey(fromPEM pem: String) throws -> SecKey {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .filter { !$0.isWhitespace }

        guard let der = Data(base64Encoded: body) else {
            throw APIError(kind: .decoding, message: "Service account private_key is not base64")
        }

        // Service account keys are PKCS#8. SecKeyCreateWithData wants a bare
        // PKCS#1 RSAPrivateKey, so strip the PKCS#8 wrapper when present.
        let pkcs1 = stripPKCS8Header(der) ?? der

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData,
                                             attributes as CFDictionary,
                                             &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw APIError(kind: .decoding, message: "Could not parse service account key: \(message)")
        }
        return key
    }

    /// PKCS#8 wraps the PKCS#1 key in: SEQUENCE { INTEGER 0, SEQUENCE { OID, NULL },
    /// OCTET STRING { <PKCS#1> } }. Walk that structure to the octet string.
    private static func stripPKCS8Header(_ der: Data) -> Data? {
        var index = 0
        let bytes = [UInt8](der)

        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]; index += 1
            if first & 0x80 == 0 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            return length
        }

        guard index < bytes.count, bytes[index] == 0x30 else { return nil }  // SEQUENCE
        index += 1
        guard readLength() != nil else { return nil }

        guard index < bytes.count, bytes[index] == 0x02 else { return nil }  // INTEGER version
        index += 1
        guard let versionLength = readLength() else { return nil }
        index += versionLength

        guard index < bytes.count, bytes[index] == 0x30 else { return nil }  // AlgorithmIdentifier
        index += 1
        guard let algorithmLength = readLength() else { return nil }
        index += algorithmLength

        guard index < bytes.count, bytes[index] == 0x04 else { return nil }  // OCTET STRING
        index += 1
        guard let keyLength = readLength(), index + keyLength <= bytes.count else { return nil }

        return Data(bytes[index..<(index + keyLength)])
    }

    static func sign(_ message: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data? else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw APIError(kind: .transport, message: "RS256 signing failed: \(detail)")
        }
        return signature
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Reads documents from Firestore over its REST API.
///
/// Uses REST rather than the Firebase SDK so the app stays a dependency-free
/// SwiftPM package; the SDK would pull in a large CocoaPods/xcframework tree
/// for what amounts to a handful of authenticated GETs.
public final class FirestoreClient: @unchecked Sendable {
    private let account: ServiceAccount
    private let privateKey: SecKey
    private let http: HTTPClient
    private let session = URLSession.shared

    /// Token state lives in an actor: an NSLock cannot be held across the
    /// `await` on the token exchange.
    private actor TokenState {
        private var token: String?
        private var expiresAt: Date = .distantPast

        func cached() -> String? {
            guard let token, Date() < expiresAt.addingTimeInterval(-60) else { return nil }
            return token
        }

        func store(_ token: String, lifetime: TimeInterval) {
            self.token = token
            self.expiresAt = Date().addingTimeInterval(lifetime)
        }
    }
    private let tokenState = TokenState()

    public init(account: ServiceAccount, http: HTTPClient? = nil) throws {
        self.account = account
        self.privateKey = try RSASigner.privateKey(fromPEM: account.private_key)
        self.http = http ?? HTTPClient()
    }

    public convenience init(serviceAccountJSON: String, http: HTTPClient? = nil) throws {
        try self.init(account: ServiceAccount.load(json: serviceAccountJSON), http: http)
    }

    private func token() async throws -> String {
        if let cached = await tokenState.cached() { return cached }

        let now = Date()
        let header = ["alg": "RS256", "typ": "JWT", "kid": account.private_key_id]
        let claims: [String: Any] = [
            "iss": account.client_email,
            "scope": "https://www.googleapis.com/auth/datastore",
            "aud": account.token_uri ?? "https://oauth2.googleapis.com/token",
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.addingTimeInterval(3600).timeIntervalSince1970),
        ]

        let headerSegment = RSASigner.base64URL(
            try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let claimsSegment = RSASigner.base64URL(
            try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let signingInput = "\(headerSegment).\(claimsSegment)"
        let signature = try RSASigner.sign(Data(signingInput.utf8), with: privateKey)
        let assertion = "\(signingInput).\(RSASigner.base64URL(signature))"

        var request = URLRequest(url: URL(string: account.token_uri
                                          ?? "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            URLQueryItem(name: "assertion", value: assertion),
        ]
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }

        struct TokenResponse: Decodable { var access_token: String; var expires_in: Int }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw APIError(kind: .unauthorized, message: "Google token exchange failed: \(body)")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        await tokenState.store(decoded.access_token,
                               lifetime: TimeInterval(decoded.expires_in))
        return decoded.access_token
    }

    /// Runs a structured query against one collection, following pagination.
    public func query(collection: String,
                      whereFieldGreaterThan field: String? = nil,
                      timestamp: Date? = nil,
                      limit: Int = 1000) async throws -> [[String: FirestoreValue]] {
        var structured: [String: Any] = [
            "from": [["collectionId": collection]],
            "limit": limit,
            "orderBy": [["field": ["fieldPath": field ?? "occurredAt"],
                         "direction": "ASCENDING"]],
        ]
        if let field, let timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            structured["where"] = [
                "fieldFilter": [
                    "field": ["fieldPath": field],
                    "op": "GREATER_THAN",
                    "value": ["timestampValue": formatter.string(from: timestamp)],
                ],
            ]
        }

        let url = URL(string: "https://firestore.googleapis.com/v1/projects/"
                    + "\(account.project_id)/databases/(default)/documents:runQuery")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["structuredQuery": structured])

        let data = try await http.send(request)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let document = row["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any] else { return nil }
            return fields.compactMapValues(FirestoreValue.init(json:))
        }
    }
}

/// A decoded Firestore field value.
public enum FirestoreValue: Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case timestamp(Date)
    case null

    init?(json: Any) {
        guard let dictionary = json as? [String: Any] else { return nil }
        if let value = dictionary["stringValue"] as? String { self = .string(value) }
        else if let value = dictionary["integerValue"] as? String,
                let parsed = Int64(value) { self = .integer(parsed) }
        else if let value = dictionary["integerValue"] as? Int64 { self = .integer(value) }
        else if let value = dictionary["doubleValue"] as? Double { self = .double(value) }
        else if let value = dictionary["booleanValue"] as? Bool { self = .boolean(value) }
        else if let value = dictionary["timestampValue"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: value) ?? {
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: value)
            }()
            guard let date else { return nil }
            self = .timestamp(date)
        }
        else if dictionary["nullValue"] != nil { self = .null }
        else { return nil }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return String(value)
        case .timestamp, .null: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var dateValue: Date? {
        switch self {
        case .timestamp(let value): return value
        case .integer(let value): return Date(timeIntervalSince1970: TimeInterval(value))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .boolean(let value): return value
        case .integer(let value): return value != 0
        default: return nil
        }
    }
}
