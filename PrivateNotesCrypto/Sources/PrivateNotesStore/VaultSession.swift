import Foundation
import PrivateNotesCrypto

/// What came back from reading the vault, and how many files could not be opened
/// (damaged, or not written by this vault's key).
public struct Loaded<Item: Sendable>: Sendable {
    public var items: [Item]
    public var unreadableCount: Int
}

/// An unlocked vault. Holds the master key in memory; drop every reference to lock.
public final class VaultSession: Sendable {
    static let fileExtension = "pnote"

    let directory: URL
    let masterKey: MasterKey
    private let cipher: ItemCipher

    init(directory: URL, masterKey: MasterKey) {
        self.directory = directory
        self.masterKey = masterKey
        self.cipher = ItemCipher(masterKey: masterKey)
    }

    public func loadFolders() throws -> Loaded<Folder> { try load() }
    public func loadNotes() throws -> Loaded<Note> { try load() }

    public func save(_ folder: Folder) throws { try store(folder) }
    public func save(_ note: Note) throws { try store(note) }

    public func deleteFolder(id: UUID) throws { try remove(.folder, id) }
    public func deleteNote(id: UUID) throws { try remove(.note, id) }

    // MARK: - Key check

    private static let keyCheckContext = ItemContext(
        kind: .keyCheck,
        id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    )
    private static let keyCheckMarker = Data("PrivateNotes key check v1".utf8)

    private var keyCheckURL: URL {
        directory.appendingPathComponent("keycheck").appendingPathExtension(Self.fileExtension)
    }

    var hasKeyCheck: Bool {
        FileManager.default.fileExists(atPath: keyCheckURL.path)
    }

    /// Writes a small encrypted marker. A key that can open it is this vault's key.
    func writeKeyCheck() throws {
        try VaultFiles.write(try cipher.seal(Self.keyCheckMarker, for: Self.keyCheckContext), to: keyCheckURL)
    }

    /// True only if this session's key opens the vault's marker.
    func keyCheckPasses() -> Bool {
        guard let sealed = try? Data(contentsOf: keyCheckURL),
              let plain = try? cipher.open(sealed, for: Self.keyCheckContext)
        else { return false }
        return plain == Self.keyCheckMarker
    }

    // MARK: - Files

    private func folderURL(for kind: ItemKind) -> URL {
        let name: String
        switch kind {
        case .note: name = "notes"
        case .folder: name = "folders"
        case .attachment: name = "attachments"
        case .keyCheck: name = "check"
        }
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private func fileURL(_ kind: ItemKind, _ id: UUID) -> URL {
        folderURL(for: kind)
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension(Self.fileExtension)
    }

    private func store<Item: VaultItem>(_ item: Item) throws {
        let kind = Item.kind
        let plain = try JSONEncoder().encode(item)
        let sealed = try cipher.seal(plain, for: ItemContext(kind: kind, id: item.id))
        try FileManager.default.createDirectory(at: folderURL(for: kind), withIntermediateDirectories: true)
        try VaultFiles.write(sealed, to: fileURL(kind, item.id))
    }

    private func load<Item: VaultItem>() throws -> Loaded<Item> {
        let kind = Item.kind
        let folder = folderURL(for: kind)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return Loaded(items: [], unreadableCount: 0)
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == Self.fileExtension }

        var items: [Item] = []
        var unreadable = 0
        for file in files {
            guard
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                let sealed = try? Data(contentsOf: file),
                let plain = try? cipher.open(sealed, for: ItemContext(kind: kind, id: id)),
                let item = try? JSONDecoder().decode(Item.self, from: plain),
                item.id == id
            else {
                unreadable += 1
                continue
            }
            items.append(item)
        }
        return Loaded(items: items, unreadableCount: unreadable)
    }

    private func remove(_ kind: ItemKind, _ id: UUID) throws {
        let url = fileURL(kind, id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
