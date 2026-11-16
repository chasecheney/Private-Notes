import Foundation
import PrivateNotesStore

/// Translates between the stored `RichText` and what the platform text view edits.
public enum RichTextConverter {
    public static func attributedString(
        from rich: RichText,
        image: (UUID) -> PlatformImage?
    ) -> NSAttributedString {
        let snapshots = rich.paragraphs.map { paragraph -> ParagraphSnapshot in
            let content = NSMutableAttributedString()
            for run in paragraph.runs {
                let format = TextFormat(
                    style: paragraph.style,
                    bold: run.bold,
                    italic: run.italic,
                    underline: run.underline,
                    strikethrough: run.strikethrough
                )
                if let id = run.attachmentID {
                    content.append(imageString(id: id, image: image(id), format: format))
                } else {
                    content.append(NSAttributedString(string: run.text, attributes: format.attributes))
                }
            }
            return ParagraphSnapshot(
                style: paragraph.style,
                list: paragraph.list,
                indent: paragraph.indent,
                content: content
            )
        }
        let numbers = ListSupport.numbers(for: snapshots.map { (list: $0.list, indent: $0.indent) })

        let output = NSMutableAttributedString()
        for (index, snapshot) in snapshots.enumerated() {
            output.append(ListSupport.render(snapshot, number: numbers[index]))
            if index < snapshots.count - 1 {
                let lineBreak = TextFormat(
                    style: snapshot.style,
                    list: snapshot.list,
                    indent: snapshot.list == nil ? 0 : snapshot.indent
                )
                output.append(NSAttributedString(string: "\n", attributes: lineBreak.attributes))
            }
        }
        return output
    }

    /// The single attachment character for an inline image.
    public static func imageString(id: UUID, image: PlatformImage?, format: TextFormat) -> NSAttributedString {
        let attachment = NoteImageAttachment(id: id, image: image)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(format.attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    public static func richText(from attributed: NSAttributedString) -> RichText {
        let paragraphs = ListSupport.paragraphRanges(in: attributed.string as NSString).map { range in
            paragraph(from: ListSupport.snapshot(ofParagraph: range, in: attributed))
        }
        return RichText(paragraphs: paragraphs).normalized()
    }

    private static func paragraph(from snapshot: ParagraphSnapshot) -> RichText.Paragraph {
        let content = snapshot.content
        var runs: [RichText.Run] = []
        if content.length > 0 {
            let text = content.string as NSString
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length), options: []) { attributes, subrange, _ in
                if let attachment = attributes[.attachment] {
                    // Only this app's own images are kept; any other kind of attachment is dropped.
                    if let image = attachment as? NoteImageAttachment {
                        runs.append(RichText.Run(attachmentID: image.attachmentID))
                    }
                    return
                }
                let format = TextFormat(attributes: attributes)
                runs.append(RichText.Run(
                    text: text.substring(with: subrange),
                    bold: format.bold,
                    italic: format.italic,
                    underline: format.underline,
                    strikethrough: format.strikethrough
                ))
            }
        }
        return RichText.Paragraph(
            style: snapshot.style,
            list: snapshot.list,
            indent: snapshot.list == nil ? 0 : snapshot.indent,
            runs: runs
        )
    }
}
