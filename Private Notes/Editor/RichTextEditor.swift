import PrivateNotesStore
import SwiftUI

/// The note editor: a native text view (so images can sit inline), wrapped for SwiftUI.
///
/// The text is loaded once, when the view is created. Give the view a different `.id` to show
/// a different note. Typed and pasted text always takes the note's own fonts and colors:
/// formatting from other apps is not brought in.
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
        let lastStyle = initialText.paragraphs.last.flatMap { $0.runs.isEmpty ? nil : $0.style } ?? .body
        textView.typingAttributes = TextFormat(style: lastStyle).attributes
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
        textView.onPasteImage = onPasteImage
        controller.textView = textView
        controller.onChange = onChange

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
            newlineTyped = replacementString == "\n"
            return true
        }

        func textDidChange(_ notification: Notification) {
            if newlineTyped {
                newlineTyped = false
                controller.newlineWasTyped()
            }
            controller.contentDidChange()
        }
    }
}

/// Text view that pastes plain text (taking the note's formatting) and hands pasted images to the app.
final class NoteTextView: NSTextView {
    var onPasteImage: ((Data) -> Void)?

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
}

#else
import UIKit

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
        textView.onPasteImage = onPasteImage
        controller.textView = textView
        controller.onChange = onChange
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

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            newlineTyped = text == "\n"
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            if newlineTyped {
                newlineTyped = false
                controller.newlineWasTyped()
            }
            controller.contentDidChange()
        }
    }
}

/// Text view that pastes plain text (taking the note's formatting) and hands pasted images to the app.
final class NoteTextView: UITextView {
    var onPasteImage: ((Data) -> Void)?

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

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return isEditable && (UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages)
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
