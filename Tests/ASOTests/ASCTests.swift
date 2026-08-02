import XCTest
import Foundation
import CryptoKit
@testable import ASOCore
@testable import ASCKit

final class JWTTests: XCTestCase {

    /// A throwaway P-256 key in the same PKCS#8 PEM shape as an Apple .p8 file.
    private func samplePEM() -> String {
        P256.Signing.PrivateKey().pemRepresentation
    }

    func testParsesPKCS8PEM() throws {
        XCTAssertNoThrow(try JWTSigner.privateKey(fromPEM: samplePEM()))
    }

    func testParsesPEMWithSurroundingWhitespace() throws {
        let padded = "\n\n  " + samplePEM() + "  \n\n"
        XCTAssertNoThrow(try JWTSigner.privateKey(fromPEM: padded))
    }

    /// Users often paste just the base64 body out of the .p8 without the armour.
    func testParsesBareBase64Body() throws {
        let body = samplePEM()
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
        XCTAssertNoThrow(try JWTSigner.privateKey(fromPEM: body))
    }

    func testRejectsGarbageKey() {
        XCTAssertThrowsError(try JWTSigner.privateKey(fromPEM: "not a key"))
    }

    func testSignedTokenHasThreeSegmentsAndCorrectHeader() throws {
        let key = try JWTSigner.privateKey(fromPEM: samplePEM())
        let token = try JWTSigner.sign(
            claims: ["iss": "issuer", "aud": "appstoreconnect-v1"],
            keyId: "ABC123",
            privateKey: key)

        let segments = token.split(separator: ".")
        XCTAssertEqual(segments.count, 3)

        let header = try decodeSegment(String(segments[0]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "ABC123")
        XCTAssertEqual(header["typ"] as? String, "JWT")

        let claims = try decodeSegment(String(segments[1]))
        XCTAssertEqual(claims["aud"] as? String, "appstoreconnect-v1")
    }

    /// JWS requires the raw r‖s form (64 bytes for P-256), not DER. Getting this
    /// wrong produces a token Apple rejects with a generic 401.
    func testSignatureIsRawNotDER() throws {
        let key = try JWTSigner.privateKey(fromPEM: samplePEM())
        let token = try JWTSigner.sign(claims: ["iss": "x"], keyId: "K", privateKey: key)
        let signatureSegment = String(token.split(separator: ".")[2])
        let data = try XCTUnwrap(base64URLDecode(signatureSegment))
        XCTAssertEqual(data.count, 64, "ES256 signature must be 64 raw bytes")
    }

    /// The token must verify against the matching public key over "header.claims".
    func testSignatureVerifies() throws {
        let key = try JWTSigner.privateKey(fromPEM: samplePEM())
        let token = try JWTSigner.sign(claims: ["iss": "x"], keyId: "K", privateKey: key)
        let segments = token.split(separator: ".")
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let rawSignature = try XCTUnwrap(base64URLDecode(String(segments[2])))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: rawSignature)
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signingInput))
    }

    func testBase64URLHasNoPaddingOrUnsafeCharacters() throws {
        let key = try JWTSigner.privateKey(fromPEM: samplePEM())
        // Sign repeatedly: r/s values vary, so unsafe characters appear probabilistically.
        for _ in 0..<25 {
            let token = try JWTSigner.sign(claims: ["iss": UUID().uuidString],
                                           keyId: "K", privateKey: key)
            XCTAssertFalse(token.contains("="), "base64url must not be padded")
            XCTAssertFalse(token.contains("+"), "base64url must not contain +")
            XCTAssertFalse(token.contains("/"), "base64url must not contain /")
        }
    }

    // MARK: - Helpers

    private func decodeSegment(_ segment: String) throws -> [String: Any] {
        let data = try XCTUnwrap(base64URLDecode(segment))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

final class TokenCacheTests: XCTestCase {

    func testReusesTokenWithinLifetime() async throws {
        let cache = TokenCache()
        var mintCount = 0
        for _ in 0..<5 {
            _ = try await cache.token(lifetime: 1200) {
                mintCount += 1
                return "token-\(mintCount)"
            }
        }
        XCTAssertEqual(mintCount, 1, "token should be minted once and reused")
    }

    /// The 60s safety margin means a token with under a minute left is re-minted,
    /// so it cannot expire while a slow request is in flight.
    func testReMintsInsideSafetyMargin() async throws {
        let cache = TokenCache()
        var mintCount = 0
        _ = try await cache.token(lifetime: 30) { mintCount += 1; return "a" }
        _ = try await cache.token(lifetime: 30) { mintCount += 1; return "b" }
        XCTAssertEqual(mintCount, 2)
    }

    func testInvalidateForcesReMint() async throws {
        let cache = TokenCache()
        var mintCount = 0
        _ = try await cache.token(lifetime: 1200) { mintCount += 1; return "a" }
        await cache.invalidate()
        _ = try await cache.token(lifetime: 1200) { mintCount += 1; return "b" }
        XCTAssertEqual(mintCount, 2)
    }
}

final class MetadataDifferTests: XCTestCase {

    private func snapshot(locale: String = "en-US",
                          keywords: String = "migraine,headache",
                          name: String = "MigraineCast",
                          editableVersion: AppStoreVersion? = AppStoreVersion(
                            id: "v1", versionString: "2.0",
                            state: .prepareForSubmission, platform: "IOS")
    ) -> AppMetadataSnapshot {
        var entry = LocalizedMetadata(locale: locale,
                                      appInfoLocalizationId: "info-1",
                                      versionLocalizationId: "ver-1")
        entry[.name] = name
        entry[.subtitle] = "Track your triggers"
        entry[.keywords] = keywords
        entry[.description] = "A migraine tracker."
        return AppMetadataSnapshot(
            app: TrackedApp(id: "123", bundleId: "com.t.migrainecast", name: "MigraineCast"),
            editableVersion: editableVersion,
            appInfoId: "appinfo-1",
            metadata: [locale: entry])
    }

    func testNoDiffWhenUnchanged() {
        let remote = snapshot()
        let plan = MetadataDiffer.plan(remote: remote, local: remote.metadata)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.canPush)
    }

    /// Untouched fields must not appear as diffs, otherwise a pull-then-push
    /// would rewrite every field on the listing.
    func testUntouchedFieldsAreIgnored() {
        let remote = snapshot()
        var local = LocalizedMetadata(locale: "en-US",
                                      appInfoLocalizationId: "info-1",
                                      versionLocalizationId: "ver-1")
        local[.keywords] = "migraine,headache,relief"   // only field set
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])

        XCTAssertEqual(plan.diffs.count, 1)
        XCTAssertEqual(plan.diffs.first?.field, .keywords)
        XCTAssertEqual(plan.operations.count, 1)
    }

    /// Title and keywords live on different ASC objects and must become two
    /// separate writes, not one merged PATCH.
    func testSplitsAcrossAppInfoAndVersionContainers() {
        let remote = snapshot()
        var local = remote.metadata["en-US"]!
        local[.name] = "MigraineCast Pro"
        local[.keywords] = "migraine,aura,relief"
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])

        XCTAssertEqual(plan.operations.count, 2)
        let containers = Set(plan.operations.map(\.container))
        XCTAssertEqual(containers, [.appInfo, .version])
    }

    /// Multiple changed fields in the same container collapse into one request.
    func testGroupsSameContainerFieldsIntoOneOperation() {
        let remote = snapshot()
        var local = remote.metadata["en-US"]!
        local[.keywords] = "a,b,c"
        local[.description] = "Updated description."
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertEqual(plan.operations.first?.values.count, 2)
    }

    func testOverLongKeywordsBlocksPush() {
        let remote = snapshot()
        var local = remote.metadata["en-US"]!
        local[.keywords] = String(repeating: "a", count: 101)
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])

        XCTAssertFalse(plan.canPush)
        XCTAssertTrue(plan.blockers.contains { $0.contains("limit is 100") })
    }

    func testOverLongTitleBlocksPush() {
        let remote = snapshot()
        var local = remote.metadata["en-US"]!
        local[.name] = String(repeating: "x", count: 31)
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])
        XCTAssertFalse(plan.canPush)
    }

    func testExactLimitIsAllowed() {
        let remote = snapshot()
        var local = remote.metadata["en-US"]!
        local[.keywords] = String(repeating: "a", count: 100)
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])
        XCTAssertTrue(plan.canPush)
    }

    /// Without an editable version, keyword/description writes have nowhere to
    /// land. That must be caught before contacting Apple.
    func testVersionFieldWithoutEditableVersionIsBlocked() {
        let remote = snapshot(editableVersion: nil)
        var local = remote.metadata["en-US"]!
        local[.keywords] = "new,keywords"
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])

        XCTAssertFalse(plan.canPush)
        XCTAssertTrue(plan.blockers.contains { $0.contains("No editable version") })
    }

    /// Title/subtitle live on appInfo, so they stay pushable with no version in flight.
    func testAppInfoFieldWithoutEditableVersionIsAllowed() {
        let remote = snapshot(editableVersion: nil)
        var local = remote.metadata["en-US"]!
        local[.subtitle] = "New subtitle"
        let plan = MetadataDiffer.plan(remote: remote, local: ["en-US": local])
        XCTAssertTrue(plan.canPush, "appInfo fields do not require an editable version")
    }

    func testNewLocaleProducesCreateOperation() throws {
        let remote = snapshot()
        var dutch = LocalizedMetadata(locale: "nl-NL")   // no ids: does not exist yet
        dutch[.keywords] = "migraine,hoofdpijn"
        var local = remote.metadata
        local["nl-NL"] = dutch

        let plan = MetadataDiffer.plan(remote: remote, local: local)
        let operation = try XCTUnwrap(plan.operations.first { $0.locale == "nl-NL" })
        XCTAssertTrue(operation.isCreate)
    }

    func testMultipleLocalesEachGetOperations() {
        var remote = snapshot()
        var dutchRemote = LocalizedMetadata(locale: "nl-NL",
                                            appInfoLocalizationId: "info-2",
                                            versionLocalizationId: "ver-2")
        dutchRemote[.keywords] = "oud"
        remote.metadata["nl-NL"] = dutchRemote

        var english = remote.metadata["en-US"]!
        english[.keywords] = "new,en"
        var dutch = dutchRemote
        dutch[.keywords] = "nieuw,nl"

        let plan = MetadataDiffer.plan(remote: remote,
                                       local: ["en-US": english, "nl-NL": dutch])
        XCTAssertEqual(plan.operations.count, 2)
        XCTAssertEqual(Set(plan.operations.map(\.locale)), ["en-US", "nl-NL"])
    }
}

