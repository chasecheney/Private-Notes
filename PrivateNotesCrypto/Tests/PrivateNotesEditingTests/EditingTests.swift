import XCTest
import PrivateNotesStore
@testable import PrivateNotesEditing

final class EditingTests: XCTestCase {
    private func show(_ rich: RichText) -> NSAttributedString {
        RichTextConverter.attributedString(from: rich) { _ in nil }
    }

    private func roundTrip(_ rich: RichText, file: StaticString = #filePath, line: UInt = #line) {
        let shown = show(rich)
        XCTAssertEqual(RichTextConverter.richText(from: shown), rich.normalized(), file: file, line: line)
        XCTAssertTrue(ListSupport.normalizationEdits(for: shown).isEmpty, "freshly shown text should need no fixing", file: file, line: line)
    }

    private let sample = RichText(paragraphs: [
        .init(style: .title, runs: [.init(text: "Wallets")]),
        .init(style: .body, runs: [
            .init(text: "plain "),
            .init(text: "bold", bold: true),
            .init(text: " italic", italic: true),
            .init(text: " both", bold: true, italic: true),
            .init(text: " under", underline: true),
            .init(text: " strike", strikethrough: true),
        ]),
        .init(style: .body, runs: []),
        .init(style: .heading, runs: [.init(text: "Steps")]),
        .init(style: .body, list: .numbered, runs: [.init(text: "first")]),
        .init(style: .body, list: .numbered, runs: [.init(text: "second", bold: true)]),
        .init(style: .body, list: .bullet, indent: 1, runs: [.init(text: "nested")]),
        .init(style: .body, list: .dash, indent: 2, runs: [.init(text: "deeper")]),
        .init(style: .body, list: .numbered, runs: [.init(text: "third")]),
        .init(style: .monospaced, runs: [.init(text: "abandon ability able")]),
        .init(style: .subheading, runs: [.init(text: "End")]),
    ])

    // MARK: - Round trips

    func testRoundTripOfFormattedDocument() {
        roundTrip(sample)
    }

    func testRoundTripOfEdgeCases() {
        roundTrip(RichText(paragraphs: [.init()]))
        roundTrip(RichText(plainText: ""))
        roundTrip(RichText(plainText: "one"))
        roundTrip(RichText(plainText: "\n\ntext\n\n"))
        roundTrip(RichText(paragraphs: [.init(list: .bullet, runs: [])]))
        roundTrip(RichText(paragraphs: [
            .init(style: .title, list: .numbered, runs: [.init(text: "big item")]),
            .init(list: .bullet, indent: 6, runs: [.init(text: "deepest")]),
        ]))
    }

    func testRoundTripKeepsImages() {
        let first = UUID()
        let second = UUID()
        roundTrip(RichText(paragraphs: [
            .init(runs: [.init(text: "before"), .init(attachmentID: first), .init(text: "after")]),
            .init(list: .bullet, runs: [.init(attachmentID: second)]),
        ]))
    }

    // MARK: - What is shown

    func testListMarkersAreShownButNotStored() {
        let shown = show(sample)
        let text = shown.string
        XCTAssertTrue(text.contains("1.\tfirst\n2.\tsecond\n•\tnested\n–\tdeeper\n3.\tthird"), text)
        XCTAssertFalse(RichTextConverter.richText(from: shown).plainText.contains("•"))
        XCTAssertFalse(RichTextConverter.richText(from: shown).plainText.contains("\t"))
    }

    func testNumbering() {
        func numbers(_ items: [(RichText.ListKind?, Int)]) -> [Int] {
            ListSupport.numbers(for: items.map { (list: $0.0, indent: $0.1) })
        }
        XCTAssertEqual(numbers([(.numbered, 0), (.numbered, 0), (.numbered, 0)]), [1, 2, 3])
        // A nested list numbers on its own and the outer list carries on afterwards.
        XCTAssertEqual(numbers([(.numbered, 0), (.numbered, 1), (.numbered, 1), (.numbered, 0)]), [1, 1, 2, 2])
        // Ordinary text restarts numbering.
        XCTAssertEqual(numbers([(.numbered, 0), (nil, 0), (.numbered, 0)]), [1, 1, 1])
        // So does a bullet at the same depth.
        XCTAssertEqual(numbers([(.numbered, 0), (.bullet, 0), (.numbered, 0)]), [1, 1, 1])
        // A nested bullet does not.
        XCTAssertEqual(numbers([(.numbered, 0), (.bullet, 1), (.numbered, 0)]), [1, 1, 2])
    }

