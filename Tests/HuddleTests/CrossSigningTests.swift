import CryptoKit
import XCTest
@testable import Huddle

/// Checking cross-signing signatures (CrossSigning.swift): a device shows as verified only when
/// its keys are signed by its owner's self-signing key, itself signed by their master key.
final class CrossSigningTests: XCTestCase {
    private let userID = "@alice:example.org"

    private func unpadded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Signs `object` as Matrix does: over its canonical JSON, without signatures or unsigned.
    private func signed(_ object: [String: Any], by key: Curve25519.Signing.PrivateKey) throws -> [String: Any] {
        var bare = object
        bare["signatures"] = nil
        bare["unsigned"] = nil
        let message = try XCTUnwrap(CanonicalJSON.data(bare))
        let signature = unpadded(try key.signature(for: message))
        let keyName = "ed25519:\(unpadded(key.publicKey.rawRepresentation))"
        var result = object
        var signatures = result["signatures"] as? [String: [String: String]] ?? [:]
        signatures[userID, default: [:]][keyName] = signature
        result["signatures"] = signatures
        return result
    }

    /// Through JSON and back, as the server's answer is read.
    private func asReceived(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func keyObject(_ key: Curve25519.Signing.PrivateKey) -> [String: Any] {
        let id = unpadded(key.publicKey.rawRepresentation)
        return ["user_id": userID, "usage": ["self_signing"], "keys": ["ed25519:\(id)": id]]
    }

    func testAProperChainIsTrusted() throws {
        let master = Curve25519.Signing.PrivateKey()
        let selfSigning = Curve25519.Signing.PrivateKey()
        let masterID = unpadded(master.publicKey.rawRepresentation)
        let selfSigningObject = try asReceived(signed(keyObject(selfSigning), by: master))
        let found = CrossSigning.selfSigningKey(selfSigningObject, userID: userID, masterKey: masterID)
        XCTAssertEqual(found, unpadded(selfSigning.publicKey.rawRepresentation))

        let device: [String: Any] = ["user_id": userID, "device_id": "PHONE", "algorithms": ["m.olm.v1.curve25519-aes-sha2"],
                                     "keys": ["ed25519:PHONE": "abc", "curve25519:PHONE": "def"],
                                     "unsigned": ["device_display_name": "Alice's phone"]]
        let signedDevice = try asReceived(signed(device, by: selfSigning))
        XCTAssertTrue(CrossSigning.isDeviceSigned(signedDevice, userID: userID, deviceID: "PHONE", selfSigningKey: try XCTUnwrap(found)))
    }

    func testASelfSigningKeyNotSignedByTheMasterKeyIsNot() throws {
        let master = Curve25519.Signing.PrivateKey()
        let impostor = Curve25519.Signing.PrivateKey()
        let selfSigning = Curve25519.Signing.PrivateKey()
        // Signed, but by a key the server made up.
        let forged = try asReceived(signed(keyObject(selfSigning), by: impostor))
        XCTAssertNil(CrossSigning.selfSigningKey(forged, userID: userID, masterKey: unpadded(master.publicKey.rawRepresentation)))
    }

    /// The server's own key signing, with the signature filed under the master key's name.
    func testASignatureUnderTheMasterKeysNameButNotByItIsNot() throws {
        let master = Curve25519.Signing.PrivateKey()
        let masterID = unpadded(master.publicKey.rawRepresentation)
        let impostor = Curve25519.Signing.PrivateKey()
        let selfSigning = Curve25519.Signing.PrivateKey()
        var forged = try signed(keyObject(selfSigning), by: impostor)
        var signatures = try XCTUnwrap(forged["signatures"] as? [String: [String: String]])
        let signature = try XCTUnwrap(signatures[userID]?.values.first)
        signatures[userID] = ["ed25519:\(masterID)": signature]
        forged["signatures"] = signatures
        XCTAssertNil(CrossSigning.selfSigningKey(try asReceived(forged), userID: userID, masterKey: masterID))
    }

    func testADeviceChangedAfterSigningIsNotSigned() throws {
        let selfSigning = Curve25519.Signing.PrivateKey()
        let ssk = unpadded(selfSigning.publicKey.rawRepresentation)
        var device = try signed(["user_id": userID, "device_id": "PHONE", "keys": ["ed25519:PHONE": "abc"]], by: selfSigning)
        device["keys"] = ["ed25519:PHONE": "the server's own key"]
        XCTAssertFalse(CrossSigning.isDeviceSigned(try asReceived(device), userID: userID, deviceID: "PHONE", selfSigningKey: ssk))
    }

    func testADeviceOfSomeoneElseOrAnotherIDIsNot() throws {
        let selfSigning = Curve25519.Signing.PrivateKey()
        let ssk = unpadded(selfSigning.publicKey.rawRepresentation)
        let device = try asReceived(signed(["user_id": userID, "device_id": "PHONE", "keys": [:] as [String: String]], by: selfSigning))
        XCTAssertFalse(CrossSigning.isDeviceSigned(device, userID: userID, deviceID: "LAPTOP", selfSigningKey: ssk))
        XCTAssertFalse(CrossSigning.isDeviceSigned(device, userID: "@mallory:example.org", deviceID: "PHONE", selfSigningKey: ssk))
    }

    func testWhatsUnsignedCanChange() throws {
        let selfSigning = Curve25519.Signing.PrivateKey()
        var device = try signed(["user_id": userID, "device_id": "PHONE", "keys": ["ed25519:PHONE": "abc"]], by: selfSigning)
        device["unsigned"] = ["device_display_name": "renamed later"]
        XCTAssertTrue(CrossSigning.isDeviceSigned(try asReceived(device), userID: userID, deviceID: "PHONE",
                                                  selfSigningKey: unpadded(selfSigning.publicKey.rawRepresentation)))
    }

    /// The examples in the Matrix specification's appendix on canonical JSON.
    func testCanonicalJSONMatchesTheSpecification() throws {
        let cases: [(String, String)] = [
            (#"{}"#, #"{}"#),
            (#"{"one": 1, "two": "Two"}"#, #"{"one":1,"two":"Two"}"#),
            (#"{"b": "2", "a": "1"}"#, #"{"a":"1","b":"2"}"#),
            (#"{"auth": {"success": true, "mxid": "@john.doe:example.com", "profile": {"display_name": "John Doe", "three_pids": [{"medium": "email", "address": "john.doe@example.org"}, {"medium": "msisdn", "address": "123456789"}]}}}"#,
             #"{"auth":{"mxid":"@john.doe:example.com","profile":{"display_name":"John Doe","three_pids":[{"address":"john.doe@example.org","medium":"email"},{"address":"123456789","medium":"msisdn"}]},"success":true}}"#),
            (#"{"a": "日本語"}"#, #"{"a":"日本語"}"#),
            (#"{"本": 2, "日": 1}"#, #"{"日":1,"本":2}"#),
            (#"{"a": "日"}"#, #"{"a":"日"}"#),
            (#"{"a": null}"#, #"{"a":null}"#),
        ]
        for (input, expected) in cases {
            let value = try JSONSerialization.jsonObject(with: Data(input.utf8), options: .fragmentsAllowed)
            let canonical = try XCTUnwrap(CanonicalJSON.data(value), input)
            XCTAssertEqual(String(decoding: canonical, as: UTF8.self), expected, input)
        }
    }

    func testUnpaddedBase64() {
        XCTAssertEqual(Data(unpaddedBase64: "YQ"), Data("a".utf8))
        XCTAssertEqual(Data(unpaddedBase64: "YWI"), Data("ab".utf8))
        XCTAssertEqual(Data(unpaddedBase64: "YWJj"), Data("abc".utf8))
        XCTAssertNil(Data(unpaddedBase64: "not base64!"))
    }
}
