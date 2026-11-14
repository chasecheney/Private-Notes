import XCTest
@testable import PrivateNotesCrypto

final class RecoveryPhraseTests: XCTestCase {
    func testWordlistIsComplete() {
        XCTAssertEqual(BIP39Wordlist.words.count, 2048)
        XCTAssertEqual(BIP39Wordlist.index.count, 2048)
        XCTAssertEqual(BIP39Wordlist.words.first, "abandon")
        XCTAssertEqual(BIP39Wordlist.words.last, "zoo")
    }

    // Published BIP39 test vectors for 256-bit entropy.
    func testKnownVectorAllZeros() throws {
        let phrase = try RecoveryPhrase(entropy: Data(repeating: 0x00, count: 32))
        XCTAssertEqual(phrase.words, Array(repeating: "abandon", count: 23) + ["art"])
    }

    func testKnownVectorAllOnes() throws {
        let phrase = try RecoveryPhrase(entropy: Data(repeating: 0xFF, count: 32))
        XCTAssertEqual(phrase.words, Array(repeating: "zoo", count: 23) + ["vote"])
    }

    func testKnownVector7F() throws {
        let phrase = try RecoveryPhrase(entropy: Data(repeating: 0x7F, count: 32))
        XCTAssertEqual(
            phrase.phrase,
            "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
        )
    }

    func testGenerateAndParseRoundTrip() throws {
        for _ in 0..<50 {
            let original = RecoveryPhrase.generate()
            XCTAssertEqual(original.words.count, 24)
            let parsed = try RecoveryPhrase(phrase: original.phrase)
            XCTAssertEqual(parsed, original)
            XCTAssertEqual(parsed.keyEncryptionKey(), original.keyEncryptionKey())
        }
    }

    func testGeneratedPhrasesDiffer() {
        XCTAssertNotEqual(RecoveryPhrase.generate(), RecoveryPhrase.generate())
    }

    func testParsingIgnoresCaseAndSpacing() throws {
        let original = RecoveryPhrase.generate()
        let messy = "  " + original.words.map { $0.uppercased() }.joined(separator: " \n\t ") + "\n"
        XCTAssertEqual(try RecoveryPhrase(phrase: messy), original)
    }

    func testRejectsWrongWordCount() {
        let words = RecoveryPhrase.generate().words
        XCTAssertThrowsError(try RecoveryPhrase(phrase: words.dropLast().joined(separator: " "))) {
            XCTAssertEqual($0 as? CryptoError, .invalidRecoveryPhrase)
        }
        XCTAssertThrowsError(try RecoveryPhrase(phrase: "")) {
            XCTAssertEqual($0 as? CryptoError, .invalidRecoveryPhrase)
        }
    }

    func testRejectsUnknownWord() {
        var words = RecoveryPhrase.generate().words
        words[5] = "notaword"
        XCTAssertThrowsError(try RecoveryPhrase(phrase: words.joined(separator: " "))) {
            XCTAssertEqual($0 as? CryptoError, .invalidRecoveryPhrase)
        }
    }

    func testRejectsBadChecksum() {
        // Valid words, wrong last word: the all-zeros phrase must end in "art".
        let words = Array(repeating: "abandon", count: 24)
        XCTAssertThrowsError(try RecoveryPhrase(phrase: words.joined(separator: " "))) {
            XCTAssertEqual($0 as? CryptoError, .invalidRecoveryPhrase)
        }
    }

    func testRejectsWrongEntropyLength() {
        XCTAssertThrowsError(try RecoveryPhrase(entropy: Data(repeating: 0, count: 16)))
    }
}
