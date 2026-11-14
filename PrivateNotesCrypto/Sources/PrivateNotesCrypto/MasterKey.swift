import CryptoKit
import Foundation

/// The single 256-bit key that everything else is encrypted under.
/// Exists in memory only while the app is unlocked. Never persisted unwrapped.
public struct MasterKey: Equatable, Sendable {
    let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// A new random master key.
    public static func generate() -> MasterKey {
        MasterKey(key: SymmetricKey(size: .bits256))
    }

    /// Rebuilds a master key from raw bytes, for example bytes read back from the Keychain.
    public init(rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw CryptoError.invalidParameters }
        self.key = SymmetricKey(data: rawBytes)
    }

    /// Raw bytes, for storing in the Keychain behind biometrics. Do not write these anywhere else.
    public func rawBytes() -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
