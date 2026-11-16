import Foundation
import PrivateNotesStore

/// One paragraph of the text view, taken apart: what kind of list item it is (if any) and its
/// content without the bullet or number.
public struct ParagraphSnapshot {
    public var style: RichText.Style
    public var list: RichText.ListKind?
    public var indent: Int
    public var content: NSAttributedString

    public init(style: RichText.Style = .body, list: RichText.ListKind? = nil, indent: Int = 0,
                content: NSAttributedString = NSAttributedString()) {
        self.style = style
        self.list = list
        self.indent = indent
        self.content = content
    }
}

/// Lists in the text view.
///
/// A list item's bullet or number is real text at the start of its paragraph ("•", a tab),
/// tagged with `.noteListMarker`. That keeps drawing simple and identical on every platform.
/// The marker is never part of the stored note: it is added when a note is shown and left
/// out when it is read back.
public enum ListSupport {
    public static let indentStep: CGFloat = 22

    /// A replacement of part of the text.
    public struct Edit {
        public var range: NSRange
        public var replacement: NSAttributedString

        public init(range: NSRange, replacement: NSAttributedString) {
            self.range = range
            self.replacement = replacement
        }
    }

    // MARK: - Markers

    public static func markerText(_ kind: RichText.ListKind, number: Int) -> String {
        switch kind {
        case .bullet: return "•\t"
        case .dash: return "–\t"
        case .numbered: return "\(max(number, 1)).\t"
        }
    }

    static func isMarkerText(_ text: String) -> Bool {
        kind(ofMarkerText: text) != nil
    }

    static func kind(ofMarkerText text: String) -> RichText.ListKind? {
        if text == "•\t" { return .bullet }
        if text == "–\t" { return .dash }
        guard text.hasSuffix(".\t") else { return nil }
        let digits = text.dropLast(2)
        return !digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? .numbered : nil
    }

    // MARK: - Paragraphs

