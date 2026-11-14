import Foundation
import LocalAuthentication
import Security

public enum BiometricError: Error, Equatable {
    /// This device has no usable Touch ID / Face ID.
    case unavailable
    /// Nothing stored, or it was invalidated because the enrolled fingerprints or faces changed.
    case noStoredKey
    /// The user dismissed the prompt or the match failed.
    case cancelled
    /// The Keychain refused; the code is the system status.
    case keychain(Int32)
}

/// The Keychain copy of the master key that Touch ID / Face ID unlocks.
///
/// The item is bound to the current biometric enrollment (adding a finger or face invalidates
/// it), stays on this device only, and has no device-passcode fallback: when biometrics fail,
/// the app password is the way in.
enum BiometricKeychain {
    private static let service = "com.chasecheney.privatenotes.masterkey"
    private static let account = "vault"

    private static var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    static var biometryName: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    static var exists: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery
        query[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func store(_ key: Data) throws {
        guard biometryName != nil else { throw BiometricError.unavailable }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            accessError?.release()
            throw BiometricError.unavailable
        }

        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData] = key
        query[kSecAttrAccessControl] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricError.keychain(status) }
    }

    static func read(reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw BiometricError.keychain(status) }
            return data
        case errSecItemNotFound:
            throw BiometricError.noStoredKey
        case errSecUserCanceled, errSecAuthFailed:
            throw BiometricError.cancelled
        default:
            throw BiometricError.keychain(status)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
