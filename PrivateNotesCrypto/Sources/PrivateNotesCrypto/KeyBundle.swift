import CryptoKit
import Foundation

/// Everything needed to recover the master key from the password or the recovery phrase.
/// Contains no secrets in the clear, so it is safe to store on disk and to sync.
public struct KeyBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Argon2id salt for the password.
    public var passwordSalt: Data
    /// Argon2id cost settings used for the password.
    public var kdf: KDFParameters
    /// Master key encrypted under the password-derived key.
    public var passwordWrappedKey: Data
    /// Master key encrypted under the recovery-phrase key.
    public var recoveryWrappedKey: Data

    private static let passwordContext = "PrivateNotes/v1/wrap/password"
    private static let recoveryContext = "PrivateNotes/v1/wrap/recovery"

    /// What first-time setup produces. Show `recoveryPhrase` to the user once, then discard it.
    public struct NewVault: Sendable {
        public let bundle: KeyBundle
        public let masterKey: MasterKey
        public let recoveryPhrase: RecoveryPhrase
    }

    /// First-time setup: makes a new master key and wraps it under the password and a new recovery phrase.
    public static func create(
        password: String,
        parameters: KDFParameters = .moderate
    ) throws -> NewVault {
        let masterKey = MasterKey.generate()
        let phrase = RecoveryPhrase.generate()
        let salt = PasswordKDF.randomSalt()
        let passwordKEK = try PasswordKDF.deriveKey(password: password, salt: salt, parameters: parameters)

        let bundle = KeyBundle(
            version: currentVersion,
            passwordSalt: salt,
            kdf: parameters,
            passwordWrappedKey: try KeyWrap.wrap(masterKey, with: passwordKEK, context: passwordContext),
            recoveryWrappedKey: try KeyWrap.wrap(masterKey, with: phrase.keyEncryptionKey(), context: recoveryContext)
        )
        return NewVault(bundle: bundle, masterKey: masterKey, recoveryPhrase: phrase)
    }

    /// Unlocks with the app password. Throws `wrongSecretOrCorruptKeyData` if it is wrong.
    public func unlock(password: String) throws -> MasterKey {
        try checkVersion()
        let kek = try PasswordKDF.deriveKey(password: password, salt: passwordSalt, parameters: kdf)
        return try KeyWrap.unwrap(passwordWrappedKey, with: kek, context: Self.passwordContext)
    }

    /// Unlocks with the recovery phrase. Throws `wrongSecretOrCorruptKeyData` if it is not this vault's phrase.
    public func unlock(recoveryPhrase: RecoveryPhrase) throws -> MasterKey {
        try checkVersion()
        return try KeyWrap.unwrap(
            recoveryWrappedKey,
            with: recoveryPhrase.keyEncryptionKey(),
            context: Self.recoveryContext
        )
    }

    /// Returns a bundle with a new password. Needs the unlocked master key; notes are not re-encrypted.
    /// The recovery phrase keeps working.
    public func changingPassword(
        to newPassword: String,
        masterKey: MasterKey,
        parameters: KDFParameters? = nil
    ) throws -> KeyBundle {
        try checkVersion()
        let newParameters = parameters ?? kdf
        let salt = PasswordKDF.randomSalt()
        let kek = try PasswordKDF.deriveKey(password: newPassword, salt: salt, parameters: newParameters)

        var updated = self
        updated.passwordSalt = salt
        updated.kdf = newParameters
        updated.passwordWrappedKey = try KeyWrap.wrap(masterKey, with: kek, context: Self.passwordContext)
        return updated
    }

    /// Returns a bundle with a new recovery phrase; the old phrase stops working. The password keeps working.
    public func replacingRecoveryPhrase(
        masterKey: MasterKey
    ) throws -> (bundle: KeyBundle, recoveryPhrase: RecoveryPhrase) {
        try checkVersion()
        let phrase = RecoveryPhrase.generate()
        var updated = self
        updated.recoveryWrappedKey = try KeyWrap.wrap(
            masterKey,
            with: phrase.keyEncryptionKey(),
            context: Self.recoveryContext
        )
        return (updated, phrase)
    }

    private func checkVersion() throws {
        guard version == Self.currentVersion else { throw CryptoError.unsupportedVersion(version) }
    }
}
