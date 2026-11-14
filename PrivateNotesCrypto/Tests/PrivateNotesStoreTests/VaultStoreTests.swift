import XCTest
import PrivateNotesCrypto
@testable import PrivateNotesStore

/// Small Argon2id settings so the tests run quickly. Real vaults use `.moderate`.
private let testKDF = KDFParameters(opsLimit: 2, memLimit: 8 * 1024 * 1024)

final class VaultStoreTests: XCTestCase {
    private var directory: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateNotesTests-\(UUID().uuidString)", isDirectory: true)
        store = VaultStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func allFiles() throws -> [URL] {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    func testNewDirectoryIsNotInitialized() {
        XCTAssertFalse(store.isInitialized)
        XCTAssertThrowsError(try store.unlock(password: "pw")) {
            XCTAssertEqual($0 as? VaultError, .notInitialized)
        }
    }

    func testCreateThenUnlock() throws {
        _ = try store.createVault(password: "pw", parameters: testKDF)
        XCTAssertTrue(store.isInitialized)
        XCTAssertNoThrow(try store.unlock(password: "pw"))
        XCTAssertThrowsError(try store.unlock(password: "nope")) {
            XCTAssertEqual($0 as? CryptoError, .wrongSecretOrCorruptKeyData)
        }
    }

    func testCreateRefusesToOverwrite() throws {
        _ = try store.createVault(password: "pw", parameters: testKDF)
        XCTAssertThrowsError(try store.createVault(password: "other", parameters: testKDF)) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists)
        }
        XCTAssertNoThrow(try store.unlock(password: "pw"))
    }

    func testNotesAndFoldersSurviveRelock() throws {
        let created = try store.createVault(password: "pw", parameters: testKDF)
        let folder = Folder(name: "Wallets")
        let note = Note(folderID: folder.id, body: "Ledger\nseed words here", isPinned: true, neverSync: true)
        try created.session.save(folder)
        try created.session.save(note)

        let reopened = try store.unlock(password: "pw")
        let folders = try reopened.loadFolders()
        let notes = try reopened.loadNotes()
        XCTAssertEqual(folders.items, [folder])
        XCTAssertEqual(notes.items, [note])
        XCTAssertEqual(folders.unreadableCount, 0)
        XCTAssertEqual(notes.unreadableCount, 0)
    }

    func testEmptyVaultLoadsEmpty() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        XCTAssertEqual(try session.loadNotes().items, [])
        XCTAssertEqual(try session.loadFolders().items, [])
    }

    func testSavingAgainReplaces() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        var note = Note(body: "first")
        try session.save(note)
        note.body = "second"
        try session.save(note)
        XCTAssertEqual(try session.loadNotes().items, [note])
    }

    func testDelete() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        let keep = Note(body: "keep")
        let drop = Note(body: "drop")
        let folder = Folder(name: "F")
        try session.save(keep)
        try session.save(drop)
        try session.save(folder)

        try session.deleteNote(id: drop.id)
        try session.deleteFolder(id: folder.id)
        try session.deleteNote(id: UUID()) // deleting something that isn't there is fine

        XCTAssertEqual(try session.loadNotes().items, [keep])
        XCTAssertEqual(try session.loadFolders().items, [])
    }

    func testNothingReadableOnDisk() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        let folder = Folder(name: "ZEBRAFOLDERNAME")
        try session.save(folder)
        try session.save(Note(folderID: folder.id, body: "GIRAFFETITLE\nOKAPIBODYTEXT"))

        let files = try allFiles()
        XCTAssertEqual(files.count, 3) // key bundle, one folder, one note
        for file in files {
            let data = try Data(contentsOf: file)
            for word in ["ZEBRAFOLDERNAME", "GIRAFFETITLE", "OKAPIBODYTEXT"] {
                XCTAssertNil(data.range(of: Data(word.utf8)), "\(word) found in \(file.lastPathComponent)")
                XCTAssertFalse(file.path.contains(word))
            }
        }
    }

    func testDamagedAndForeignFilesAreCountedNotFatal() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        let good = Note(body: "good")
        let damaged = Note(body: "damaged")
        try session.save(good)
        try session.save(damaged)

        let notesFolder = directory.appendingPathComponent("notes")
        let damagedFile = notesFolder.appendingPathComponent(damaged.id.uuidString.lowercased() + ".pnote")
        var bytes = try Data(contentsOf: damagedFile)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: damagedFile)
        try Data("junk".utf8).write(to: notesFolder.appendingPathComponent("not-a-uuid.pnote"))
        try Data("ignored".utf8).write(to: notesFolder.appendingPathComponent("readme.txt"))

        let loaded = try session.loadNotes()
        XCTAssertEqual(loaded.items, [good])
        XCTAssertEqual(loaded.unreadableCount, 2)
    }

    func testFileRenamedToAnotherIdWillNotOpen() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        let note = Note(body: "bound to its id")
        try session.save(note)

        let notesFolder = directory.appendingPathComponent("notes")
        let original = notesFolder.appendingPathComponent(note.id.uuidString.lowercased() + ".pnote")
        let renamed = notesFolder.appendingPathComponent(UUID().uuidString.lowercased() + ".pnote")
        try FileManager.default.moveItem(at: original, to: renamed)

        let loaded = try session.loadNotes()
        XCTAssertEqual(loaded.items, [])
        XCTAssertEqual(loaded.unreadableCount, 1)
    }

    func testOtherVaultsFilesWillNotOpen() throws {
        let session = try store.createVault(password: "pw", parameters: testKDF).session
        try session.save(Note(body: "mine"))

        let otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let other = try VaultStore(directory: otherDirectory).createVault(password: "pw", parameters: testKDF).session
        let foreign = Note(body: "theirs")
        try other.save(foreign)
        try FileManager.default.copyItem(
            at: otherDirectory.appendingPathComponent("notes/\(foreign.id.uuidString.lowercased()).pnote"),
            to: directory.appendingPathComponent("notes/\(foreign.id.uuidString.lowercased()).pnote")
        )

        let loaded = try session.loadNotes()
        XCTAssertEqual(loaded.items.map(\.body), ["mine"])
        XCTAssertEqual(loaded.unreadableCount, 1)
    }

    func testRecoveryPhraseUnlocksAndPasswordCanBeReset() throws {
        let created = try store.createVault(password: "forgotten", parameters: testKDF)
        let note = Note(body: "still here")
        try created.session.save(note)

        let phrase = try RecoveryPhrase(phrase: created.recoveryPhrase.phrase)
        let recovered = try store.unlock(recoveryPhrase: phrase)
        try store.changePassword(to: "new password", session: recovered)

        XCTAssertThrowsError(try store.unlock(password: "forgotten"))
        let reopened = try store.unlock(password: "new password")
        XCTAssertEqual(try reopened.loadNotes().items, [note])
        XCTAssertNoThrow(try store.unlock(recoveryPhrase: phrase))
    }

    func testTitleAndPreview() {
        XCTAssertEqual(Note(body: "").title, "")
        XCTAssertEqual(Note(body: "").preview, "")
        XCTAssertEqual(Note(body: "Only line").title, "Only line")
        XCTAssertEqual(Note(body: "Only line").preview, "")
        let note = Note(body: "\n\n  Title here  \n\n\tSecond line\nThird")
        XCTAssertEqual(note.title, "Title here")
        XCTAssertEqual(note.preview, "Second line")
    }
}
