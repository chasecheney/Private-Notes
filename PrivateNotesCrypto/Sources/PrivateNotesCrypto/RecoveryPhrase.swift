import CryptoKit
import Foundation

/// A 24-word recovery phrase in the BIP39 English word format: 256 random bits plus an
/// 8-bit checksum, 11 bits per word. Shown to the user once at setup; never stored.
public struct RecoveryPhrase: Equatable, Sendable {
    public static let wordCount = 24
    static let entropyLength = 32

    /// The 24 words, in order.
    public let words: [String]
    let entropy: Data

    /// The words joined by single spaces.
    public var phrase: String { words.joined(separator: " ") }

    /// A new random phrase.
    public static func generate() -> RecoveryPhrase {
        let entropy = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // 32 random bytes always encode, so this cannot fail.
        return try! RecoveryPhrase(entropy: entropy)
    }

    init(entropy: Data) throws {
        guard entropy.count == Self.entropyLength else { throw CryptoError.invalidParameters }
        let bytes = Array(entropy) + [Self.checksum(of: entropy)]
        self.entropy = Data(entropy)
        self.words = (0..<Self.wordCount).map { BIP39Wordlist.words[Self.index(ofWord: $0, in: bytes)] }
    }

    /// Parses a phrase the user typed. Case and extra spacing are ignored.
    /// Throws `invalidRecoveryPhrase` for a wrong word count, an unknown word, or a bad checksum.
    public init(phrase: String) throws {
        let typed = phrase
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard typed.count == Self.wordCount else { throw CryptoError.invalidRecoveryPhrase }

        var bytes = [UInt8](repeating: 0, count: Self.entropyLength + 1)
        for (position, word) in typed.enumerated() {
            guard let value = BIP39Wordlist.index[word] else { throw CryptoError.invalidRecoveryPhrase }
            for bit in 0..<11 where (value >> (10 - bit)) & 1 == 1 {
                let offset = position * 11 + bit
                bytes[offset / 8] |= UInt8(1) << UInt8(7 - offset % 8)
            }
        }

        let entropy = Data(bytes[0..<Self.entropyLength])
        guard bytes[Self.entropyLength] == Self.checksum(of: entropy) else {
            throw CryptoError.invalidRecoveryPhrase
        }
        self.entropy = entropy
        self.words = typed
    }

    /// The key that wraps the master key for recovery. The phrase already carries 256 bits
    /// of randomness, so a fast derivation is enough; no slow password hashing is needed.
    func keyEncryptionKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: entropy),
            info: Data("PrivateNotes/v1/recovery-kek".utf8),
            outputByteCount: 32
        )
    }

    private static func checksum(of entropy: Data) -> UInt8 {
        Array(SHA256.hash(data: entropy))[0]
    }

    /// Reads the 11-bit value for word number `position` out of the entropy-plus-checksum bytes.
    private static func index(ofWord position: Int, in bytes: [UInt8]) -> Int {
        var value = 0
        for offset in (position * 11)..<(position * 11 + 11) {
            let bit = (bytes[offset / 8] >> UInt8(7 - offset % 8)) & 1
            value = (value << 1) | Int(bit)
        }
        return value
    }
}
