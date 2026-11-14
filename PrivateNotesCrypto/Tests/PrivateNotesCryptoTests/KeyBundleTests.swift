import XCTest
@testable import PrivateNotesCrypto

/// Small Argon2id settings so the tests run quickly. Real vaults use `.moderate`.
let testKDF = KDFParameters(opsLimit: 2, memLimit: 8 * 1024 * 1024)

final class KeyBundleTests: XCTestCase {
    func testPasswordUnlocks() throws {
        let vault = try KeyBundle.create(password: "correct horse", parameters: testKDF)
        XCTAssertEqual(try vault.bundle.unlock(password: "correct horse"), vault.masterKey)
    }

    func testWrongPasswordFails() throws {
        let vault = try KeyBundle.create(password: "correct horse", parameters: testKDF)
        XCTAssertThrowsError(try vault.bundle.unlock(password: "Correct horse")) {
            XCTAssertEqual($0 as? CryptoError, .wrongSecretOrCorruptKeyData)
        }
    }

    func testEmptyPasswordRejected() {
        XCTAssertThrowsError(try KeyBundle.create(password: "", parameters: testKDF)) {
            XCTAssertEqual($0 as? CryptoError, .invalidParameters)
        }
    }

    func testNonASCIIPasswordWorks() throws {
        let password = "pässwörd 密码 🔐"
        let vault = try KeyBundle.create(password: password, parameters: testKDF)
        XCTAssertEqual(try vault.bundle.unlock(password: password), vault.masterKey)
        XCTAssertThrowsError(try vault.bundle.unlock(password: "passwörd 密码 🔐"))
    }

    func testUnicodeNormalizationGivesSameKey() throws {
        let composed = "caf\u{00E9}"        // é as one code point
        let decomposed = "cafe\u{0301}"     // e + combining accent
        let vault = try KeyBundle.create(password: composed, parameters: testKDF)
        XCTAssertEqual(try vault.bundle.unlock(password: decomposed), vault.masterKey)
    }

    func testPasswordEncodingIsStable() {
        // This encoding is part of the stored format; it must never change.
        XCTAssertEqual(PasswordKDF.encodedPassword("Az9"), Array("417a39".utf8))
        XCTAssertEqual(PasswordKDF.encodedPassword("\u{00E9}"), Array("c3a9".utf8))
    }

    func testKeyDerivationIsDeterministicAndSalted() throws {
        let saltA = Data(repeating: 1, count: PasswordKDF.saltLength)
        let saltB = Data(repeating: 2, count: PasswordKDF.saltLength)
        let first = try PasswordKDF.deriveKey(password: "pw", salt: saltA, parameters: testKDF)
        let again = try PasswordKDF.deriveKey(password: "pw", salt: saltA, parameters: testKDF)
        let otherSalt = try PasswordKDF.deriveKey(password: "pw", salt: saltB, parameters: testKDF)
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, otherSalt)
    }

    func testBadSaltLengthRejected() {
        XCTAssertThrowsError(
            try PasswordKDF.deriveKey(password: "pw", salt: Data(repeating: 1, count: 5), parameters: testKDF)
        ) {
            XCTAssertEqual($0 as? CryptoError, .invalidParameters)
        }
    }

    func testRecoveryPhraseUnlocks() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let retyped = try RecoveryPhrase(phrase: vault.recoveryPhrase.phrase)
        XCTAssertEqual(try vault.bundle.unlock(recoveryPhrase: retyped), vault.masterKey)
    }

    func testOtherRecoveryPhraseFails() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        XCTAssertThrowsError(try vault.bundle.unlock(recoveryPhrase: .generate())) {
            XCTAssertEqual($0 as? CryptoError, .wrongSecretOrCorruptKeyData)
        }
    }

    func testChangePassword() throws {
        let vault = try KeyBundle.create(password: "old", parameters: testKDF)
        let changed = try vault.bundle.changingPassword(to: "new", masterKey: vault.masterKey)

        XCTAssertEqual(try changed.unlock(password: "new"), vault.masterKey)
        XCTAssertThrowsError(try changed.unlock(password: "old"))
        XCTAssertEqual(try changed.unlock(recoveryPhrase: vault.recoveryPhrase), vault.masterKey)
        XCTAssertNotEqual(changed.passwordSalt, vault.bundle.passwordSalt)
        XCTAssertEqual(changed.recoveryWrappedKey, vault.bundle.recoveryWrappedKey)
    }

    func testChangePasswordCanRaiseCost() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let stronger = KDFParameters(opsLimit: 3, memLimit: 16 * 1024 * 1024)
        let changed = try vault.bundle.changingPassword(to: "pw", masterKey: vault.masterKey, parameters: stronger)
        XCTAssertEqual(changed.kdf, stronger)
        XCTAssertEqual(try changed.unlock(password: "pw"), vault.masterKey)
    }

    func testReplaceRecoveryPhrase() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let replaced = try vault.bundle.replacingRecoveryPhrase(masterKey: vault.masterKey)

        XCTAssertEqual(try replaced.bundle.unlock(recoveryPhrase: replaced.recoveryPhrase), vault.masterKey)
        XCTAssertThrowsError(try replaced.bundle.unlock(recoveryPhrase: vault.recoveryPhrase))
        XCTAssertEqual(try replaced.bundle.unlock(password: "pw"), vault.masterKey)
    }

    func testBundleSurvivesJSONRoundTrip() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let json = try JSONEncoder().encode(vault.bundle)
        let decoded = try JSONDecoder().decode(KeyBundle.self, from: json)
        XCTAssertEqual(decoded, vault.bundle)
        XCTAssertEqual(try decoded.unlock(password: "pw"), vault.masterKey)
    }

    func testBundleHoldsNoPlainKey() throws {
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let raw = vault.masterKey.rawBytes()
        XCTAssertNil(vault.bundle.passwordWrappedKey.range(of: raw))
        XCTAssertNil(vault.bundle.recoveryWrappedKey.range(of: raw))
    }

    func testTamperedWrappedKeyFails() throws {
        var bundle = try KeyBundle.create(password: "pw", parameters: testKDF).bundle
        bundle.passwordWrappedKey[bundle.passwordWrappedKey.count - 1] ^= 0x01
        XCTAssertThrowsError(try bundle.unlock(password: "pw")) {
            XCTAssertEqual($0 as? CryptoError, .wrongSecretOrCorruptKeyData)
        }
    }

    func testNewerVersionRejected() throws {
        var bundle = try KeyBundle.create(password: "pw", parameters: testKDF).bundle
        bundle.version = 99
        XCTAssertThrowsError(try bundle.unlock(password: "pw")) {
            XCTAssertEqual($0 as? CryptoError, .unsupportedVersion(99))
        }
    }

    func testMasterKeyRawBytesRoundTrip() throws {
        let key = MasterKey.generate()
        XCTAssertEqual(key.rawBytes().count, 32)
        XCTAssertEqual(try MasterKey(rawBytes: key.rawBytes()), key)
        XCTAssertThrowsError(try MasterKey(rawBytes: Data(repeating: 0, count: 31)))
    }

    func testModerateSettingsAreAtLeastLibsodiumModerate() {
        XCTAssertGreaterThanOrEqual(KDFParameters.moderate.opsLimit, 3)
        XCTAssertGreaterThanOrEqual(KDFParameters.moderate.memLimit, 256 * 1024 * 1024)
    }
}
