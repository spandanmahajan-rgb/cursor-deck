// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

// Release signing helper (see UpdateSignature). The private key is read from QUE_SIGNING_KEY (base64), never argv.
//   que-sign new-key        prints a new private key (base64): store it, don't show it
//   que-sign public-key     prints the public key of QUE_SIGNING_KEY
//   que-sign sign <file>    prints the signature of <file>
//   que-sign verify <file> <signature-file>   exits 0 only if it matches UpdateSignature.publicKey

import CryptoKit
import Foundation
import QueCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKey() -> String {
    guard let key = ProcessInfo.processInfo.environment["QUE_SIGNING_KEY"], !key.isEmpty else { fail("QUE_SIGNING_KEY is not set") }
    return key
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "new-key":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public-key":
    guard let data = Data(base64Encoded: privateKey()),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("QUE_SIGNING_KEY is not a valid key") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 3:
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("Can't read \(args[2])") }
    do { print(try UpdateSignature.sign(data, privateKeyBase64: privateKey())) } catch { fail("Signing failed: \(error)") }
case "verify" where args.count == 4:
    guard let data = FileManager.default.contents(atPath: args[2]),
          let signature = try? String(contentsOfFile: args[3], encoding: .utf8) else { fail("Can't read the files") }
    guard UpdateSignature.isValid(data, signatureBase64: signature) else { fail("Signature does NOT match Que's public key") }
    print("Signature OK")
default:
    fail("Usage: que-sign new-key | public-key | sign <file> | verify <file> <signature-file>")
}
