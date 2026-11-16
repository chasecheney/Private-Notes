import Foundation
import PrivateNotesStore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Translates between the stored `RichText` and what the platform text view edits.
enum RichTextConverter {
    static func attributedString(
        from rich: RichText,
        image: (UUID) -> PlatformImage?
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, paragraph) in rich.paragraphs.enumerated() {
            for run in paragraph.runs {
                let format = TextFormat(
                    style: paragraph.style,
                    bold: run.bold,
                    italic: run.italic,
                    underline: run.underline,
                    strikethrough: run.strikethrough
                )
                if let id = run.attachmentID {
                    output.append(imageString(id: id, image: image(id), format: format))
                } else {
                    output.append(NSAttributedString(string: run.text, attributes: format.attributes))
                }
            }
            if index < rich.paragraphs.count - 1 {
                output.append(NSAttributedString(
                    string: "\n",
                    attributes: TextFormat(style: paragraph.style).attributes
                ))
            }
        }
        return output
    }

    /// The single attachment character for an inline image.
    static func imageString(id: UUID, image: PlatformImage?, format: TextFormat) -> NSAttributedString {
        let attachment = NoteImageAttachment(id: id, image: image)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(format.attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    static func richText(from attributed: NSAttributedString) -> RichText {
        let text = attributed.string as NSString
        var paragraphs: [RichText.Paragraph] = []
        var start = 0
        while true {
            let remaining = NSRange(location: start, length: text.length - start)
            let newline = text.range(of: "\n", options: [], range: remaining)
            let end = newline.location == NSNotFound ? text.length : newline.location
            paragraphs.append(paragraph(in: NSRange(location: start, length: end - start), of: attributed))
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return RichText(paragraphs: paragraphs).normalized()
    }

    private static func paragraph(in range: NSRange, of attributed: NSAttributedString) -> RichText.Paragraph {
        guard range.length > 0 else { return RichText.Paragraph(style: .body, runs: []) }

        let style = TextFormat(attributes: attributed.attributes(at: range.location, effectiveRange: nil)).style
        let text = attributed.string as NSString
        var runs: [RichText.Run] = []
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let format = TextFormat(attributes: attributes)
            if let attachment = attributes[.attachment] {
                // Only this app's own images are kept; anything else pasted in as an attachment is dropped.
                if let image = attachment as? NoteImageAttachment {
                    runs.append(RichText.Run(attachmentID: image.attachmentID))
                }
                return
            }
            runs.append(RichText.Run(
                text: text.substring(with: subrange),
                bold: format.bold,
                italic: format.italic,
                underline: format.underline,
                strikethrough: format.strikethrough
            ))
        }
        return RichText.Paragraph(style: style, runs: runs)
    }
}
