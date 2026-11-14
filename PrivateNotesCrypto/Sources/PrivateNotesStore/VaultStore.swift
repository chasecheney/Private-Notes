import Foundation
import PrivateNotesCrypto

public enum VaultError: Error, Equatable {
    /// A vault already exists in this directory; refusing to overwrite it.
    case alreadyExists
    /// No vault has been set up in this directory yet.
    case notInitialized
}

/// A locked vault on disk: knows where it lives and how to set it up or unlock it.
///
/// Layout inside `directory`:
/// - `keybundle.json` — the wrapped master key (no secrets in the clear)
/// - `notes/<uuid>.pnote`, `folders/<uuid>.pnote` — one encrypted file per item
///
/// File names are random ids. Everything else about an item, including its title, dates,
/// and which folder it is in, is inside the encrypted file.
public struct VaultStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var keyBundleURL: URL {
        directory.appendingPathComponent("keybundle.json")
    }

    /// True once a vault has been created here.
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: keyBundleURL.path)
    }

    /// Result of first-time setup. Show the recovery phrase once, then let it go.
    public struct Created: Sendable {
        public let session: VaultSession
        public let recoveryPhrase: RecoveryPhrase
    }

    /// First-time setup. Slow on purpose (Argon2id): call off the main thread.
    public func createVault(password: String, parameters: KDFParameters = .moderate) throws -> Created {
        guard !isInitialized else { throw VaultError.alreadyExists }
        let new = try KeyBundle.create(password: password, parameters: parameters)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeKeyBundle(new.bundle)
        let session = VaultSession(directory: directory, masterKey: new.masterKey)
        try session.writeKeyCheck()
        return Created(session: session, recoveryPhrase: new.recoveryPhrase)
    }

    /// Slow on purpose (Argon2id): call off the main thread.
    public func unlock(password: String) throws -> VaultSession {
        let masterKey = try readKeyBundle().unlock(password: password)
        return try sessionEnsuringKeyCheck(masterKey)
    }

    /// Confirms the password is right without keeping anything unlocked.
    /// Slow on purpose (Argon2id): call off the main thread.
    public func verify(password: String) throws {
        _ = try readKeyBundle().unlock(password: password)
    }

    public func unlock(recoveryPhrase: RecoveryPhrase) throws -> VaultSession {
        let masterKey = try readKeyBundle().unlock(recoveryPhrase: recoveryPhrase)
        return try sessionEnsuringKeyCheck(masterKey)
    }

    /// Unlocks with a master key kept outside the vault (the Keychain copy behind Touch ID / Face ID).
    /// The key is checked against the vault before it is trusted.
    func unlock(rawMasterKey: Data) throws -> VaultSession {
        guard isInitialized else { throw VaultError.notInitialized }
        let session = VaultSession(directory: directory, masterKey: try MasterKey(rawBytes: rawMasterKey))
        guard session.keyCheckPasses() else { throw CryptoError.wrongSecretOrCorruptKeyData }
        return session
    }

    /// The key came from the password or recovery phrase, so it is right by construction.
    /// Vaults made before the key check existed get one here.
    private func sessionEnsuringKeyCheck(_ masterKey: MasterKey) throws -> VaultSession {
        let session = VaultSession(directory: directory, masterKey: masterKey)
        if !session.hasKeyCheck {
            try session.writeKeyCheck()
        }
        return session
    }

    // MARK: - Touch ID / Face ID

    /// "Touch ID", "Face ID", or nil when this device has no usable biometrics.
    public static var biometryName: String? { BiometricKeychain.biometryName }

    /// True when a biometric-protected copy of the key is stored. Does not prompt.
    public var hasBiometricKey: Bool { BiometricKeychain.exists }

    /// Stores a copy of the master key in the Keychain, readable only after a biometric match
    /// with the fingerprints or face enrolled right now, and never synced or backed up.
    public func enableBiometricUnlock(session: VaultSession) throws {
        try BiometricKeychain.store(session.masterKey.rawBytes())
    }

    public func disableBiometricUnlock() {
        BiometricKeychain.delete()
    }

    /// Shows the system biometric prompt and unlocks. Blocks until the user responds: call off the main thread.
    public func unlockWithBiometrics(reason: String) throws -> VaultSession {
        try unlock(rawMasterKey: try BiometricKeychain.read(reason: reason))
    }

    /// Sets a new password using an unlocked session. Notes are not re-encrypted and the
    /// recovery phrase keeps working. Slow on purpose: call off the main thread.
    public func changePassword(to newPassword: String, session: VaultSession) throws {
        let updated = try readKeyBundle().changingPassword(to: newPassword, masterKey: session.masterKey)
        try writeKeyBundle(updated)
    }

    private func readKeyBundle() throws -> KeyBundle {
        guard isInitialized else { throw VaultError.notInitialized }
        return try JSONDecoder().decode(KeyBundle.self, from: Data(contentsOf: keyBundleURL))
    }

    private func writeKeyBundle(_ bundle: KeyBundle) throws {
        try VaultFiles.write(try JSONEncoder().encode(bundle), to: keyBundleURL)
    }
}

enum VaultFiles {
    /// Writes the whole file or nothing, so a crash mid-save cannot leave a half-written item.
    static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}
