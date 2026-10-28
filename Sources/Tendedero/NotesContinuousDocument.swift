import AppKit
import NotesCore

extension NSAttributedString.Key {
    static let notesBlock = NSAttributedString.Key("shipian.block")
    static let notesKind = NSAttributedString.Key("shipian.kind")
    static let notesChecked = NSAttributedString.Key("shipian.checked")
    static let notesHeading = NSAttributedString.Key("shipian.heading")
    static let notesAttachment = NSAttributedString.Key("shipian.attachment")
    static let notesAttachmentName = NSAttributedString.Key("shipian.attachmentName")
    static let notesMarker = NSAttributedString.Key("shipian.marker")
}

/// TextKit presentation of the existing block format. No new storage schema or web bridge.
@MainActor enum NotesContinuousDocument {
    static let bodySize: CGFloat = 15
    static func render(_ note: NoteDocument, scale: CGFloat = 1, width: CGFloat = 500, image: (NoteAttachment) -> NSImage? = { _ in nil }) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in note.blocks.enumerated() {
            let heading = block.markdown?.hasPrefix("# ") == true ? 1 : block.markdown?.hasPrefix("## ") == true ? 2 : 0
            let bullet = block.kind == .paragraph && (block.text.hasPrefix("• ") || block.markdown?.hasPrefix("- ") == true)
            let kind = bullet ? "bullet" : block.kind.rawValue
            let metadata: [NSAttributedString.Key: Any] = [.notesBlock:block.id.uuidString, .notesKind:kind, .notesChecked:block.isChecked, .notesHeading:heading]
            let content: NSMutableAttributedString
            if block.kind == .image || block.kind == .file {
                let attachment = note.attachments.first { $0.id == block.attachmentID }
                let cell = NotesDocumentAttachmentCell(name: attachment?.name ?? block.text, image: attachment.flatMap(image), imageKind: block.kind == .image, width: min(380 * scale, width), scale: scale)
                let token = NSTextAttachment(); token.attachmentCell = cell
                content = NSMutableAttributedString(attachment: token)
                content.addAttributes([.notesAttachment:block.attachmentID?.uuidString ?? "", .notesAttachmentName:block.text], range: NSRange(location: 0, length: content.length))
            } else {
                if let data = block.richText, let rich = NSAttributedString(rtf: data, documentAttributes: nil), rich.string == block.text {
                    content = NSMutableAttributedString(attributedString: rich)
                } else {
                    content = NSMutableAttributedString(string: block.text, attributes: [.font:NSFont.systemFont(ofSize: bodySize)])
                }
                sanitizeLinks(in: content)
                if bullet, content.string.hasPrefix("• ") { content.deleteCharacters(in: NSRange(location: 0, length: 2)) }
                let unscaled = NSAttributedString(attributedString: content)
                unscaled.enumerateAttribute(.font, in: NSRange(location: 0, length: unscaled.length)) { value, range, _ in
                    let font = value as? NSFont ?? NSFont.systemFont(ofSize: bodySize)
                    content.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale), range: range)
                }
                if block.richText == nil, heading > 0, content.length > 0 {
                    content.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize * (heading == 1 ? 1.65 : 1.28) * scale, weight: .semibold), range: NSRange(location: 0, length: content.length))
                }
                if kind == "checklist" { content.insert(taskMarker(checked: block.isChecked, size: bodySize * scale), at: 0) }
                else if bullet { content.insert(NSAttributedString(string: "•\t", attributes: [.font:NSFont.systemFont(ofSize: bodySize * scale), .notesMarker:true]), at: 0) }
            }
            if index < note.blocks.count - 1 { content.append(NSAttributedString(string: "\n")) }
            if content.length > 0 { content.addAttributes(metadata, range: NSRange(location: 0, length: content.length)) }
            result.append(content)
        }
        normalizeLayout(result, scale: scale)
        return result
    }
    /// Imported and historical rich text must cross the same web-link boundary.
    static func sanitizeLinks(in value: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: value.length)
        value.removeAttribute(.notesPendingLink, range: range)
        let original = NSAttributedString(attributedString: value)
        original.enumerateAttribute(.link, in: range) { link, run, _ in
            guard link != nil else { return }
            if let url = NotesWebLink.destination(from: link) { value.addAttribute(.link, value: url, range: run) }
            else {
                value.removeAttribute(.link, range: run)
                value.removeAttribute(.toolTip, range: run)
            }
        }
    }
    static func taskMarker(checked: Bool, size: CGFloat, baselineFont: NSFont? = nil) -> NSAttributedString {
        let side = max(14,size), stroke = max(1.2,size * 0.085)
        let ink = NSColor(NotesTheme.accent)
        let image = NSImage(size:NSSize(width:side + 2,height:side + 2),flipped:false) { _ in
            let box = NSBezierPath(roundedRect:NSRect(x:1,y:1,width:side,height:side),xRadius:side * 0.35,yRadius:side * 0.35)
            box.lineWidth = stroke
            if checked { ink.setFill(); box.fill() } else { NSColor(NotesTheme.muted).setStroke(); box.stroke() }
            if checked {
                let check = NSBezierPath(); check.move(to:NSPoint(x:side * 0.25,y:side * 0.52))
                check.line(to:NSPoint(x:side * 0.45,y:side * 0.31)); check.line(to:NSPoint(x:side * 0.79,y:side * 0.72))
                check.lineWidth = stroke; check.lineCapStyle = .round; check.lineJoinStyle = .round
                NSColor.white.setStroke(); check.stroke()
            }
            return true
        }
        let token = NSTextAttachment()
        token.attachmentCell = NotesChecklistAttachmentCell(image: image, font: baselineFont ?? NSFont.systemFont(ofSize: size))
        let marker = NSMutableAttributedString(attachment: token)
        marker.append(NSAttributedString(string: "\t"))
        marker.addAttributes([.notesMarker:true, .foregroundColor:NSColor(NotesTheme.accent), .font:NSFont.systemFont(ofSize: size)], range: NSRange(location: 0, length: marker.length))
        return marker
    }
    static func normalizeLayout(_ value: NSMutableAttributedString, scale: CGFloat) {
        let text = value.string as NSString
        var cursor = 0
        while cursor < text.length {
            let range = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let attributes = value.attributes(at: range.location, effectiveRange: nil)
            let kind = attributes[.notesKind] as? String ?? "paragraph"
            // The synthetic marker can retain the default font when only the
            // body is resized. It must share the body's font metrics, otherwise
            // fractional zoom gives the attachment and CJK text different baselines.
            var baselineFont: NSFont?
            value.enumerateAttributes(in: range) { attributes, _, _ in
                guard attributes[.notesMarker] as? Bool != true, let font = attributes[.font] as? NSFont else { return }
                if font.pointSize > (baselineFont?.pointSize ?? 0) { baselineFont = font }
            }
            let size = baselineFont?.pointSize ?? (attributes[.font] as? NSFont)?.pointSize ?? bodySize * scale
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = size * 1.75
            style.paragraphSpacing = size * 0.8
            if kind == "checklist" || kind == "bullet" {
                style.headIndent = size * 1.55
                if kind == "checklist" {
                    // The minimum-size checkbox must still fit before the tab
                    // at small fonts; wrapped text uses the same body column.
                    style.headIndent = max(style.headIndent, max(14, size) + 2 + size * 0.35)
                }
                style.firstLineHeadIndent = attributes[.notesMarker] as? Bool == true ? 0 : style.headIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                style.defaultTabInterval = style.headIndent
            }
            value.addAttributes([.paragraphStyle:style, .foregroundColor:NSColor(NotesTheme.text)], range: range)
            if kind == "checklist", attributes[.notesMarker] as? Bool == true {
                let marker = taskMarker(checked: attributes[.notesChecked] as? Bool ?? false, size: size, baselineFont: baselineFont)
                if range.length >= 2, text.substring(with: NSRange(location: cursor, length: 2)) == "\u{FFFC}\t" {
                    value.addAttribute(.attachment, value: marker.attribute(.attachment, at: 0, effectiveRange: nil)!, range: NSRange(location: cursor, length: 1))
                    value.addAttribute(.font, value: baselineFont ?? NSFont.systemFont(ofSize: size), range: NSRange(location: cursor, length: 2))
                }
            }
            cursor = NSMaxRange(range)
        }
    }
    static func blocks(from value: NSAttributedString, scale: CGFloat = 1, trailingAttributes: [NSAttributedString.Key: Any] = [:]) throws -> [NoteBlock] {
        let emptyID = (trailingAttributes[.notesBlock] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        guard value.length > 0 else { return [NoteBlock(id: emptyID)] }
        let text = value.string as NSString
        struct Part { var id: UUID; var kind: String; var heading: Int; var checked: Bool; var range: NSRange }
        var parts: [Part] = [], cursor = 0
        func append(_ range: NSRange, ownedAttachment: Bool = false) {
            let attrs = value.attributes(at: min(range.location, value.length - 1), effectiveRange: nil)
            let id = (attrs[.notesBlock] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let sourceKind = attrs[.notesKind] as? String ?? "paragraph"
            let kind: String
            if ownedAttachment {
                let cell = (attrs[.attachment] as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell
                kind = sourceKind == "image" || sourceKind == "file" ? sourceKind : cell?.imageKind == true ? "image" : "file"
            } else {
                // Removing a separator can leave attachment paragraph attributes on text.
                // Only the attachment token itself may become an owned-file block.
                kind = sourceKind == "image" || sourceKind == "file" ? "paragraph" : sourceKind
            }
            let heading = ownedAttachment || sourceKind == "image" || sourceKind == "file" ? 0 : attrs[.notesHeading] as? Int ?? 0
            let checked = attrs[.notesChecked] as? Bool ?? false
            if let last = parts.last, last.id == id, last.kind == kind, last.heading == heading, last.checked == checked, !ownedAttachment, last.kind != "image", last.kind != "file" {
                parts[parts.count - 1].range.length = NSMaxRange(range) - last.range.location
            } else { parts.append(Part(id:id, kind:kind, heading:heading, checked:checked, range:range)) }
        }
        while cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            var range = paragraph
            if range.length > 0, text.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" { range.length -= 1 }
            var attachments: [NSRange] = []
            value.enumerateAttribute(.notesAttachment, in: range) { reference, run, _ in
                guard reference is String else { return }
                for index in run.location..<NSMaxRange(run) where text.character(at: index) == 0xFFFC {
                    let attrs = value.attributes(at: index, effectiveRange: nil)
                    if attrs[.attachment] is NSTextAttachment, attrs[.notesMarker] as? Bool != true { attachments.append(NSRange(location: index, length: 1)) }
                }
            }
            var start = range.location
            for attachment in attachments {
                if attachment.location > start { append(NSRange(location:start, length:attachment.location - start)) }
                append(attachment, ownedAttachment:true)
                start = NSMaxRange(attachment)
            }
            if start < NSMaxRange(range) || attachments.isEmpty { append(NSRange(location:start, length:NSMaxRange(range) - start)) }
            cursor = NSMaxRange(paragraph)
        }
        // A final empty paragraph is a real caret destination, not disposable whitespace.
        if text.hasSuffix("\n") { parts.append(Part(id:emptyID, kind:trailingAttributes[.notesKind] as? String ?? "paragraph", heading:trailingAttributes[.notesHeading] as? Int ?? 0, checked:false, range:NSRange(location:text.length, length:0))) }
        var seen = Set<UUID>(), blocks: [NoteBlock] = []
        for part in parts {
            var id = part.id
            while !seen.insert(id).inserted { id = UUID() }
            let attrs = value.attributes(at: min(part.range.location, value.length - 1), effectiveRange: nil)
            if part.kind == "image" || part.kind == "file" {
                blocks.append(NoteBlock(id:id, kind:part.kind == "image" ? .image : .file, text:attrs[.notesAttachmentName] as? String ?? "附件", attachmentID:(attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:))))
                continue
            }
            let body = NSMutableAttributedString(attributedString: value.attributedSubstring(from: part.range))
            var markerRanges: [NSRange] = []
            body.enumerateAttribute(.notesMarker, in: NSRange(location: 0, length: body.length)) { marked, range, _ in if marked as? Bool == true { markerRanges.append(range) } }
            for range in markerRanges.reversed() { body.deleteCharacters(in: range) }
            let original = NSAttributedString(attributedString: body)
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, range, _ in
                if let font = attributes[.font] as? NSFont { body.addAttribute(.font, value:NSFontManager.shared.convert(font, toSize:font.pointSize / max(0.1, scale)), range:range) }
                for key in [.notesBlock, .notesKind, .notesChecked, .notesHeading, .notesAttachment, .notesAttachmentName, .notesMarker, .notesPendingLink] as [NSAttributedString.Key] { body.removeAttribute(key, range:range) }
            }
            var markdown = RichNoteTextView.Coordinator.markdown(body)
            if part.heading > 0 { markdown = String(repeating:"#", count:part.heading) + " " + markdown }
            if part.kind == "bullet" {
                body.insert(NSAttributedString(string:"• ", attributes:[.font:NSFont.systemFont(ofSize:bodySize)]), at:0)
                markdown = "- " + markdown
            }
            let rich = try body.data(from:NSRange(location:0,length:body.length), documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
            blocks.append(NoteBlock(id:id, kind:part.kind == "checklist" ? .checklist : .paragraph, text:body.string, richText:rich, markdown:markdown, isChecked:part.checked))
        }
        return blocks.isEmpty ? [NoteBlock()] : blocks
    }
}

