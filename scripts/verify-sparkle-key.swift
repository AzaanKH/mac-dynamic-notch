import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(
    Data("usage: verify-sparkle-key.swift PUBLIC_KEY\n".utf8)
  )
  exit(64)
}

let expectedPublicKey = CommandLine.arguments[1]
let privateKeyText = String(
  data: FileHandle.standardInput.readDataToEndOfFile(),
  encoding: .utf8
)?.trimmingCharacters(in: .whitespacesAndNewlines)

guard
  let privateKeyText,
  let privateSeed = Data(base64Encoded: privateKeyText),
  privateSeed.count == 32
else {
  FileHandle.standardError.write(
    Data("error: Sparkle private key must be a base64-encoded 32-byte seed\n".utf8)
  )
  exit(65)
}

do {
  let privateKey = try Curve25519.Signing.PrivateKey(
    rawRepresentation: privateSeed
  )
  let actualPublicKey = privateKey.publicKey.rawRepresentation
    .base64EncodedString()

  guard actualPublicKey == expectedPublicKey else {
    FileHandle.standardError.write(
      Data("error: SPARKLE_PUBLIC_ED_KEY does not match SPARKLE_PRIVATE_KEY\n".utf8)
    )
    exit(66)
  }
} catch {
  FileHandle.standardError.write(
    Data("error: invalid Sparkle private key: \(error)\n".utf8)
  )
  exit(65)
}
