import PrivateNotesEditing
import PrivateNotesStore
import SwiftUI

/// The note editor: a native text view (so images can sit inline), wrapped for SwiftUI.
///
/// The text is loaded once, when the view is created. Give the view a different `.id` to show
/// a different note. Typed and pasted text always takes the note's own fonts and colors:
/// formatting from other apps is not brought in. Copying out is ordinary copying: nothing
/// expires and nothing is held back.
@MainActor
struct RichTextEditor {
    let initialText: RichText
    let isEditable: Bool
    let controller: EditorController
    /// Loads a decrypted image for display.
    let loadImage: (UUID) -> PlatformImage?
    let onChange: (RichText) -> Void
    /// An image was pasted; the bytes are handed over to be stored and then inserted.
    let onPasteImage: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    fileprivate func load(into textView: PlatformTextView) {
        let content = RichTextConverter.attributedString(from: initialText, image: loadImage)
        #if os(macOS)
        textView.textStorage?.setAttributedString(content)
        #else
        textView.attributedText = content
        #endif
        // What typing looks like in an empty note, or after the last character.
        let last = initialText.paragraphs.last
        let lastStyle = last.flatMap { $0.runs.isEmpty && $0.list == nil ? nil : $0.style } ?? .body
        textView.typingAttributes = TextFormat(
            style: lastStyle,
            list: last?.list,
            indent: last?.list == nil ? 0 : (last?.indent ?? 0)
        ).attributes
    }

    fileprivate func connect(_ textView: NoteTextView) {
        textView.onPasteImage = onPasteImage
        textView.onFormatShortcut = { [controller] trait in controller.toggle(trait) }
        textView.onOutdent = { [controller] in controller.changeIndent(by: -1) }
        controller.textView = textView
        controller.onChange = onChange
    }
}

#if os(macOS)
import AppKit

extension RichTextEditor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 12)

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true

        load(into: textView)
        textView.delegate = context.coordinator
        connect(textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        textView.onPasteImage = onPasteImage
        controller.onChange = onChange
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: EditorController
        private var newlineTyped = false

        init(controller: EditorController) {
            self.controller = controller
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if !controller.isApplyingEdits {
                newlineTyped = replacementString == "\n"
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !controller.isApplyingEdits else { return }
            let wasNewline = newlineTyped
            newlineTyped = false
            controller.userDidEdit(newlineTyped: wasNewline)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.selectionDidChange()
        }

        /// Return, Tab, Shift-Tab, and Backspace behave differently inside a list.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return controller.handleReturn()
            case #selector(NSResponder.insertTab(_:)):
                return controller.changeIndent(by: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return controller.changeIndent(by: -1)
            case #selector(NSResponder.deleteBackward(_:)):
                return controller.handleBackspace()
            default:
                return false
            }
        }
    }
}

/// The Mac text view: pastes plain text (taking the note's formatting), hands pasted images
/// to the app, copies clean text for other apps, and handles the formatting shortcuts.
final class NoteTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?
    /// Command-B, Command-I, or Command-U was pressed while typing in this view.
    var onFormatShortcut: ((EditorController.Trait) -> Void)?
    var onOutdent: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, modifiers == .command, isEditable, window?.firstResponder === self {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b":
                onFormatShortcut?(.bold)
                return true
            case "i":
                onFormatShortcut?(.italic)
                return true
            case "u":
                onFormatShortcut?(.underline)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.string]) != nil {
            pasteAsPlainText(sender)
        } else if isEditable,
                  let image = NSImage(pasteboard: pasteboard),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func copy(_ sender: Any?) {
        if !writeSelectionToClipboard() {
            super.copy(sender)
        }
    }

    override func cut(_ sender: Any?) {
        guard isEditable, writeSelectionToClipboard() else {
            super.cut(sender)
            return
        }
        delete(sender)
    }

    /// Puts only the plain text of the selection on the clipboard.
    @objc func copyWithoutFormatting(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let textStorage else { return }
        let exported = ClipboardText.export(textStorage.attributedSubstring(from: range))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exported.plain, forType: .string)
    }

    /// Adds "Copy Without Formatting" to the right-click menu, under Copy.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        guard selectedRange().length > 0 else { return menu }
        let item = NSMenuItem(
            title: "Copy Without Formatting",
            action: #selector(copyWithoutFormatting(_:)),
            keyEquivalent: ""
        )
        item.target = self
        let copyIndex = menu.items.firstIndex { $0.action == #selector(NSText.copy(_:)) }
        menu.insertItem(item, at: copyIndex.map { $0 + 1 } ?? 0)
        return menu
    }

    private func writeSelectionToClipboard() -> Bool {
        let range = selectedRange()
        guard range.length > 0, let textStorage else { return false }
        let exported = ClipboardText.export(textStorage.attributedSubstring(from: range))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exported.plain, forType: .string)
        if let rtf = exported.rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
        return true
    }
}