    /// The range of every paragraph, without its line break. An empty text is one empty paragraph.
    public static func paragraphRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let remaining = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", options: [], range: remaining)
            let end = newline.location == NSNotFound ? text.length : newline.location
            ranges.append(NSRange(location: start, length: end - start))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return ranges
    }

    /// The paragraph (without its line break) that the character position falls in.
    public static func paragraphRange(containing location: Int, in text: NSString) -> NSRange {
        let position = min(max(location, 0), text.length)
        var start = position
        while start > 0, text.character(at: start - 1) != 10 { start -= 1 }
        var end = position
        while end < text.length, text.character(at: end) != 10 { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The bullet or number at the start of the paragraph, if it has a complete one.
    public static func markerRange(inParagraph range: NSRange, of attributed: NSAttributedString) -> NSRange? {
        let text = attributed.string as NSString
        let end = min(NSMaxRange(range), text.length)
        var index = range.location
        while index < end {
            guard attributed.attribute(.noteListMarker, at: index, effectiveRange: nil) != nil else { return nil }
            if text.character(at: index) == 9 {
                let candidate = NSRange(location: range.location, length: index - range.location + 1)
                return isMarkerText(text.substring(with: candidate)) ? candidate : nil
            }
            index += 1
        }
        return nil
    }

    public static func snapshot(ofParagraph range: NSRange, in attributed: NSAttributedString) -> ParagraphSnapshot {
        let text = attributed.string as NSString
        var snapshot = ParagraphSnapshot()
        var contentRange = range
        var markerStyle: RichText.Style?

        if let marker = markerRange(inParagraph: range, of: attributed) {
            let format = TextFormat(attributes: attributed.attributes(at: marker.location, effectiveRange: nil))
            snapshot.list = format.list ?? kind(ofMarkerText: text.substring(with: marker))
            snapshot.indent = format.indent
            markerStyle = format.style
            contentRange = NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker))
        }

        let content = NSMutableAttributedString()
        if contentRange.length > 0 {
            attributed.enumerateAttributes(in: contentRange, options: []) { attributes, subrange, _ in
                // A bullet or number that ended up in the middle of a line (two lines were joined)
                // is leftover decoration, not content.
                if attributes[.noteListMarker] != nil, isMarkerText(text.substring(with: subrange)) {
                    return
                }
                content.append(attributed.attributedSubstring(from: subrange))
            }
        }
        snapshot.content = content

        if content.length > 0 {
            snapshot.style = TextFormat(attributes: content.attributes(at: 0, effectiveRange: nil)).style
        } else {
            snapshot.style = markerStyle ?? .body
        }
        return snapshot
    }

    /// The paragraph as it should appear: marker first (for a list item), then the content with
    /// the paragraph's style, list kind, and indent applied to all of it.
    public static func render(_ snapshot: ParagraphSnapshot, number: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let indent = snapshot.list == nil ? 0 : snapshot.indent
        if let list = snapshot.list {
            output.append(NSAttributedString(
                string: markerText(list, number: number),
                attributes: TextFormat(style: snapshot.style, list: list, indent: indent).markerAttributes
            ))
        }

        let content = snapshot.content
        guard content.length > 0 else { return output }
        let text = content.string as NSString
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length), options: []) { attributes, subrange, _ in
            var format = TextFormat(attributes: attributes)
            format.style = snapshot.style
            format.list = snapshot.list
            format.indent = indent
            var updated = format.attributes
            if let attachment = attributes[.attachment] {
                updated[.attachment] = attachment
            }
            output.append(NSAttributedString(string: text.substring(with: subrange), attributes: updated))
        }
        return output
    }

    /// The number each paragraph would show if it is a numbered item (1 otherwise). Numbering
    /// continues down a run of items at the same depth and restarts after anything else.
    public static func numbers(for paragraphs: [(list: RichText.ListKind?, indent: Int)]) -> [Int] {
        var counters: [Int: Int] = [:]
        var result: [Int] = []
        for paragraph in paragraphs {
            guard let list = paragraph.list else {
                counters.removeAll()
                result.append(1)
                continue
            }
            counters = counters.filter { $0.key <= paragraph.indent }
            if list == .numbered {
                let next = (counters[paragraph.indent] ?? 0) + 1
                counters[paragraph.indent] = next
                result.append(next)
            } else {
                counters[paragraph.indent] = nil
                result.append(1)
            }
        }
        return result
    }

    // MARK: - Keeping the text view consistent

    /// The changes needed so that every paragraph looks the way `render` would draw it: right
    /// numbers, no half-deleted or stray markers, and one style and list setting per paragraph.
    /// Empty when the text is already consistent.
    public static func normalizationEdits(for attributed: NSAttributedString) -> [Edit] {
        let ranges = paragraphRanges(in: attributed.string as NSString)
        let snapshots = ranges.map { snapshot(ofParagraph: $0, in: attributed) }
        let numbers = numbers(for: snapshots.map { (list: $0.list, indent: $0.indent) })

        var edits: [Edit] = []
        for (index, range) in ranges.enumerated() {
            let rendered = render(snapshots[index], number: numbers[index])
            let wanted = signature(of: rendered, in: NSRange(location: 0, length: rendered.length))
            if wanted != signature(of: attributed, in: range) {
                edits.append(Edit(range: range, replacement: rendered))
            }
        }
        return edits
    }

    /// What a stretch of text means, ignoring exactly which font and color objects carry it.
    private struct Piece: Equatable {
        var text: String
        var format: TextFormat
        var isMarker: Bool
        var attachment: ObjectIdentifier?
    }

    private static func signature(of attributed: NSAttributedString, in range: NSRange) -> [Piece] {
        guard range.length > 0 else { return [] }
        let text = attributed.string as NSString
        var pieces: [Piece] = []
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let piece = Piece(
                text: text.substring(with: subrange),
                format: TextFormat(attributes: attributes),
                isMarker: attributes[.noteListMarker] != nil,
                attachment: attributes[.attachment].map { ObjectIdentifier($0 as AnyObject) }
            )
            if let last = pieces.last, last.attachment == nil, piece.attachment == nil,
               last.format == piece.format, last.isMarker == piece.isMarker {
                pieces[pieces.count - 1].text += piece.text
            } else {
                pieces.append(piece)
            }
        }
        return pieces
    }
}
