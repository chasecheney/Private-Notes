import Foundation
import PrivateNotesCrypto

/// Something the vault stores as one encrypted file.
protocol VaultItem: Codable, Sendable {
    var id: UUID { get }
    static var kind: ItemKind { get }
}

public struct Folder: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

extension Folder: VaultItem {
    static var kind: ItemKind { .folder }
}

public struct Note: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// The folder this note is in, or nil when it is not in any folder.
    public var folderID: UUID?
    /// The whole text without formatting. The first line doubles as the title, as in Apple Notes.
    /// Kept in step with `richText`; used for titles, previews, and search.
    public var body: String
    /// The formatted content. Nil for a note that has only ever been plain text.
    public var richText: RichText?
    public var createdAt: Date
    public var modifiedAt: Date
    public var isPinned: Bool
    /// Protected against accidental edits; the app asks for the password before allowing changes.
    public var isReadOnly: Bool
    /// Never leaves this device: must not be handed to sync in any form.
    public var neverSync: Bool

    public init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        body: String = "",
        richText: RichText? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false,
        isReadOnly: Bool = false,
        neverSync: Bool = false
    ) {
        self.id = id
        self.folderID = folderID
        self.body = body
        self.richText = richText
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
        self.isReadOnly = isReadOnly
        self.neverSync = neverSync
    }

    /// The formatted content, built from the plain text when the note has none yet.
    public var content: RichText {
        richText ?? RichText(plainText: body)
    }

    /// Replaces the content, keeping the plain text in step.
    public mutating func setContent(_ newContent: RichText) {
        richText = newContent
        body = newContent.plainText
    }

    /// First non-blank line.
    public var title: String {
        nonBlankLines.first ?? ""
    }

    /// Second non-blank line, shown under the title in the note list.
    public var preview: String {
        let lines = nonBlankLines
        return lines.count > 1 ? lines[1] : ""
    }

    private var nonBlankLines: [String] {
        var found: [String] = []
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                found.append(trimmed)
                if found.count == 2 { break }
            }
        }
        return found
    }
}

extension Note: VaultItem {
    static var kind: ItemKind { .note }
}