/// An image cell normally puts its bottom on the text baseline, making a
/// checkbox sit too high. Centre its canvas on the font's visible capital band.
@MainActor final class NotesChecklistAttachmentCell: NSTextAttachmentCell {
    let verticalOffset: CGFloat
    init(image: NSImage, font: NSFont) {
        verticalOffset = (font.capHeight - image.size.height) / 2
        super.init(imageCell: image)
    }
    required init(coder: NSCoder) {
        verticalOffset = coder.decodeDouble(forKey: "shipian.checkboxBaseline")
        super.init(coder: coder)
    }
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(verticalOffset, forKey: "shipian.checkboxBaseline")
    }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: verticalOffset) }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        image?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// An attachment is always an owned file reference; no image bytes enter the note's RTF.
@MainActor final class NotesDocumentAttachmentCell: NSTextAttachmentCell {
    let name: String
    let previewImage: NSImage?
    let imageKind: Bool
    let displaySize: NSSize
    init(name: String, image: NSImage?, imageKind: Bool, width: CGFloat, scale: CGFloat) {
        self.name = name; previewImage = image; self.imageKind = imageKind
        if let image, imageKind, image.size.width > 0 {
            let w = min(width, image.size.width * scale)
            displaySize = NSSize(width:w,height:w * image.size.height / image.size.width)
        } else { displaySize = NSSize(width:max(150,min(width,470 * scale)),height:(imageKind ? 110 : 68) * scale) }
        super.init(textCell: "")
    }
    required init(coder: NSCoder) {
        name = coder.decodeObject(forKey:"shipian.name") as? String ?? "附件"
        previewImage = coder.decodeObject(forKey:"shipian.preview") as? NSImage
        imageKind = coder.decodeBool(forKey:"shipian.image")
        displaySize = coder.decodeSize(forKey:"shipian.size")
        super.init(coder:coder)
    }
    override func encode(with coder:NSCoder) {
        super.encode(with:coder)
        coder.encode(name,forKey:"shipian.name"); coder.encode(previewImage,forKey:"shipian.preview")
        coder.encode(imageKind,forKey:"shipian.image"); coder.encode(displaySize,forKey:"shipian.size")
    }
    override func cellSize() -> NSSize { displaySize }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x:0,y:0) }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        if let previewImage, imageKind {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect:frame,xRadius:12,yRadius:12).addClip()
            previewImage.draw(in:frame,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState(); return
        }
        NSColor(NotesTheme.shell).withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect:frame, xRadius:10, yRadius:10).fill()
        let title = (imageKind ? "图片暂时无法读取：" : "附件：") + name
        (title as NSString).draw(in:frame.insetBy(dx:14,dy:16), withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor(NotesTheme.text)])
    }
}