final class PushConfirmationTests: XCTestCase {

    private func samplePlan() -> PushPlan {
        PushPlan(appId: "1", appName: "MigraineCast", appInfoId: "info",
                 editableVersionId: "v1", editableVersionString: "2.0",
                 operations: [PushOperation(locale: "en-US", container: .version,
                                            localizationId: "ver-1",
                                            values: [.keywords: "a,b"])],
                 diffs: [MetadataDiff(locale: "en-US", field: .keywords,
                                      remote: "a", local: "a,b")])
    }

    func testPlansStartUnconfirmed() {
        XCTAssertFalse(samplePlan().isConfirmed)
    }

    func testConfirmedSetsFlag() {
        XCTAssertTrue(samplePlan().confirmed().isConfirmed)
    }

    /// The core safety property: an unconfirmed plan must be refused by the
    /// client rather than reaching App Store Connect.
    func testUnconfirmedPlanIsRejectedByClient() async throws {
        let key = P256.Signing.PrivateKey().pemRepresentation
        let client = try ASCClient(credentials: ASCCredentials(
            issuerId: "issuer", keyId: "key", privateKeyPEM: key))

        do {
            _ = try await client.push(samplePlan())
            XCTFail("push should refuse an unconfirmed plan")
        } catch let error as APIError {
            XCTAssertEqual(error.kind, .conflict)
            XCTAssertTrue(error.message.contains("unconfirmed"))
        }
    }

    func testReviewTextShowsBeforeAndAfter() {
        let text = samplePlan().reviewText
        XCTAssertTrue(text.contains("MigraineCast"))
        XCTAssertTrue(text.contains("- a"))
        XCTAssertTrue(text.contains("+ a,b"))
    }
}
