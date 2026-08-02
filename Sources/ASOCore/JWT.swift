import Foundation
import CryptoKit

public enum JWTError: Error, LocalizedError {
    case invalidPrivateKey(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey(let detail):
            return "Could not read the .p8 private key: \(detail)"
        case .encodingFailed:
            return "Could not encode the JWT payload"
        }
    }
}

/// ES256 JSON Web Token signing for Apple's APIs.
///
/// Both App Store Connect and Search Ads use ES256 over a P-256 key from a .p8
/// file, but differ in claims: ASC signs a token used directly as the bearer,
/// Search Ads signs a client-credentials assertion exchanged for an access token.
public enum JWTSigner {

    /// Parses a PKCS#8 PEM .p8 file. Accepts the raw file contents including
    /// header/footer lines and surrounding whitespace, which is how the file
    /// arrives when a user drags it in or pastes it.
    public static func privateKey(fromPEM pem: String) throws -> P256.Signing.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: trimmed)
        } catch {
            // Some users paste only the base64 body without the PEM armour.
            let body = trimmed
                .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
                .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: body) else {
                throw JWTError.invalidPrivateKey(
                    "Expected a PKCS#8 PEM block beginning with -----BEGIN PRIVATE KEY-----")
            }
            do {
                return try P256.Signing.PrivateKey(derRepresentation: der)
            } catch {
                throw JWTError.invalidPrivateKey(String(describing: error))
            }
        }
    }

    /// Signs a token with the given header and claims.
    public static func sign(claims: [String: Any],
                            keyId: String,
                            privateKey: P256.Signing.PrivateKey,
                            extraHeader: [String: Any] = [:]) throws -> String {
        var header: [String: Any] = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        header.merge(extraHeader) { _, new in new }

        let headerSegment = try base64URLEncodedJSON(header)
        let claimsSegment = try base64URLEncodedJSON(claims)
        let signingInput = "\(headerSegment).\(claimsSegment)"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        // JWS requires the raw r‖s concatenation, not the DER encoding.
        let signatureSegment = base64URLEncode(signature.rawRepresentation)
        return "\(signingInput).\(signatureSegment)"
    }

    private static func base64URLEncodedJSON(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            throw JWTError.encodingFailed
        }
        return base64URLEncode(data)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Caches a signed token until shortly before it expires.
///
/// app-agent re-signs on every call site. Signing is cheap, but a fresh `iat`
/// on every request defeats Apple's own token reuse and makes the 20-minute
/// window meaningless, so we mint once and reuse.
public actor TokenCache {
    private var token: String?
    private var expiresAt: Date = .distantPast
    /// Renew early so a token cannot expire mid-flight on a slow request.
    private let safetyMargin: TimeInterval = 60

    public init() {}

    public func token(lifetime: TimeInterval, mint: () throws -> String) throws -> String {
        if let token, Date() < expiresAt.addingTimeInterval(-safetyMargin) {
            return token
        }
        let fresh = try mint()
        self.token = fresh
        self.expiresAt = Date().addingTimeInterval(lifetime)
        return fresh
    }

    /// Forces the next call to mint a new token, after a 401.
    public func invalidate() {
        token = nil
        expiresAt = .distantPast
    }
}
