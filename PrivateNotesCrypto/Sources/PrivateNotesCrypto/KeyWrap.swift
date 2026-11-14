import CryptoKit
import Foundation

/// Encrypts the master key under a key-encryption key (from the password or the recovery phrase).
enum KeyWrap {
    static func wrap(_ masterKey: MasterKey, with kek: SymmetricKey, context: String) throws -> Data {
        let box = try ChaChaPoly.seal(
            masterKey.rawBytes(),
            using: kek,
            authenticating: Data(context.utf8)
        )
        return box.combined
    }

    static func unwrap(_ wrapped: Data, with kek: SymmetricKey, context: String) throws -> MasterKey {
        do {
            let box = try ChaChaPoly.SealedBox(combined: wrapped)
            let raw = try ChaChaPoly.open(box, using: kek, authenticating: Data(context.utf8))
            return try MasterKey(rawBytes: raw)
        } catch {
            throw CryptoError.wrongSecretOrCorruptKeyData
        }
    }
}
