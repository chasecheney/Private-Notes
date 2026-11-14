import Foundation

public enum CryptoError: Error, Equatable {
    /// Argon2id could not run (usually: not enough memory for the cost settings).
    case keyDerivationFailed
    /// Salt, cost settings, or password are not usable.
    case invalidParameters
    /// The password or recovery phrase did not unlock the key, or the stored key data is damaged.
    case wrongSecretOrCorruptKeyData
    /// The recovery phrase is not 24 valid words, or its checksum does not match.
    case invalidRecoveryPhrase
    /// The encrypted item could not be opened: wrong key, wrong item, or modified data.
    case decryptionFailed
    /// Data was written by a newer format than this code understands.
    case unsupportedVersion(Int)
}
