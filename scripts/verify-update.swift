import Foundation
import CryptoKit

// Verify against the shipped public key, not merely the signing tool's own key.
guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let publicData = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Invalid update signature input\n", stderr)
    exit(1)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Update signature does not match the app's SUPublicEDKey\n", stderr)
        exit(1)
    }
} catch {
    fputs("Unable to verify update signature\n", stderr)
    exit(1)
}
