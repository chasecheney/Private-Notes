import Foundation
import PrivateNotesEditing

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What copying from a note puts on the clipboard for other apps.
enum ClipboardText {
    /// Plain text, and the same text as RTF with its formatting. The note's own text color is
    /// left out, so text copied in dark mode is not white when pasted elsewhere. Images are
    /// not included.
    static func export(_ selection: NSAttributedString) -> (plain: String, rtf: Data?) {
        let copy = NSMutableAttributedString(attributedString: selection)

        var images: [NSRange] = []
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length), options: []) { value, range, _ in
            if value != nil { images.append(range) }
        }
        for range in images.reversed() {
            copy.deleteCharacters(in: range)
        }

        let whole = NSRange(location: 0, length: copy.length)
        for key in [
            NSAttributedString.Key.foregroundColor, .noteStyle, .noteBold, .noteItalic,
            .noteList, .noteIndent, .noteListMarker,
        ] {
            copy.removeAttribute(key, range: whole)
        }

        let rtf = try? copy.data(
            from: whole,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        return (copy.string, rtf)
    }
}
