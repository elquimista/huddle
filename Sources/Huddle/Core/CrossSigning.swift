import CryptoKit
import Foundation

/// Checks the signatures of cross-signing, as the server hands out keys: that a key object was
/// signed by a given Ed25519 key. The server can say anything about who signed what; only a
/// signature that checks out against a key the app already trusts says it's so.
enum CrossSigning {
    /// The public key of a user's self-signing key, from the server's `self_signing_keys` entry,
    /// once its signature by the user's master key (one the app trusts) checks out.
    static func selfSigningKey(_ object: [String: Any], userID: String, masterKey: String) -> String? {
        guard object["user_id"] as? String == userID,
              (object["usage"] as? [String])?.contains("self_signing") == true,
              let keys = object["keys"] as? [String: String], keys.count == 1,
              let (keyID, key) = keys.first, keyID == "ed25519:\(key)",
              isSigned(object, by: masterKey, userID: userID) else { return nil }
        return key
    }

    /// Whether a device's keys, from the server's `device_keys`, were signed by the user's
    /// self-signing key: the device was verified from one of the user's trusted devices.
    static func isDeviceSigned(_ object: [String: Any], userID: String, deviceID: String, selfSigningKey: String) -> Bool {
        object["user_id"] as? String == userID && object["device_id"] as? String == deviceID
            && isSigned(object, by: selfSigningKey, userID: userID)
    }

    /// Whether `object` carries a valid signature by the Ed25519 key `key` (unpadded base64),
    /// made by `userID`, over its canonical JSON without its signatures and unsigned parts.
    static func isSigned(_ object: [String: Any], by key: String, userID: String) -> Bool {
        guard let keyData = Data(unpaddedBase64: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = ((object["signatures"] as? [String: Any])?[userID] as? [String: Any])?["ed25519:\(key)"] as? String,
              let signatureData = Data(unpaddedBase64: signature) else { return false }
        var signed = object
        signed["signatures"] = nil
        signed["unsigned"] = nil
        guard let message = CanonicalJSON.data(signed) else { return false }
        return publicKey.isValidSignature(signatureData, for: message)
    }
}

/// Matrix's canonical JSON of a value read with JSONSerialization: the exact bytes a signature
/// covers. Keys in code point order, no spaces, integers only, text as UTF-8 with only quotes,
/// backslashes and control characters escaped.
enum CanonicalJSON {
    static func data(_ value: Any) -> Data? {
        var text = ""
        guard write(value, to: &text) else { return nil }
        return Data(text.utf8)
    }

    private static func write(_ value: Any, to text: inout String) -> Bool {
        switch value {
        case let object as [String: Any]:
            text += "{"
            let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (index, key) in keys.enumerated() {
                if index > 0 { text += "," }
                write(string: key, to: &text)
                text += ":"
                guard let member = object[key], write(member, to: &text) else { return false }
            }
            text += "}"
        case let array as [Any]:
            text += "["
            for (index, element) in array.enumerated() {
                if index > 0 { text += "," }
                guard write(element, to: &text) else { return false }
            }
            text += "]"
        case let string as String:
            write(string: string, to: &text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                text += number.boolValue ? "true" : "false"
            } else if let integer = Int64(exactly: number) {
                text += String(integer)
            } else {
                return false   // canonical JSON has no fractions
            }
        case is NSNull:
            text += "null"
        default:
            return false
        }
        return true
    }

    private static func write(string: String, to text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case _ where scalar.value < 0x20: text += String(format: "\\u%04x", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }
}

extension Data {
    /// Matrix's unpadded base64, as keys and signatures are written.
    init?(unpaddedBase64 string: String) {
        let padding = (4 - string.count % 4) % 4
        self.init(base64Encoded: string + String(repeating: "=", count: padding))
    }
}
