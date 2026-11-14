import CryptoKit
import Foundation
import Sodium

/// Argon2id cost settings. Stored beside the wrapped key so they can be raised later.
public struct KDFParameters: Codable, Equatable, Sendable {
    /// Number of passes.
    public var opsLimit: Int
    /// Memory in bytes.
    public var memLimit: Int

    public init(opsLimit: Int, memLimit: Int) {
        self.opsLimit = opsLimit
        self.memLimit = memLimit
    }

    /// libsodium "moderate": the default for real vaults.
    public static var moderate: KDFParameters {
        let pw = Sodium().pwHash
        return KDFParameters(opsLimit: pw.OpsLimitModerate, memLimit: pw.MemLimitModerate)
    }

    /// libsodium "sensitive": slower and uses more memory.
    public static var sensitive: KDFParameters {
        let pw = Sodium().pwHash
        return KDFParameters(opsLimit: pw.OpsLimitSensitive, memLimit: pw.MemLimitSensitive)
    }
}

enum PasswordKDF {
    static var saltLength: Int { Sodium().pwHash.SaltBytes }

    static func randomSalt() -> Data {
        Data((0..<saltLength).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    /// Derives a 256-bit key-encryption key from the password with Argon2id.
    static func deriveKey(password: String, salt: Data, parameters: KDFParameters) throws -> SymmetricKey {
        let sodium = Sodium()
        guard !password.isEmpty,
              salt.count == sodium.pwHash.SaltBytes,
              parameters.opsLimit > 0,
              parameters.memLimit > 0
        else { throw CryptoError.invalidParameters }

        guard let derived = sodium.pwHash.hash(
            outputLength: 32,
            passwd: encodedPassword(password),
            salt: Array(salt),
            opsLimit: parameters.opsLimit,
            memLimit: parameters.memLimit,
            alg: .Argon2ID13
        ) else { throw CryptoError.keyDerivationFailed }

        return SymmetricKey(data: derived)
    }

    /// The password as fed to Argon2id: Unicode-normalized (NFC), UTF-8, then lowercase hex.
    ///
    /// Normalizing makes the same password typed on different keyboards produce the same key.
    /// Hex keeps every byte in the ASCII range: the Sodium wrapper converts password bytes to
    /// signed chars, which cannot represent bytes above 127 (any non-ASCII character).
    /// Hex is one-to-one, so no strength is lost.
    ///
    /// This encoding is part of the on-disk format. Changing it locks out existing vaults.
    static func encodedPassword(_ password: String) -> [UInt8] {
        let hexDigits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in password.precomposedStringWithCanonicalMapping.utf8 {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }
}
