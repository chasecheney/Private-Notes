import CryptoKit
import Foundation

/// What an encrypted item is. Part of the encryption context, so ciphertext of one kind
/// cannot be passed off as another.
public enum ItemKind: String, Codable, Sendable {
    /// A note's title and rich-text body.
    case note
    /// An image or other file attached to a note.
    case attachment
    /// A folder's name and settings.
    case folder
}

/// Identifies one encrypted item. The same kind and id must be given to open it again.
public struct ItemContext: Equatable, Hashable, Sendable {
    public let kind: ItemKind
    public let id: UUID

    public init(kind: ItemKind, id: UUID) {
        self.kind = kind
        self.id = id
    }

    var label: Data {
        Data("PrivateNotes/v1/item/\(kind.rawValue)/\(id.uuidString.lowercased())".utf8)
    }
}

/// Encrypts and decrypts notes, attachments, and folders under the master key.
///
/// Each item gets its own key (derived from the master key and the item's kind and id) and a
/// fresh random nonce on every save. Ciphertext is bound to its item: it will not open as a
/// different note, as a different kind, or if any byte was changed.
///
/// Stored format: 1 version byte, then nonce (12) + ciphertext + tag (16).
public struct ItemCipher: Sendable {
    static let formatVersion: UInt8 = 1

    private let masterKey: MasterKey

    public init(masterKey: MasterKey) {
        self.masterKey = masterKey
    }

    public func seal(_ plaintext: Data, for context: ItemContext) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: itemKey(for: context), authenticating: context.label)
        var out = Data([Self.formatVersion])
        out.append(box.combined)
        return out
    }

    public func open(_ sealed: Data, for context: ItemContext) throws -> Data {
        guard let version = sealed.first else { throw CryptoError.decryptionFailed }
        guard version == Self.formatVersion else { throw CryptoError.unsupportedVersion(Int(version)) }
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed.dropFirst())
            return try ChaChaPoly.open(box, using: itemKey(for: context), authenticating: context.label)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    private func itemKey(for context: ItemContext) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey.key,
            info: context.label,
            outputByteCount: 32
        )
    }
}