    func testFormatSurvivesAttributes() {
        let formats = [
            TextFormat(),
            TextFormat(style: .title, bold: true),
            TextFormat(style: .monospaced, italic: true, underline: true),
            TextFormat(style: .heading, strikethrough: true, list: .numbered, indent: 3),
            TextFormat(style: .body, bold: true, italic: true, list: .dash, indent: 0),
        ]
        for format in formats {
            XCTAssertEqual(TextFormat(attributes: format.attributes), format)
        }
    }

    func testMarkerAttributesAreTaggedAndPlain() {
        let marker = TextFormat(style: .body, bold: true, underline: true, list: .bullet, indent: 2).markerAttributes
        XCTAssertNotNil(marker[.noteListMarker])
        XCTAssertNil(marker[.underlineStyle])
        let read = TextFormat(attributes: marker)
        XCTAssertFalse(read.bold)
        XCTAssertEqual(read.list, .bullet)
        XCTAssertEqual(read.indent, 2)
        XCTAssertNil(TextFormat(style: .body, list: .bullet).attributes[.noteListMarker])
    }

    func testPlainTypedTextIsBodyText() {
        // Text with no attributes of ours at all, as from an unexpected source.
        let rich = RichTextConverter.richText(from: NSAttributedString(string: "hello\nworld"))
        XCTAssertEqual(rich, RichText(plainText: "hello\nworld"))
    }

    // MARK: - Paragraph helpers

