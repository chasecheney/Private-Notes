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
        return Created(
            session: VaultSession(directory: directory, masterKey: new.masterKey),
            recoveryPhrase: new.recoveryPhrase
        )
    }

    /// Slow on purpose (Argon2id): call off the main thread.
    public func unlock(password: String) throws -> VaultSession {
        let masterKey = try readKeyBundle().unlock(password: password)
        return VaultSession(directory: directory, masterKey: masterKey)
    }

    public func unlock(recoveryPhrase: RecoveryPhrase) throws -> VaultSession {
        let masterKey = try readKeyBundle().unlock(recoveryPhrase: recoveryPhrase)
        return VaultSession(directory: directory, masterKey: masterKey)
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
