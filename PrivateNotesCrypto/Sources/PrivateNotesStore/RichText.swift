import Foundation

/// A note's formatted content, stored in a form that means the same thing on every platform:
/// paragraphs with a style, made of runs of text with bold/italic/underline/strikethrough,
/// plus inline images referenced by id. Fonts, sizes, and colors are decided when it is shown.
public struct RichText: Codable, Equatable, Hashable, Sendable {
    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph] = []) {
        self.paragraphs = paragraphs
    }

    public enum Style: String, Codable, CaseIterable, Sendable {
        case title
        case heading
        case subheading
        case body
        case monospaced
    }

    public enum ListKind: String, Codable, CaseIterable, Sendable {
        case bullet
        case dash
        case numbered
    }

    public struct Paragraph: Codable, Equatable, Hashable, Sendable {
        public static let maximumIndent = 6

        public var style: Style
        /// Set when this paragraph is a list item. The bullet or number is not part of `runs`.
        public var list: ListKind?
        /// Nesting depth of a list item, 0 for the outermost level.
        public var indent: Int
        public var runs: [Run]

        public init(style: Style = .body, list: ListKind? = nil, indent: Int = 0, runs: [Run] = []) {
            self.style = style
            self.list = list
            self.indent = min(max(indent, 0), Self.maximumIndent)
            self.runs = runs
        }

        private enum CodingKeys: String, CodingKey { case style, list, indent, runs }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Unknown values from a newer version fall back to plain body text instead of failing the note.
            let rawStyle = try values.decodeIfPresent(String.self, forKey: .style)
            self.style = rawStyle.flatMap(Style.init(rawValue:)) ?? .body
            let rawList = try values.decodeIfPresent(String.self, forKey: .list)
            self.list = rawList.flatMap(ListKind.init(rawValue:))
            let rawIndent = try values.decodeIfPresent(Int.self, forKey: .indent) ?? 0
            self.indent = min(max(rawIndent, 0), Self.maximumIndent)
            self.runs = try values.decodeIfPresent([Run].self, forKey: .runs) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(style.rawValue, forKey: .style)
            try values.encodeIfPresent(list?.rawValue, forKey: .list)
            if indent > 0 { try values.encode(indent, forKey: .indent) }
            try values.encode(runs, forKey: .runs)
        }
    }

    public struct Run: Codable, Equatable, Hashable, Sendable {
        /// The characters. Empty for an image.
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strikethrough: Bool
        /// Set when this run is an inline image; the id of its encrypted attachment.
        public var attachmentID: UUID?

        public init(
            text: String = "",
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            strikethrough: Bool = false,
            attachmentID: UUID? = nil
        ) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
            self.attachmentID = attachmentID
        }

        private enum CodingKeys: String, CodingKey {
            case text, bold, italic, underline, strikethrough, attachmentID
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
            self.bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            self.italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            self.underline = try values.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            self.strikethrough = try values.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
            self.attachmentID = try values.decodeIfPresent(UUID.self, forKey: .attachmentID)
        }

        public func encode(to encoder: Encoder) throws {
            // Only what is set is written, to keep notes small.
            var values = encoder.container(keyedBy: CodingKeys.self)
            if !text.isEmpty { try values.encode(text, forKey: .text) }
            if bold { try values.encode(true, forKey: .bold) }
            if italic { try values.encode(true, forKey: .italic) }
            if underline { try values.encode(true, forKey: .underline) }
            if strikethrough { try values.encode(true, forKey: .strikethrough) }
            try values.encodeIfPresent(attachmentID, forKey: .attachmentID)
        }

        /// True when the two runs are formatted the same way and could be one run.
        func hasSameFormatting(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic
                && underline == other.underline && strikethrough == other.strikethrough
        }
    }

    /// Unformatted text: one body paragraph per line.
    public init(plainText: String) {
        let unified = plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.paragraphs = unified.components(separatedBy: "\n").map { line in
            Paragraph(style: .body, runs: line.isEmpty ? [] : [Run(text: line)])
        }
    }

    /// The text without formatting, one line per paragraph. Images contribute nothing.
    /// Used for titles, previews, and search.
    public var plainText: String {
        paragraphs
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// Ids of every inline image, in order.
    public var attachmentIDs: [UUID] {
        paragraphs.flatMap { $0.runs.compactMap(\.attachmentID) }
    }

    /// The same content in its simplest form: no empty runs, neighbouring runs with identical
    /// formatting merged, and no line breaks hiding inside a run.
    public func normalized() -> RichText {
        RichText(paragraphs: paragraphs.map { paragraph in
            var merged: [Run] = []
            for var run in paragraph.runs {
                if run.attachmentID != nil {
                    run.text = ""
                    merged.append(run)
                    continue
                }
                run.text = run.text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                if run.text.isEmpty { continue }
                if let last = merged.last, last.attachmentID == nil, last.hasSameFormatting(as: run) {
                    merged[merged.count - 1].text += run.text
                } else {
                    merged.append(run)
                }
            }
            return Paragraph(
                style: paragraph.style,
                list: paragraph.list,
                indent: paragraph.list == nil ? 0 : paragraph.indent,
                runs: merged
            )
        })
    }
}
