import XCTest
@testable import PrivateNotesCrypto

final class ItemCipherTests: XCTestCase {
    private let cipher = ItemCipher(masterKey: .generate())
    private let note = ItemContext(kind: .note, id: UUID())
    private let secret = Data("seed words go here".utf8)

    func testRoundTrip() throws {
        let sealed = try cipher.seal(secret, for: note)
        XCTAssertEqual(try cipher.open(sealed, for: note), secret)
    }

    func testEmptyAndLargeData() throws {
        XCTAssertEqual(try cipher.open(try cipher.seal(Data(), for: note), for: note), Data())
        let large = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let attachment = ItemContext(kind: .attachment, id: UUID())
        XCTAssertEqual(try cipher.open(try cipher.seal(large, for: attachment), for: attachment), large)
    }

    func testCiphertextHidesPlaintext() throws {
        let sealed = try cipher.seal(secret, for: note)
        XCTAssertNil(sealed.range(of: secret))
        XCTAssertEqual(sealed.count, 1 + 12 + secret.count + 16)
    }

    func testSameInputEncryptsDifferentlyEachTime() throws {
        XCTAssertNotEqual(try cipher.seal(secret, for: note), try cipher.seal(secret, for: note))
    }

    func testWrongNoteIdFails() throws {
        let sealed = try cipher.seal(secret, for: note)
        let other = ItemContext(kind: .note, id: UUID())
        XCTAssertThrowsError(try cipher.open(sealed, for: other)) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testWrongKindFails() throws {
        let sealed = try cipher.seal(secret, for: note)
        let sameIdAsFolder = ItemContext(kind: .folder, id: note.id)
        XCTAssertThrowsError(try cipher.open(sealed, for: sameIdAsFolder)) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testWrongMasterKeyFails() throws {
        let sealed = try cipher.seal(secret, for: note)
        let otherCipher = ItemCipher(masterKey: .generate())
        XCTAssertThrowsError(try otherCipher.open(sealed, for: note)) {
            XCTAssertEqual($0 as? CryptoError, .decryptionFailed)
        }
    }

    func testAnyModifiedByteFails() throws {
        let sealed = try cipher.seal(secret, for: note)
        for position in 1..<sealed.count {
            var tampered = sealed
            tampered[position] ^= 0x01
            XCTAssertThrowsError(try cipher.open(tampered, for: note), "byte \(position)")
        }
    }

    func testTruncatedAndEmptyInputFails() throws {
        let sealed = try cipher.seal(secret, for: note)
        XCTAssertThrowsError(try cipher.open(Data(), for: note))
        XCTAssertThrowsError(try cipher.open(sealed.prefix(10), for: note))
        XCTAssertThrowsError(try cipher.open(sealed.dropLast(), for: note))
    }

    func testUnknownFormatVersionRejected() throws {
        var sealed = try cipher.seal(secret, for: note)
        sealed[0] = 2
        XCTAssertThrowsError(try cipher.open(sealed, for: note)) {
            XCTAssertEqual($0 as? CryptoError, .unsupportedVersion(2))
        }
    }

    func testFullFlowAfterRelock() throws {
        // Set up, encrypt, "lock" (drop the key), unlock with the password, decrypt.
        let vault = try KeyBundle.create(password: "pw", parameters: testKDF)
        let sealed = try ItemCipher(masterKey: vault.masterKey).seal(secret, for: note)
        let reopenedKey = try vault.bundle.unlock(password: "pw")
        XCTAssertEqual(try ItemCipher(masterKey: reopenedKey).open(sealed, for: note), secret)
    }
}
