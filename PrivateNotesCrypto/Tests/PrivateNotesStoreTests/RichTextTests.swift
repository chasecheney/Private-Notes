import XCTest
import PrivateNotesCrypto
@testable import PrivateNotesStore

private let testKDF = KDFParameters(opsLimit: 2, memLimit: 8 * 1024 * 1024)

final class RichTextTests: XCTestCase {
    func testPlainTextRoundTrip() {
        for text in ["", "one line", "two\nlines", "trailing\n", "\n\nblank lines\n\nbetween"] {
            XCTAssertEqual(RichText(plainText: text).plainText, text, "\(text.debugDescription)")
        }
    }

    func testPlainTextBecomesBodyParagraphs() {
        let rich = RichText(plainText: "a\n\nb")
        XCTAssertEqual(rich.paragraphs.count, 3)
        XCTAssertEqual(rich.paragraphs.map(\.style), [.body, .body, .body])
        XCTAssertEqual(rich.paragraphs[1].runs, [])
    }

    func testWindowsLineEndingsAreUnified() {
        XCTAssertEqual(RichText(plainText: "a\r\nb\rc").plainText, "a\nb\nc")
    }

    func testPlainTextIgnoresFormattingAndImages() {
        let image = UUID()
        let rich = RichText(paragraphs: [
            .init(style: .title, runs: [.init(text: "Wallet"), .init(text: " backup", bold: true)]),
            .init(style: .body, runs: [.init(attachmentID: image)]),
            .init(style: .monospaced, runs: [.init(text: "abandon ability", underline: true)]),
        ])
        XCTAssertEqual(rich.plainText, "Wallet backup\n\nabandon ability")
        XCTAssertEqual(rich.attachmentIDs, [image])
    }

    func testCodableRoundTrip() throws {
        let rich = RichText(paragraphs: [
            .init(style: .heading, runs: [.init(text: "H", bold: true, italic: true)]),
            .init(style: .body, runs: [
                .init(text: "x", underline: true, strikethrough: true),
                .init(attachmentID: UUID()),
            ]),
            .init(style: .body, runs: []),
        ])
        let data = try JSONEncoder().encode(rich)
        XCTAssertEqual(try JSONDecoder().decode(RichText.self, from: data), rich)
    }

    func testDecodingToleratesMissingAndUnknownValues() throws {
        let json = #"{"paragraphs":[{"runs":[{"text":"hi"}]},{"style":"from-the-future","runs":[{"bold":true}]},{}]}"#
        let rich = try JSONDecoder().decode(RichText.self, from: Data(json.utf8))
        XCTAssertEqual(rich.paragraphs.count, 3)
        XCTAssertEqual(rich.paragraphs[0], .init(style: .body, runs: [.init(text: "hi")]))
        XCTAssertEqual(rich.paragraphs[1].style, .body)
        XCTAssertEqual(rich.paragraphs[1].runs, [.init(text: "", bold: true)])
        XCTAssertEqual(rich.paragraphs[2], .init(style: .body, runs: []))
    }

    func testNormalizedMergesAndCleans() {
        let image = UUID()
        let messy = RichText(paragraphs: [
            .init(style: .body, runs: [
                .init(text: "a"),
                .init(text: ""),
                .init(text: "b"),
                .init(text: "c", bold: true),
                .init(text: "d", bold: true),
                .init(text: "ignored", attachmentID: image),
                .init(text: "e\nf", bold: true),
            ]),
        ])
        XCTAssertEqual(messy.normalized().paragraphs[0].runs, [
            .init(text: "ab"),
            .init(text: "cd", bold: true),
            .init(attachmentID: image),
            .init(text: "e f", bold: true),
        ])
    }

    func testNoteContentFallsBackToPlainText() {
        let note = Note(body: "Title\nbody")
        XCTAssertNil(note.richText)
        XCTAssertEqual(note.content, RichText(plainText: "Title\nbody"))
    }

    func testSetContentKeepsPlainTextInStep() {
        var note = Note(body: "old")
        note.setContent(RichText(paragraphs: [
            .init(style: .title, runs: [.init(text: "New title", bold: true)]),
            .init(style: .body, runs: [.init(text: "second line")]),
        ]))
        XCTAssertEqual(note.body, "New title\nsecond line")
        XCTAssertEqual(note.title, "New title")
        XCTAssertEqual(note.preview, "second line")
    }

    func testNotesSavedBeforeRichTextStillLoad() throws {
        // What a note looked like on disk before formatting existed: no richText key.
        let old = #"{"id":"0E1B6C0C-7D0B-4C39-9D5E-0C2B9B4E6A11","body":"plain","createdAt":0,"modifiedAt":0,"isPinned":false,"isReadOnly":true,"neverSync":false}"#
        let note = try JSONDecoder().decode(Note.self, from: Data(old.utf8))
        XCTAssertEqual(note.body, "plain")
        XCTAssertNil(note.richText)
        XCTAssertTrue(note.isReadOnly)
        XCTAssertEqual(note.content.plainText, "plain")
    }

    // MARK: - In the vault

    private func makeSession() throws -> (VaultSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateNotesTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try VaultStore(directory: directory).createVault(password: "pw", parameters: testKDF).session
        return (session, directory)
    }

    func testFormattedNotePersists() throws {
        let (session, _) = try makeSession()
        var note = Note()
        note.setContent(RichText(paragraphs: [
            .init(style: .title, runs: [.init(text: "Seeds")]),
            .init(style: .monospaced, runs: [.init(text: "word word", bold: true), .init(attachmentID: UUID())]),
        ]))
        try session.save(note)
        XCTAssertEqual(try session.loadNotes().items, [note])
    }

    func testAttachmentRoundTripAndListing() throws {
        let (session, _) = try makeSession()
        let first = UUID()
        let second = UUID()
        let bytes = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try session.saveAttachment(id: first, data: bytes)
        try session.saveAttachment(id: second, data: Data("small".utf8))

        XCTAssertEqual(try session.loadAttachment(id: first), bytes)
        XCTAssertEqual(Set(try session.attachmentIDs()), [first, second])

        try session.deleteAttachment(id: first)
        XCTAssertEqual(try session.attachmentIDs(), [second])
        XCTAssertThrowsError(try session.loadAttachment(id: first))
        XCTAssertNoThrow(try session.deleteAttachment(id: first))
    }

    func testAttachmentIsEncryptedOnDiskAndBoundToItsId() throws {
        let (session, directory) = try makeSession()
        let id = UUID()
        let marker = Data("PLAINIMAGEBYTESMARKER".utf8)
        try session.saveAttachment(id: id, data: marker + Data(repeating: 0xAB, count: 1000))

        let folder = directory.appendingPathComponent("attachments")
        let file = folder.appendingPathComponent(id.uuidString.lowercased() + ".pnote")
        XCTAssertNil(try Data(contentsOf: file).range(of: marker))

        let other = UUID()
        try FileManager.default.copyItem(
            at: file,
            to: folder.appendingPathComponent(other.uuidString.lowercased() + ".pnote")
        )
        XCTAssertThrowsError(try session.loadAttachment(id: other))
    }

    func testEmptyVaultHasNoAttachments() throws {
        let (session, _) = try makeSession()
        XCTAssertEqual(try session.attachmentIDs(), [])
    }
}