#else
import UIKit
import UniformTypeIdentifiers

extension RichTextEditor: UIViewRepresentable {
    func makeUIView(context: Context) -> NoteTextView {
        let textView = NoteTextView(frame: .zero, textContainer: nil)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.allowsEditingTextAttributes = false
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.dataDetectorTypes = []
        textView.isEditable = isEditable
        textView.isSelectable = true

        load(into: textView)
        textView.delegate = context.coordinator
        connect(textView)
        return textView
    }

    func updateUIView(_ textView: NoteTextView, context: Context) {
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        textView.onPasteImage = onPasteImage
        controller.onChange = onChange
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: EditorController
        private var newlineTyped = false

        init(controller: EditorController) {
            self.controller = controller
        }

        /// Return, Tab, and Backspace behave differently inside a list.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if controller.isApplyingEdits { return true }
            if text == "\n", controller.handleReturn() { return false }
            if text == "\t", controller.changeIndent(by: 1) { return false }
            if text.isEmpty, range.length == 1, controller.handleBackspace() { return false }
            newlineTyped = text == "\n"
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !controller.isApplyingEdits else { return }
            let wasNewline = newlineTyped
            newlineTyped = false
            controller.userDidEdit(newlineTyped: wasNewline)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            controller.selectionDidChange()
        }

        /// Adds "Copy Without Formatting" to the menu shown for selected text.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0, let noteView = textView as? NoteTextView else { return nil }
            let plainCopy = UIAction(
                title: "Copy Without Formatting",
                image: UIImage(systemName: "doc.plaintext")
            ) { _ in
                noteView.copyWithoutFormatting(nil)
            }
            return UIMenu(children: suggestedActions + [plainCopy])
        }
    }
}

/// The iPhone and iPad text view: pastes plain text (taking the note's formatting), hands
/// pasted images to the app, copies clean text for other apps, and handles hardware-keyboard
/// shortcuts.
final class NoteTextView: UITextView {
    var onPasteImage: ((Data) -> Void)?
    /// Command-B, Command-I, or Command-U was pressed on a hardware keyboard.
    var onFormatShortcut: ((EditorController.Trait) -> Void)?
    /// Shift-Tab was pressed on a hardware keyboard.
    var onOutdent: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        guard isEditable else { return super.keyCommands }
        let commands = [
            UIKeyCommand(title: "Bold", action: #selector(shortcutBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italic", action: #selector(shortcutItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Underline", action: #selector(shortcutUnderline), input: "u", modifierFlags: .command),
            UIKeyCommand(title: "Outdent", action: #selector(shortcutOutdent), input: "\t", modifierFlags: .shift),
        ]
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func shortcutBold() { onFormatShortcut?(.bold) }
    @objc private func shortcutItalic() { onFormatShortcut?(.italic) }
    @objc private func shortcutUnderline() { onFormatShortcut?(.underline) }
    @objc private func shortcutOutdent() { onOutdent?() }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasStrings, let string = pasteboard.string {
            let before = textStorage.length
            insertText(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            if textStorage.length != before {
                delegate?.textViewDidChange?(self)
            }
        } else if isEditable, pasteboard.hasImages, let data = pasteboard.image?.pngData() {
            onPasteImage?(data)
        }
    }

    override func copy(_ sender: Any?) {
        if !writeSelectionToClipboard() {
            super.copy(sender)
        }
    }

    override func cut(_ sender: Any?) {
        guard isEditable, writeSelectionToClipboard() else {
            super.cut(sender)
            return
        }
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: "")
        selectedRange = NSRange(location: range.location, length: 0)
        undoManager?.removeAllActions()
        delegate?.textViewDidChange?(self)
    }

    /// Puts only the plain text of the selection on the clipboard.
    @objc func copyWithoutFormatting(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0 else { return }
        let exported = ClipboardText.export(textStorage.attributedSubstring(from: range))
        UIPasteboard.general.string = exported.plain
    }

    private func writeSelectionToClipboard() -> Bool {
        let range = selectedRange
        guard range.length > 0 else { return false }
        let exported = ClipboardText.export(textStorage.attributedSubstring(from: range))
        var item: [String: Any] = [UTType.utf8PlainText.identifier: exported.plain]
        if let rtf = exported.rtf {
            item[UTType.rtf.identifier] = rtf
        }
        UIPasteboard.general.setItems([item], options: [:])
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return isEditable && (UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages)
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif

/// Commands the menu bar sends to whichever note text view has the cursor.
@MainActor
enum EditorCommands {
    static func copyWithoutFormatting() {
        let action = #selector(NoteTextView.copyWithoutFormatting(_:))
        #if os(macOS)
        NSApp.sendAction(action, to: nil, from: nil)
        #else
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
        #endif
    }
}
