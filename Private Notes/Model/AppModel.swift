import Foundation
import Observation
import PrivateNotesCrypto
import PrivateNotesStore

/// Which folder the note list is showing.
enum FolderSelection: Hashable {
    case allNotes
    case folder(UUID)
}

/// App state: whether the vault is set up and unlocked, and the decrypted notes while it is.
/// Decrypted content lives only here, in memory, and is dropped on lock.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// No vault yet: ask for a password.
        case needsSetup
        /// Vault just created: show the recovery phrase once.
        case showingRecoveryPhrase([String])
        case locked
        /// Unlocked with the recovery phrase: a new password must be set before continuing.
        case mustSetNewPassword
        case unlocked
    }

    static let minimumPasswordLength = 10

    private(set) var phase: Phase
    private(set) var folders: [Folder] = []
    private(set) var notes: [Note] = []
    /// Files in the vault that could not be opened (damaged or foreign).
    private(set) var unreadableCount = 0
    /// True while a slow key operation is running.
    private(set) var isWorking = false
    var errorMessage: String?

    @ObservationIgnored private let store: VaultStore
    @ObservationIgnored private var session: VaultSession?
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]

    init(store: VaultStore = VaultStore(directory: AppModel.defaultVaultDirectory)) {
        self.store = store
        self.phase = store.isInitialized ? .locked : .needsSetup
    }

    nonisolated static var defaultVaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.chasecheney.privatenotes", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
    }

    // MARK: - Setup, unlock, lock

    func createVault(password: String) async {
        let store = self.store
        await runKeyOperation {
            let created = try await Task.detached(priority: .userInitiated) {
                try store.createVault(password: password)
            }.value
            self.session = created.session
            self.phase = .showingRecoveryPhrase(created.recoveryPhrase.words)
        }
    }

    /// Called once the user confirms they wrote the recovery phrase down.
    func finishSetup() {
        guard case .showingRecoveryPhrase = phase else { return }
        loadEverything()
        phase = .unlocked
    }

    func unlock(password: String) async {
        let store = self.store
        await runKeyOperation {
            let session = try await Task.detached(priority: .userInitiated) {
                try store.unlock(password: password)
            }.value
            self.session = session
            self.loadEverything()
            self.phase = .unlocked
        }
    }

    func unlock(recoveryPhraseText: String) async {
        let store = self.store
        await runKeyOperation {
            let phrase = try RecoveryPhrase(phrase: recoveryPhraseText)
            self.session = try store.unlock(recoveryPhrase: phrase)
            self.phase = .mustSetNewPassword
        }
    }

    func setNewPassword(_ password: String) async {
        guard let session else { return }
        let store = self.store
        await runKeyOperation {
            try await Task.detached(priority: .userInitiated) {
                try store.changePassword(to: password, session: session)
            }.value
            self.loadEverything()
            self.phase = .unlocked
        }
    }

    /// Saves anything pending, then forgets the key and all decrypted content.
    func lock() {
        flushPendingSaves()
        session = nil
        folders = []
        notes = []
        unreadableCount = 0
        errorMessage = nil
        if store.isInitialized {
            phase = .locked
        } else {
            phase = .needsSetup
        }
    }

    private func runKeyOperation(_ work: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = Self.describe(error)
        }
        isWorking = false
    }

    private func loadEverything() {
        guard let session else { return }
        do {
            let loadedFolders = try session.loadFolders()
            let loadedNotes = try session.loadNotes()
            folders = loadedFolders.items
            notes = loadedNotes.items
            unreadableCount = loadedFolders.unreadableCount + loadedNotes.unreadableCount
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Reading

    var sortedFolders: [Folder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func note(_ id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func folderName(_ selection: FolderSelection) -> String {
        switch selection {
        case .allNotes:
            return "All Notes"
        case .folder(let id):
            return folders.first { $0.id == id }?.name ?? "Notes"
        }
    }

    /// Notes for the list: pinned first, then most recently changed. Search matches anywhere in the text.
    func notes(in selection: FolderSelection, matching search: String) -> [Note] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes
            .filter { note in
                switch selection {
                case .allNotes: return true
                case .folder(let id): return note.folderID == id
                }
            }
            .filter { query.isEmpty || $0.body.localizedCaseInsensitiveContains(query) }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.modifiedAt > $1.modifiedAt
            }
    }

    // MARK: - Notes

    @discardableResult
    func addNote(in selection: FolderSelection) -> UUID {
        var folderID: UUID?
        if case .folder(let id) = selection { folderID = id }
        let note = Note(folderID: folderID)
        notes.append(note)
        saveNow(note.id)
        return note.id
    }

    /// Text changed in the editor. Saved shortly after typing stops.
    func updateBody(_ id: UUID, _ body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index].body = body
        notes[index].modifiedAt = Date()
        scheduleSave(id)
    }

    func togglePinned(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        saveNow(id)
    }

    func moveNote(_ id: UUID, toFolder folderID: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].folderID != folderID else { return }
        notes[index].folderID = folderID
        saveNow(id)
    }

    func deleteNote(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        notes.removeAll { $0.id == id }
        perform { try $0.deleteNote(id: id) }
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(named name: String) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = Folder(name: trimmed)
        folders.append(folder)
        perform { try $0.save(folder) }
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        let folder = folders[index]
        perform { try $0.save(folder) }
    }

    /// Deletes the folder only. Its notes are kept and show up under All Notes.
    func deleteFolder(_ id: UUID) {
        for index in notes.indices where notes[index].folderID == id {
            notes[index].folderID = nil
            saveNow(notes[index].id)
        }
        folders.removeAll { $0.id == id }
        perform { try $0.deleteFolder(id: id) }
    }

    // MARK: - Saving

    private func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow(id)
        }
    }

    private func saveNow(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        guard let note = note(id) else { return }
        perform { try $0.save(note) }
    }

    /// Writes any edits still waiting on the typing delay. Call before locking or going to the background.
    func flushPendingSaves() {
        for id in Array(saveTasks.keys) {
            saveNow(id)
        }
    }

    private func perform(_ work: (VaultSession) throws -> Void) {
        guard let session else { return }
        do {
            try work(session)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Errors

    static func describe(_ error: Error) -> String {
        switch error {
        case CryptoError.wrongSecretOrCorruptKeyData:
            return "That didn't unlock the vault. Check it and try again."
        case CryptoError.invalidRecoveryPhrase:
            return "That isn't a valid recovery phrase. It should be 24 words; check the spelling of each."
        case CryptoError.keyDerivationFailed:
            return "Couldn't process the password. The device may be low on memory; close other apps and try again."
        case CryptoError.invalidParameters:
            return "Enter a password."
        case CryptoError.unsupportedVersion:
            return "This vault was made by a newer version of Private Notes."
        case VaultError.alreadyExists:
            return "A vault already exists on this device."
        case VaultError.notInitialized:
            return "No vault has been set up yet."
        default:
            return error.localizedDescription
        }
    }
}
