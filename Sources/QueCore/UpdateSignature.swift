// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import CryptoKit
import Foundation

/// The seal on every release: release.sh signs Que.zip with a private Ed25519 key that lives only in the owner's
/// Keychain (and their password manager) and uploads the signature as Que.zip.sig. The updater installs a zip only
/// if that signature matches this public key, so a release swapped on GitHub (or a taken-over account) can't
/// install anything. (Updates run in the OLD app: this protects updates made by 2.9.0 and later.)
public enum UpdateSignature {
    /// Base64 raw public key. Its private half: Keychain item "Que release signing key" (see scripts/release.sh).
    public static let publicKey = "cOX1vaxm8+Oehpkt6+9/0bDTcBq1McliKB7zXVKHExE="

    public static let assetName = "Que.zip.sig"

    /// True only when `signatureBase64` is a valid signature of `data` by `publicKeyBase64`.
    public static func isValid(_ data: Data, signatureBase64: String, publicKeyBase64: String = publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// The updater's gate: true only for a file whose seal matches. No seal, or an unreadable file, is refused.
    public static func isSealed(fileAt url: URL, signatureBase64: String?, publicKeyBase64: String = publicKey) -> Bool {
        guard let signature = signatureBase64, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return isValid(data, signatureBase64: signature, publicKeyBase64: publicKeyBase64)
    }

    /// Base64 signature of `data` (release.sh, via que-sign).
    public static func sign(_ data: Data, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CocoaError(.coderInvalidValue)
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: data).base64EncodedString()
    }
}
