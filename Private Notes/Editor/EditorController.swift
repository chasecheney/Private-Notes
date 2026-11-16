import Foundation
import PrivateNotesEditing
import PrivateNotesStore

#if os(macOS)
import AppKit
typealias PlatformTextView = NSTextView
#else
import UIKit
typealias PlatformTextView = UITextView
#endif

/// The link between the formatting toolbar, the keyboard, and the text view showing one note.
///
/// Every change this class makes goes through `apply`, as whole-range replacements, so the
/// text view, undo, and the note all see it the same way.
@MainActor
final class EditorController {
    enum Trait {
        case bold, italic, underline, strikethrough
    }

    weak var textView: PlatformTextView?
    var onChange: ((RichText) -> Void)?

    /// True while this class is changing the text itself, so the text view's own change
    /// notifications are not mistaken for typing.
    private(set) var isApplyingEdits = false

    // MARK: - Reading the text view

    private var storage: NSTextStorage? {
        textView?.textStorage
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

    private var isComposingText: Bool {
        #if os(macOS)
        return textView?.hasMarkedText() ?? false
        #else
        return textView?.markedTextRange != nil
        #endif
    }

    private var canEdit: Bool {
        textView?.isEditable ?? false
    }

    /// The paragraphs (without their line breaks) that the selection touches.
    private func selectedParagraphs(in storage: NSTextStorage) -> [NSRange] {
        let text = storage.string as NSString
        let selected = selection
        let end = NSMaxRange(selected)
        return ListSupport.paragraphRanges(in: text).filter { range in
            // A selection that ends at the very start of a line does not include that line.
            NSMaxRange(range) >= selected.location
                && (selected.length == 0 ? range.location <= end : range.location < end)
        }
    }

    // MARK: - Hearing about changes

    /// Tells the note that the text changed.
    func contentDidChange() {
        guard let storage else { return }
        onChange?(RichTextConverter.richText(from: storage))
    }

    /// The user typed, deleted, pasted, or used undo.
    func userDidEdit(newlineTyped: Bool) {
        if newlineTyped {
            startBodyTextAfterHeading()
        }
        contentDidChange()
        #if os(macOS)
        // On the Mac this arrives in the middle of the text view finishing its own change;
        // tidy lists up right after it, as a separate undoable step.
        DispatchQueue.main.async { [weak self] in
            self?.tidyLists()
        }
        #else
        tidyLists()
        #endif
    }

    /// The cursor moved.
    func selectionDidChange() {
        guard !isApplyingEdits, let storage else { return }
        let current = selection
        if current.length == 0 {
            // Keep the cursor out of bullets and numbers.
            let paragraph = ListSupport.paragraphRange(containing: current.location, in: storage.string as NSString)
            if let marker = ListSupport.markerRange(inParagraph: paragraph, of: storage),
               current.location < NSMaxRange(marker) {
                selection = NSRange(location: NSMaxRange(marker), length: 0)
            }
        }
        refreshTypingFormat()
    }

    /// Sets what the next typed character will look like from where the cursor is. Typed text
    /// is never tagged as a list marker and never inherits a list from the line above.
    private func refreshTypingFormat() {
        guard let storage, selection.length == 0 else { return }
        let location = min(selection.location, storage.length)
        let paragraph = ListSupport.paragraphRange(containing: location, in: storage.string as NSString)

        if paragraph.length > 0 {
            let index = location > paragraph.location ? location - 1 : location
            typingFormat = TextFormat(attributes: storage.attributes(at: index, effectiveRange: nil))
        } else if paragraph.location > 0 {
            // An empty line takes its style from the line break before it, but is not a list item.
            var format = TextFormat(attributes: storage.attributes(at: paragraph.location - 1, effectiveRange: nil))
            format.list = nil
            format.indent = 0
            typingFormat = format
        } else {
            var format = typingFormat
            format.list = nil
            format.indent = 0
            typingFormat = format
        }
    }

    // MARK: - Formatting commands

    /// Bold, italic, underline, or strikethrough: on the selection, or on what is typed next.
    func toggle(_ trait: Trait) {
        guard canEdit, let storage else { return }
        let range = selection

        guard range.length > 0 else {
            var format = typingFormat
            set(trait, in: &format, to: !value(of: trait, in: format))
            typingFormat = format
            return
        }

        // Turn the trait on unless every selected character already has it.
        var allHaveIt = true
        storage.enumerateAttributes(in: range, options: []) { attributes, _, stop in
            if attributes[.attachment] != nil || attributes[.noteListMarker] != nil { return }
            if !self.value(of: trait, in: TextFormat(attributes: attributes)) {
                allHaveIt = false
                stop.pointee = true
            }
        }
        let newValue = !allHaveIt

        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length), options: []) { attributes, subrange, _ in
            if attributes[.noteListMarker] != nil { return }
            var format = TextFormat(attributes: attributes)
            self.set(trait, in: &format, to: newValue)
            var updated = format.attributes
            if let attachment = attributes[.attachment] {
                updated[.attachment] = attachment
            }
            replacement.setAttributes(updated, range: subrange)
        }
        apply([ListSupport.Edit(range: range, replacement: replacement)])
    }

    /// Title, heading, body and so on: applied to every paragraph the selection touches.
    func setStyle(_ style: RichText.Style) {
        guard canEdit else { return }
        rewriteSelectedParagraphs { $0.style = style }
        var format = typingFormat
        format.style = style
        typingFormat = format
    }

    /// Turns the selected paragraphs into a list of this kind, or back into ordinary text if
    /// they already are one.
    func toggleList(_ kind: RichText.ListKind) {
        guard canEdit, let storage else { return }
        let paragraphs = selectedParagraphs(in: storage)
        let allAreThisKind = !paragraphs.isEmpty && paragraphs.allSatisfy {
            ListSupport.snapshot(ofParagraph: $0, in: storage).list == kind
        }
        rewriteSelectedParagraphs { snapshot in
            if allAreThisKind {
                snapshot.list = nil
                snapshot.indent = 0
            } else {
                snapshot.list = kind
            }
        }
    }

    /// Moves list items in (+1) or out (-1). Returns false if the selection has no list items,
    /// so the key press can do what it normally does.
    @discardableResult
    func changeIndent(by delta: Int) -> Bool {
        guard canEdit, let storage else { return false }
        let hasListItem = selectedParagraphs(in: storage).contains {
            ListSupport.snapshot(ofParagraph: $0, in: storage).list != nil
        }
        guard hasListItem else { return false }
        rewriteSelectedParagraphs { snapshot in
            guard snapshot.list != nil else { return }
            snapshot.indent = min(max(snapshot.indent + delta, 0), RichText.Paragraph.maximumIndent)
        }
        return true
    }

    /// Puts an image at the cursor, on a line of its own.
    func insertImage(id: UUID, image: PlatformImage) {
        guard canEdit, let storage else { return }
        let range = selection
        var format = typingFormat
        format.style = format.style == .monospaced ? .monospaced : .body
        format.list = nil
        format.indent = 0

        let insertion = NSMutableAttributedString()
        let text = storage.string as NSString
        if range.location > 0, text.character(at: range.location - 1) != 10 {
            insertion.append(NSAttributedString(string: "\n", attributes: format.attributes))
        }
        insertion.append(RichTextConverter.imageString(id: id, image: image, format: format))
        insertion.append(NSAttributedString(string: "\n", attributes: format.attributes))

        apply(
            [ListSupport.Edit(range: range, replacement: insertion)],
            selectionAfter: NSRange(location: range.location + insertion.length, length: 0)
        )
        typingFormat = format
    }

    // MARK: - Keys the text view asks about

    /// Return. In a list: a new item, or the end of the list if the current item is empty.
    /// Returns false when not in a list, so Return does what it normally does.
    func handleReturn() -> Bool {
        guard canEdit, let storage, !isComposingText else { return false }
        var caret = selection
        var paragraph = ListSupport.paragraphRange(containing: caret.location, in: storage.string as NSString)
        guard ListSupport.markerRange(inParagraph: paragraph, of: storage) != nil else { return false }

        if caret.length > 0 {
            // Replace the selection first, then carry on as if the cursor were there.
            apply(
                [ListSupport.Edit(range: caret, replacement: NSAttributedString())],
                selectionAfter: NSRange(location: caret.location, length: 0),
                tidy: false
            )
            caret = selection
            paragraph = ListSupport.paragraphRange(containing: caret.location, in: storage.string as NSString)
        }
        guard let marker = ListSupport.markerRange(inParagraph: paragraph, of: storage) else { return false }
        let snapshot = ListSupport.snapshot(ofParagraph: paragraph, in: storage)
        guard let list = snapshot.list else { return false }

        if snapshot.content.length == 0 {
            // Return on an empty item ends the list.
            apply(
                [ListSupport.Edit(range: paragraph, replacement: NSAttributedString())],
                selectionAfter: NSRange(location: paragraph.location, length: 0)
            )
            typingFormat = TextFormat(style: snapshot.style)
            return true
        }

        let itemFormat = TextFormat(style: snapshot.style, list: list, indent: snapshot.indent)
        let insertion = NSMutableAttributedString(string: "\n", attributes: itemFormat.attributes)
        insertion.append(NSAttributedString(
            string: ListSupport.markerText(list, number: 1),
            attributes: itemFormat.markerAttributes
        ))
        let location = max(caret.location, NSMaxRange(marker))
        apply(
            [ListSupport.Edit(range: NSRange(location: location, length: 0), replacement: insertion)],
            selectionAfter: NSRange(location: location + insertion.length, length: 0)
        )
        return true
    }

    /// Backspace. Right after a bullet or number it removes the bullet, leaving the text.
    func handleBackspace() -> Bool {
        guard canEdit, let storage, !isComposingText else { return false }
        let caret = selection
        guard caret.length == 0 else { return false }
        let paragraph = ListSupport.paragraphRange(containing: caret.location, in: storage.string as NSString)
        guard let marker = ListSupport.markerRange(inParagraph: paragraph, of: storage),
              caret.location <= NSMaxRange(marker)
        else { return false }

        rewriteSelectedParagraphs { snapshot in
            snapshot.list = nil
            snapshot.indent = 0
        }
        return true
    }

    // MARK: - Applying changes

    /// Takes each selected paragraph apart, lets `change` adjust it, and puts it back.
    private func rewriteSelectedParagraphs(_ change: (inout ParagraphSnapshot) -> Void) {
        guard let storage else { return }
        let edits = selectedParagraphs(in: storage).map { range -> ListSupport.Edit in
            var snapshot = ListSupport.snapshot(ofParagraph: range, in: storage)
            change(&snapshot)
            // Numbers are put right by the tidy-up that follows.
            return ListSupport.Edit(range: range, replacement: ListSupport.render(snapshot, number: 1))
        }
        apply(edits)
    }

    /// Fixes list numbers and anything else that drifted (see `ListSupport.normalizationEdits`).
    private func tidyLists() {
        guard canEdit, !isApplyingEdits, !isComposingText, let storage else { return }
        let edits = ListSupport.normalizationEdits(for: storage)
        guard !edits.isEmpty else { return }
        apply(edits, tidy: false)
    }

    /// Replaces ranges of the text. The selection follows the text it was in unless
    /// `selectionAfter` says where it should go.
    private func apply(_ edits: [ListSupport.Edit], selectionAfter: NSRange? = nil, tidy: Bool = true) {
        guard let textView, let storage, !edits.isEmpty else { return }
        let ordered = edits.sorted { $0.range.location < $1.range.location }
        let before = selection
        let start = Self.position(before.location, after: ordered)
        let end = Self.position(NSMaxRange(before), after: ordered)
        let mapped = NSRange(location: start, length: max(end - start, 0))

        isApplyingEdits = true
        #if os(macOS)
        for edit in ordered.reversed()
        where textView.shouldChangeText(in: edit.range, replacementString: edit.replacement.string) {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
        }
        #else
        storage.beginEditing()
        for edit in ordered.reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
        // The text view's undo history no longer matches the text; clearing it avoids undo
        // putting text back in the wrong place.
        textView.undoManager?.removeAllActions()
        #endif

        let target = selectionAfter ?? mapped
        let length = storage.length
        let location = min(max(target.location, 0), length)
        selection = NSRange(location: location, length: min(target.length, length - location))
        isApplyingEdits = false

        refreshTypingFormat()
        if tidy {
            tidyLists()
        }
        contentDidChange()
    }

    /// Where a character position ends up once the edits (in ascending order) are made.
    private static func position(_ position: Int, after edits: [ListSupport.Edit]) -> Int {
        var shift = 0
        for edit in edits {
            let delta = edit.replacement.length - edit.range.length
            if position > NSMaxRange(edit.range) {
                shift += delta
            } else if position >= edit.range.location {
                // Inside the replaced text: move with it, but stay inside the replacement.
                let moved = position + delta
                let low = edit.range.location
                let high = edit.range.location + edit.replacement.length
                return min(max(moved, low), high) + shift
            } else {
                break
            }
        }
        return position + shift
    }

    // MARK: - Helpers

    /// After Return at the end of a title or heading, the new line starts as body text.
    private func startBodyTextAfterHeading() {
        guard let storage else { return }
        let location = selection.location
        guard selection.length == 0, location > 0, location <= storage.length else { return }
        let text = storage.string as NSString
        guard text.character(at: location - 1) == 10 else { return }

        let format = TextFormat(attributes: storage.attributes(at: location - 1, effectiveRange: nil))
        guard format.list == nil else { return }
        switch format.style {
        case .title, .heading, .subheading:
            // Only at the end of the line; splitting a heading keeps both halves headings.
            guard location == text.length || text.character(at: location) == 10 else { return }
            let body = TextFormat(style: .body)
            storage.setAttributes(body.attributes, range: NSRange(location: location - 1, length: 1))
            typingFormat = body
        case .body, .monospaced:
            break
        }
    }

    private func value(of trait: Trait, in format: TextFormat) -> Bool {
        switch trait {
        case .bold: return format.bold
        case .italic: return format.italic
        case .underline: return format.underline
        case .strikethrough: return format.strikethrough
        }
    }

    private func set(_ trait: Trait, in format: inout TextFormat, to value: Bool) {
        switch trait {
        case .bold: format.bold = value
        case .italic: format.italic = value
        case .underline: format.underline = value
        case .strikethrough: format.strikethrough = value
        }
    }
}
