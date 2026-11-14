// Checks a file's EdDSA signature against a public key, as an installed copy of Tilde checks an
// update before it installs it. scripts/release.sh runs it on the zip before anything is
// published.
//   swift scripts/verify-update.swift <public key> <file> <signature>
// The key and the signature are base64, as Sparkle's generate_keys and sign_update print them.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: swift scripts/verify-update.swift <public key> <file> <signature>", code: 2)
}
guard let keyData = Data(base64Encoded: arguments[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("The update key is not an EdDSA public key.", code: 2)
}
guard let signature = Data(base64Encoded: arguments[3]) else {
    fail("The signature is not base64.", code: 2)
}
guard let file = FileManager.default.contents(atPath: arguments[2]) else {
    fail("Could not read \(arguments[2]).", code: 2)
}
guard key.isValidSignature(signature, for: file) else {
    fail("The EdDSA signature of \(arguments[2]) is not valid for the update key \(arguments[1]).", code: 1)
}
print("The EdDSA signature of \(arguments[2]) is valid for the update key.")