    func testParagraphRanges() {
        func ranges(_ text: String) -> [NSRange] { ListSupport.paragraphRanges(in: text as NSString) }
        XCTAssertEqual(ranges(""), [NSRange(location: 0, length: 0)])
        XCTAssertEqual(ranges("ab"), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(ranges("ab\n"), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 0)])
        XCTAssertEqual(ranges("a\n\nbc"), [
            NSRange(location: 0, length: 1), NSRange(location: 2, length: 0), NSRange(location: 3, length: 2),
        ])
        let text = "ab\ncde\n" as NSString
        XCTAssertEqual(ListSupport.paragraphRange(containing: 0, in: text), NSRange(location: 0, length: 2))
        XCTAssertEqual(ListSupport.paragraphRange(containing: 2, in: text), NSRange(location: 0, length: 2))
        XCTAssertEqual(ListSupport.paragraphRange(containing: 3, in: text), NSRange(location: 3, length: 3))
        XCTAssertEqual(ListSupport.paragraphRange(containing: 7, in: text), NSRange(location: 7, length: 0))
        XCTAssertEqual(ListSupport.paragraphRange(containing: 99, in: text), NSRange(location: 7, length: 0))
    }

    func testMarkerRange() {
        let shown = show(RichText(paragraphs: [
            .init(runs: [.init(text: "plain")]),
            .init(list: .numbered, runs: [.init(text: "item")]),
        ]))
        let ranges = ListSupport.paragraphRanges(in: shown.string as NSString)
        XCTAssertNil(ListSupport.markerRange(inParagraph: ranges[0], of: shown))
        XCTAssertEqual(
            ListSupport.markerRange(inParagraph: ranges[1], of: shown),
            NSRange(location: ranges[1].location, length: 3) // "1." and a tab
        )
    }

    func testTypedTextThatLooksLikeAMarkerIsNotOne() {
        let typed = NSAttributedString(string: "•\tnot a list", attributes: TextFormat().attributes)
        XCTAssertNil(ListSupport.markerRange(inParagraph: NSRange(location: 0, length: typed.length), of: typed))
        XCTAssertEqual(RichTextConverter.richText(from: typed).plainText, "•\tnot a list")
    }

    // MARK: - Self-repair

    /// Applies the edits the way the editor does, last one first.
    private func fixed(_ attributed: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        for edit in ListSupport.normalizationEdits(for: attributed).reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertTrue(ListSupport.normalizationEdits(for: result).isEmpty, "fixing should settle in one pass")
        return result
    }

    private let threeItems = RichText(paragraphs: [
        .init(list: .numbered, runs: [.init(text: "one")]),
        .init(list: .numbered, runs: [.init(text: "two")]),
        .init(list: .numbered, runs: [.init(text: "three")]),
    ])

    func testRenumbersAfterAnItemIsRemoved() {
        let shown = NSMutableAttributedString(attributedString: show(threeItems))
        let second = (shown.string as NSString).range(of: "2.\ttwo\n")
        shown.deleteCharacters(in: second)
        XCTAssertEqual(shown.string, "1.\tone\n3.\tthree")
        XCTAssertEqual(fixed(shown).string, "1.\tone\n2.\tthree")
    }

    func testHalfDeletedMarkerEndsTheListItem() {
        let shown = NSMutableAttributedString(attributedString: show(threeItems))
        // Delete just the tab of the second marker.
        let tab = (shown.string as NSString).range(of: "2.\t")
        shown.deleteCharacters(in: NSRange(location: tab.location + 2, length: 1))
        let repaired = fixed(shown)
        let rich = RichTextConverter.richText(from: repaired)
        XCTAssertEqual(rich.paragraphs.map(\.list), [.numbered, nil, .numbered])
        // The leftover "2." becomes ordinary text; the line is no longer a list item and
        // numbering restarts after it.
        XCTAssertEqual(rich.paragraphs[1].runs, [.init(text: "2.two")])
        XCTAssertTrue(repaired.string.hasSuffix("1.\tthree"))
    }

    func testJoiningALineOntoAListItemDropsTheSecondMarker() {
        let shown = NSMutableAttributedString(attributedString: show(threeItems))
        // Forward-delete at the end of "one": removes the line break before the second item.
        let lineBreak = (shown.string as NSString).range(of: "\n")
        shown.deleteCharacters(in: lineBreak)
        XCTAssertEqual(shown.string, "1.\tone2.\ttwo\n3.\tthree")
        let repaired = fixed(shown)
        XCTAssertEqual(repaired.string, "1.\tonetwo\n2.\tthree")
        XCTAssertEqual(RichTextConverter.richText(from: repaired).plainText, "onetwo\nthree")
    }

    func testTextWithListSettingsButNoMarkerBecomesOrdinaryText() {
        // What typing on a new line after a list item can produce before any repair.
        let attributes = TextFormat(list: .bullet, indent: 2).attributes
        let repaired = fixed(NSAttributedString(string: "typed", attributes: attributes))
        XCTAssertEqual(repaired.string, "typed")
        let format = TextFormat(attributes: repaired.attributes(at: 0, effectiveRange: nil))
        XCTAssertNil(format.list)
        XCTAssertEqual(format.indent, 0)
    }

    func testMixedStylesInOneParagraphSettleOnTheFirst() {
        let joined = NSMutableAttributedString()
        joined.append(NSAttributedString(string: "Title", attributes: TextFormat(style: .title).attributes))
        joined.append(NSAttributedString(string: " and body", attributes: TextFormat(style: .body, bold: true).attributes))
        let rich = RichTextConverter.richText(from: fixed(joined))
        XCTAssertEqual(rich.paragraphs, [
            .init(style: .title, runs: [.init(text: "Title"), .init(text: " and body", bold: true)]),
        ])
    }

    func testRepairLeavesImagesInPlace() {
        let image = UUID()
        let shown = NSMutableAttributedString(attributedString: show(RichText(paragraphs: [
            .init(list: .numbered, runs: [.init(text: "a")]),
            .init(list: .numbered, runs: [.init(attachmentID: image), .init(text: "b")]),
        ])))
        shown.deleteCharacters(in: (shown.string as NSString).range(of: "1.\ta\n"))
        let rich = RichTextConverter.richText(from: fixed(shown))
        XCTAssertEqual(rich.attachmentIDs, [image])
        XCTAssertEqual(rich.paragraphs.first?.list, .numbered)
    }
}
