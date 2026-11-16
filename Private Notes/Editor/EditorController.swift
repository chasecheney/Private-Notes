import Foundation
import PrivateNotesStore

#if os(macOS)
import AppKit
typealias PlatformTextView = NSTextView
#else
import UIKit
typealias PlatformTextView = UITextView
#endif

/// The link between the formatting toolbar and the text view showing one note.
@MainActor
final class EditorController {
    enum Trait {
        case bold, italic, underline, strikethrough
    }

    weak var textView: PlatformTextView?
    var onChange: ((RichText) -> Void)?

    // MARK: - Reading the text view

    private var storage: NSTextStorage? {
        #if os(macOS)
        return textView?.textStorage
        #else
        return textView?.textStorage
        #endif
    }

    private var selection: NSRange {
        get {
            #if os(macOS)
            return textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            #else
            return textView?.selectedRange ?? NSRange(location: 0, length: 0)
            #endif
        }
        set {
            #if os(macOS)
            textView?.setSelectedRange(newValue)
            #else
            textView?.selectedRange = newValue
            #endif
        }
    }

    private var typingFormat: TextFormat {
        get { TextFormat(attributes: textView?.typingAttributes ?? [:]) }
        set { textView?.typingAttributes = newValue.attributes }
    }

    /// Tells the note that the text changed.
    func contentDidChange() {
        guard let storage else { return }
        onChange?(RichTextConverter.richText(from: storage))
    }

    // MARK: - Formatting commands

    /// Bold, italic, underline, or strikethrough: on the selection, or on what is typed next.
    func toggle(_ trait: Trait) {
        guard let textView, textView.isEditable, let storage else { return }
        let range = selection

        guard range.length > 0 else {
            var format = typingFormat
            flip(trait, in: &format, to: !value(of: trait, in: format))
            typingFormat = format
            return
        }

        // Turn the trait on unless every selected character already has it.
        var allHaveIt = true
        storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if attributes[.attachment] != nil { return }
            if !self.value(of: trait, in: TextFormat(attributes: attributes)) {
                allHaveIt = false
                stop.pointee = true
            }
        }
        let newValue = !allHaveIt

        edit(range) {
            self.reformat(range, in: storage) { self.flip(trait, in: &$0, to: newValue) }
        }
        var format = typingFormat
        flip(trait, in: &format, to: newValue)
        typingFormat = format
    }

    /// Title, heading, body and so on: applied to every paragraph the selection touches.
    func setStyle(_ style: RichText.Style) {
        guard let textView, textView.isEditable, let storage else { return }
        let paragraphs = (storage.string as NSString).paragraphRange(for: selection)

        if paragraphs.length > 0 {
            edit(paragraphs) {
                self.reformat(paragraphs, in: storage) { $0.style = style }
            }
        }
        var format = typingFormat
        format.style = style
        typingFormat = format
    }

    /// Puts an image at the cursor, on a line of its own.
    func insertImage(id: UUID, image: PlatformImage) {
        guard let textView, textView.isEditable, let storage else { return }
        let range = selection
        var format = typingFormat
        format.style = format.style == .monospaced ? .monospaced : .body

        let insertion = NSMutableAttributedString()
        let text = storage.string as NSString
        if range.location > 0, text.character(at: range.location - 1) != 10 {
            insertion.append(NSAttributedString(string: "\n", attributes: format.attributes))
        }
        insertion.append(RichTextConverter.imageString(id: id, image: image, format: format))
        insertion.append(NSAttributedString(string: "\n", attributes: format.attributes))

        #if os(macOS)
        textView.insertText(insertion, replacementRange: range)
        #else
        storage.replaceCharacters(in: range, with: insertion)
        selection = NSRange(location: range.location + insertion.length, length: 0)
        contentDidChange()
        #endif
        typingFormat = format
    }

    /// After Return at the end of a title or heading, the new line starts as body text.
    func newlineWasTyped() {
        guard let storage else { return }
        let location = selection.location
        guard selection.length == 0, location > 0, location <= storage.length else { return }
        let newlineRange = NSRange(location: location - 1, length: 1)
        guard (storage.string as NSString).character(at: location - 1) == 10 else { return }

        var format = TextFormat(attributes: storage.attributes(at: location - 1, effectiveRange: nil))
        switch format.style {
        case .title, .heading, .subheading:
            // Only when the cursor is at the end of the line; splitting a heading keeps both halves headings.
            let text = storage.string as NSString
            guard location == text.length || text.character(at: location) == 10 else { return }
            format = TextFormat(style: .body)
            storage.setAttributes(format.attributes, range: newlineRange)
            typingFormat = format
        case .body, .monospaced:
            break
        }
    }

    // MARK: - Helpers

    private func value(of trait: Trait, in format: TextFormat) -> Bool {
        switch trait {
        case .bold: return format.bold
        case .italic: return format.italic
        case .underline: return format.underline
        case .strikethrough: return format.strikethrough
        }
    }

    private func flip(_ trait: Trait, in format: inout TextFormat, to value: Bool) {
        switch trait {
        case .bold: format.bold = value
        case .italic: format.italic = value
        case .underline: format.underline = value
        case .strikethrough: format.strikethrough = value
        }
    }

    /// Rewrites the attributes of every stretch of text in the range, leaving images in place.
    private func reformat(_ range: NSRange, in storage: NSTextStorage, change: (inout TextFormat) -> Void) {
        var pieces: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            var format = TextFormat(attributes: attributes)
            change(&format)
            var updated = format.attributes
            if let attachment = attributes[.attachment] {
                updated[.attachment] = attachment
            }
            pieces.append((subrange, updated))
        }
        for (subrange, attributes) in pieces {
            storage.setAttributes(attributes, range: subrange)
        }
    }

    /// Runs a change to the text storage so the text view, undo (on the Mac), and the note all hear about it.
    private func edit(_ range: NSRange, _ change: () -> Void) {
        guard let textView, let storage else { return }
        #if os(macOS)
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change()
        storage.endEditing()
        textView.didChangeText()
        #else
        let saved = selection
        storage.beginEditing()
        change()
        storage.endEditing()
        selection = saved
        contentDidChange()
        #endif
    }
}
