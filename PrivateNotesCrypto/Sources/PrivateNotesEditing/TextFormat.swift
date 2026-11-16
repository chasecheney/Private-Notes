import Foundation
import PrivateNotesStore

#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

public extension NSAttributedString.Key {
    /// The paragraph style name (`RichText.Style` raw value) this text was given.
    static let noteStyle = NSAttributedString.Key("privatenotes.style")
    /// Whether the user made this text bold. Titles are drawn bold without this being set.
    static let noteBold = NSAttributedString.Key("privatenotes.bold")
    static let noteItalic = NSAttributedString.Key("privatenotes.italic")
    /// The list kind (`RichText.ListKind` raw value) of the paragraph this text is in.
    static let noteList = NSAttributedString.Key("privatenotes.list")
    /// The list nesting depth of the paragraph this text is in.
    static let noteIndent = NSAttributedString.Key("privatenotes.indent")
    /// Marks the bullet or number at the start of a list item. It is shown in the text view
    /// but is not part of the note's content.
    static let noteListMarker = NSAttributedString.Key("privatenotes.listMarker")
}

/// The formatting of one stretch of text, in the note's own terms.
public struct TextFormat: Equatable {
    public var style: RichText.Style
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var list: RichText.ListKind?
    public var indent: Int

    public init(
        style: RichText.Style = .body,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        list: RichText.ListKind? = nil,
        indent: Int = 0
    ) {
        self.style = style
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.list = list
        self.indent = indent
    }

    /// Reads the formatting back from text-view attributes.
    public init(attributes: [NSAttributedString.Key: Any]) {
        let font = attributes[.font] as? PlatformFont
        style = (attributes[.noteStyle] as? String).flatMap(RichText.Style.init(rawValue:)) ?? .body
        bold = attributes[.noteBold] as? Bool ?? (font.map(NoteFonts.isBold) ?? false)
        italic = attributes[.noteItalic] as? Bool ?? (font.map(NoteFonts.isItalic) ?? false)
        underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        list = (attributes[.noteList] as? String).flatMap(RichText.ListKind.init(rawValue:))
        let rawIndent = attributes[.noteIndent] as? Int ?? 0
        indent = min(max(rawIndent, 0), RichText.Paragraph.maximumIndent)
    }

    /// The complete set of text-view attributes for this formatting. Always a full set, so
    /// applying it replaces whatever fonts and colors were there before.
    public var attributes: [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: NoteFonts.font(style: style, bold: bold, italic: italic),
            .foregroundColor: NoteFonts.textColor,
            .paragraphStyle: paragraphStyle,
            .noteStyle: style.rawValue,
            .noteBold: bold,
            .noteItalic: italic,
        ]
        if underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let list {
            result[.noteList] = list.rawValue
            result[.noteIndent] = indent
        }
        return result
    }

    /// Attributes for the bullet or number of a list item with this formatting.
    public var markerAttributes: [NSAttributedString.Key: Any] {
        var plain = self
        plain.bold = false
        plain.italic = false
        plain.underline = false
        plain.strikethrough = false
        var result = plain.attributes
        result[.noteListMarker] = true
        result[.foregroundColor] = NoteFonts.markerColor
        return result
    }

    private var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        switch style {
        case .title: paragraph.paragraphSpacing = 8
        case .heading, .subheading: paragraph.paragraphSpacing = 6
        case .body, .monospaced: paragraph.paragraphSpacing = 3
        }
        if let list {
            // The marker sits at the first-line indent; a tab after it moves to where the text
            // starts, and wrapped lines line up with the text, not the marker.
            let markerStart = CGFloat(indent) * ListSupport.indentStep + 4
            let textStart = markerStart + (list == .numbered ? 30 : 22)
            paragraph.firstLineHeadIndent = markerStart
            paragraph.headIndent = textStart
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
            paragraph.defaultTabInterval = 28
            paragraph.paragraphSpacing = 2
        }
        return paragraph
    }
}

enum NoteFonts {
    static var textColor: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    static var markerColor: PlatformColor {
        #if os(macOS)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    /// Body text size for this platform.
    static var baseSize: CGFloat {
        #if os(macOS)
        return 14
        #else
        return UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
    }

    static func font(style: RichText.Style, bold: Bool, italic: Bool) -> PlatformFont {
        let size: CGFloat
        let weight: PlatformFont.Weight
        switch style {
        case .title:
            size = baseSize * 1.7
            weight = .bold
        case .heading:
            size = baseSize * 1.35
            weight = .bold
        case .subheading:
            size = baseSize * 1.12
            weight = .semibold
        case .body:
            size = baseSize
            weight = .regular
        case .monospaced:
            size = baseSize * 0.95
            weight = .regular
        }
        let finalWeight: PlatformFont.Weight = bold ? (style == .title || style == .heading ? .heavy : .bold) : weight

        var font: PlatformFont
        if style == .monospaced {
            font = .monospacedSystemFont(ofSize: size, weight: finalWeight)
        } else {
            font = .systemFont(ofSize: size, weight: finalWeight)
        }
        if italic {
            font = italicized(font)
        }
        return font
    }

    private static func italicized(_ font: PlatformFont) -> PlatformFont {
        #if os(macOS)
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    static func isBold(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    static func isItalic(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }
}

/// An inline image in the editor. Remembers which encrypted attachment it shows.
public final class NoteImageAttachment: NSTextAttachment {
    public static let maximumWidth: CGFloat = 420

    public let attachmentID: UUID

    public init(id: UUID, image: PlatformImage?) {
        attachmentID = id
        super.init(data: nil, ofType: nil)
        let shown = image ?? Self.placeholder
        self.image = shown
        if let shown {
            let size = shown.size
            let scale = size.width > Self.maximumWidth ? Self.maximumWidth / size.width : 1
            bounds = CGRect(x: 0, y: 0, width: max(size.width * scale, 1), height: max(size.height * scale, 1))
        }
    }

    public required init?(coder: NSCoder) {
        attachmentID = UUID()
        super.init(coder: coder)
    }

    /// Shown when the image file is missing or can't be opened.
    private static var placeholder: PlatformImage? {
        #if os(macOS)
        return NSImage(systemSymbolName: "photo", accessibilityDescription: "Missing image")
        #else
        return UIImage(systemName: "photo")
        #endif
    }
}
