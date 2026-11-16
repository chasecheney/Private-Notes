import Foundation
import Observation
#if os(macOS)
import AppKit
#endif
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
    /// Lock after this long without keyboard or mouse activity.
    static let inactivityTimeout: TimeInterval = 5 * 60

    private(set) var phase: Phase
    private(set) var folders: [Folder] = []
    private(set) var notes: [Note] = []
    /// Files in the vault that could not be opened (damaged or foreign).
    private(set) var unreadableCount = 0
    /// True while a slow key operation is running.
    private(set) var isWorking = false
    var errorMessage: String?

    /// "Touch ID" / "Face ID", or nil when this device has none.
    private(set) var biometryName: String?
    /// True when the unlock screen can offer Touch ID / Face ID right now.
    private(set) var canUnlockWithBiometrics = false
    /// Why biometric unlock could not be turned on, if it couldn't.
    private(set) var biometricSetupProblem: String?
    /// The unlock screen prompts for biometrics by itself once, at launch.
    var shouldAutoPromptBiometrics = true

    /// User setting: offer Touch ID / Face ID to view notes.
    private(set) var biometricUnlockEnabled: Bool

    @ObservationIgnored private let store: VaultStore
    @ObservationIgnored private var session: VaultSession?
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    /// Decrypted images, kept only while unlocked.
    @ObservationIgnored private var imageCache: [UUID: PlatformImage] = [:]

    private static let biometricEnabledKey = "biometricUnlockEnabled"
    private static let passwordUnlockBootTimeKey = "passwordUnlockBootTime"

    init(store: VaultStore = VaultStore(directory: AppModel.defaultVaultDirectory)) {
        self.store = store
        self.phase = store.isInitialized ? .locked : .needsSetup
        self.biometricUnlockEnabled =
            UserDefaults.standard.object(forKey: Self.biometricEnabledKey) as? Bool ?? true
        self.biometryName = VaultStore.biometryName
        refreshBiometricAvailability()
        startInactivityTimer()
        observeSystemLockEvents()
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
            self.didUnlockWithPassword()
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
            self.didUnlockWithPassword()
            self.loadEverything()
            self.noteActivity()
            self.phase = .unlocked
        }
    }

    /// Shows the Touch ID / Face ID prompt. On failure the password field is still there.
    func unlockWithBiometrics() async {
        guard phase == .locked, canUnlockWithBiometrics else { return }
        let store = self.store
        let reason = "unlock your notes"
        await runKeyOperation {
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    try store.unlockWithBiometrics(reason: reason)
                }.value
                self.session = session
                self.loadEverything()
                self.noteActivity()
                self.phase = .unlocked
            } catch BiometricError.cancelled {
                // Dismissed: stay on the unlock screen without an error.
            } catch BiometricError.noStoredKey {
                self.refreshBiometricAvailability()
                self.errorMessage = "\(self.biometryName ?? "Biometric unlock") needs your password once, because the enrolled fingerprints or faces changed."
            } catch CryptoError.wrongSecretOrCorruptKeyData {
                // The stored key is not this vault's key. Drop it; the password sets it up again.
                store.disableBiometricUnlock()
                self.refreshBiometricAvailability()
                self.errorMessage = "Enter your password to unlock."
            }
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
            self.didUnlockWithPassword()
            self.loadEverything()
            self.noteActivity()
            self.phase = .unlocked
        }
    }

    /// Saves anything pending, then forgets the key and all decrypted content.
    /// Does nothing while the recovery phrase is on screen: it is shown only once.
    func lock() {
        guard phase == .unlocked || phase == .mustSetNewPassword else { return }
        flushPendingSaves()
        session = nil
        folders = []
        notes = []
        imageCache = [:]
        unreadableCount = 0
        errorMessage = nil
        phase = .locked
        refreshBiometricAvailability()
    }

    // MARK: - Touch ID / Face ID

    func setBiometricUnlockEnabled(_ enabled: Bool) {
        biometricUnlockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.biometricEnabledKey)
        applyBiometricSetting()
    }

    /// After any unlock that proved knowledge of the password or recovery phrase.
    private func didUnlockWithPassword() {
        UserDefaults.standard.set(Self.bootTime, forKey: Self.passwordUnlockBootTimeKey)
        applyBiometricSetting()
    }

    /// Stores or removes the biometric copy of the key to match the setting.
    private func applyBiometricSetting() {
        biometricSetupProblem = nil
        if biometricUnlockEnabled {
            if let session, biometryName != nil {
                do {
                    try store.enableBiometricUnlock(session: session)
                } catch BiometricError.keychain(let status) {
                    biometricSetupProblem = "The Keychain refused to store the key (error \(status))."
                } catch {
                    biometricSetupProblem = "\(biometryName ?? "Biometric unlock") isn't available right now."
                }
            }
        } else {
            store.disableBiometricUnlock()
        }
        refreshBiometricAvailability()
    }

    /// Biometrics are offered only when the device has them, the setting is on, a key is stored,
    /// and the password has been entered since the last restart.
    private func refreshBiometricAvailability() {
        biometryName = VaultStore.biometryName
        let storedBoot = UserDefaults.standard.double(forKey: Self.passwordUnlockBootTimeKey)
        let passwordUsedSinceRestart = storedBoot > 0 && abs(storedBoot - Self.bootTime) < 120
        canUnlockWithBiometrics =
            biometricUnlockEnabled && biometryName != nil && passwordUsedSinceRestart && store.hasBiometricKey
    }

    /// When this device last started, as seconds since 1970.
    private static var bootTime: TimeInterval {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &time, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(time.tv_sec)
    }

    // MARK: - Automatic locking

    /// Call on any sign the user is present. Resets the inactivity countdown.
    func noteActivity() {
        lastActivity = Date()
    }

    private func startInactivityTimer() {
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if self.phase == .unlocked,
                   Date().timeIntervalSince(self.lastActivity) >= Self.inactivityTimeout {
                    self.lock()
                }
            }
        }
    }

    private func observeSystemLockEvents() {
        #if os(macOS)
        // Keyboard and mouse use inside the app counts as activity.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity() }
            return event
        }

        // Sleep, display sleep, fast user switching, and the lock screen all lock the vault.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        #endif
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
            removeUnusedAttachments()
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

    /// The note's formatted content, for loading into the editor.
    func content(_ id: UUID) -> RichText {
        note(id)?.content ?? RichText(plainText: "")
    }

    /// The editor's content changed. Saved shortly after typing stops. Read-only notes don't change.
    func updateContent(_ id: UUID, _ content: RichText) {
        noteActivity()
        guard let index = notes.firstIndex(where: { $0.id == id }),
              !notes[index].isReadOnly,
              notes[index].richText != content
        else { return }
        notes[index].setContent(content)
        notes[index].modifiedAt = Date()
        scheduleSave(id)
    }

    // MARK: - Images

    /// Encrypts and stores an image (with its location data removed) and returns it ready to insert.
    func addImage(_ data: Data) -> (id: UUID, image: PlatformImage)? {
        guard let session else { return nil }
        guard let cleaned = ImageImport.strippingLocation(data), let image = PlatformImage(data: cleaned) else {
            errorMessage = "That isn't an image Private Notes can read."
            return nil
        }
        let id = UUID()
        do {
            try session.saveAttachment(id: id, data: cleaned)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
        imageCache[id] = image
        return (id, image)
    }

    /// A decrypted image for display, or nil if it is missing or damaged.
    func image(for id: UUID) -> PlatformImage? {
        if let cached = imageCache[id] { return cached }
        guard let session,
              let data = try? session.loadAttachment(id: id),
              let image = PlatformImage(data: data)
        else { return nil }
        imageCache[id] = image
        return image
    }

    /// Deletes image files no note uses any more. Runs at unlock, when there is no undo history
    /// that could bring a removed image back. Skipped if any note failed to open, since an
    /// unreadable note may still need its images.
    private func removeUnusedAttachments() {
        guard let session, unreadableCount == 0, let stored = try? session.attachmentIDs() else { return }
        let used = Set(notes.flatMap { $0.richText?.attachmentIDs ?? [] })
        for id in stored where !used.contains(id) {
            try? session.deleteAttachment(id: id)
        }
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

    /// Protects a note against accidental edits and deletion. No password needed to turn on.
    func makeReadOnly(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly else { return }
        notes[index].isReadOnly = true
        saveNow(id)
    }

    /// Makes a read-only note editable again, if the password is right. Returns whether it was.
    func unlockForEditing(_ id: UUID, password: String) async -> Bool {
        let store = self.store
        var succeeded = false
        await runKeyOperation {
            try await Task.detached(priority: .userInitiated) {
                try store.verify(password: password)
            }.value
            guard let index = self.notes.firstIndex(where: { $0.id == id }) else { return }
            self.notes[index].isReadOnly = false
            self.saveNow(id)
            succeeded = true
        }
        // The prompt shows its own message; keep the app-wide error alert out of it.
        errorMessage = nil
        return succeeded
    }

    /// Read-only notes can't be deleted; make them editable first.
    func deleteNote(_ id: UUID) {
        guard note(id)?.isReadOnly != true else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        let images = note(id)?.richText?.attachmentIDs ?? []
        notes.removeAll { $0.id == id }
        perform { session in
            try session.deleteNote(id: id)
            for image in images {
                try session.deleteAttachment(id: image)
            }
        }
        for image in images {
            imageCache[image] = nil
        }
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
            return "That's not right. Check it and try again."
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
        case BiometricError.unavailable:
            return "Biometric unlock isn't available on this device."
        case BiometricError.keychain(let status):
            return "The Keychain reported an error (\(status)). Use your password."
        default:
            return error.localizedDescription
        }
    }
}
