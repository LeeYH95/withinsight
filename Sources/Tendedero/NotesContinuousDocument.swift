import AppKit
import NotesCore

extension NSMutableAttributedString {
    /// Avoid invalidating TextKit's layout for a run that already has the requested value.
    func updateNotesAttribute(_ key: NSAttributedString.Key, value: NSObject?, range: NSRange) {
        guard range.length > 0 else { return }
        var effective = NSRange()
        let current = attribute(key, at: range.location, longestEffectiveRange: &effective, in: range) as? NSObject
        guard current != value || effective != range else { return }
        if let value { addAttribute(key, value: value, range: range) }
        else { removeAttribute(key, range: range) }
    }
}

extension NSAttributedString.Key {
    static let notesBlock = NSAttributedString.Key("shipian.block")
    static let notesKind = NSAttributedString.Key("shipian.kind")
    static let notesChecked = NSAttributedString.Key("shipian.checked")
    static let notesHeading = NSAttributedString.Key("shipian.heading")
    static let notesAttachment = NSAttributedString.Key("shipian.attachment")
    static let notesAttachmentName = NSAttributedString.Key("shipian.attachmentName")
    static let notesImageWide = NSAttributedString.Key("shipian.imageWide")
    static let notesImageCaption = NSAttributedString.Key("shipian.imageCaption")
    static let notesMarker = NSAttributedString.Key("shipian.marker")
}

/// TextKit presentation of the note blocks.
@MainActor enum NotesContinuousDocument {
    static let bodySize: CGFloat = 15
    private static let checkboxOpticalLift: CGFloat = 0.5
    static func render(_ note: NoteDocument, scale: CGFloat = 1, width: CGFloat = 500, reusable: ((NoteBlock) -> Void)? = nil,
                       image: (NoteAttachment) -> NSImage? = { _ in nil }) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in note.blocks.enumerated() {
            let heading = block.markdown?.hasPrefix("# ") == true ? 1 : block.markdown?.hasPrefix("## ") == true ? 2 : 0
            let list = NotesListEditing.descriptor(block)
            let kind = list?.kind ?? block.kind.rawValue
            var metadata: [NSAttributedString.Key: Any] = [.notesBlock:block.id.uuidString, .notesKind:kind, .notesChecked:block.isChecked, .notesHeading:heading]
            if let list { metadata[.notesListLevel] = list.level; metadata[.notesListNumber] = list.number }
            let content: NSMutableAttributedString
            if block.kind == .image || block.kind == .file {
                let attachment = note.attachments.first { $0.id == block.attachmentID }
                let cell = NotesDocumentAttachmentCell(name: attachment?.name ?? block.text, image: attachment.flatMap(image), imageKind: block.kind == .image, width: width, scale: scale, wide: block.imageWide == true, caption: block.imageCaption)
                let token = NSTextAttachment(); token.attachmentCell = cell
                content = NSMutableAttributedString(attachment: token)
                if let wide = block.imageWide { metadata[.notesImageWide] = wide }
                if let caption = block.imageCaption { metadata[.notesImageCaption] = caption }
                content.addAttributes([.notesAttachment:block.attachmentID?.uuidString ?? "", .notesAttachmentName:block.text], range: NSRange(location: 0, length: content.length))
            } else {
                let originalRichText: NSAttributedString?
                if let data = block.richText, let rich = NSAttributedString(rtf: data, documentAttributes: nil), rich.string == block.text {
                    content = NSMutableAttributedString(attributedString: rich)
                    originalRichText = rich
                } else {
                    content = NSMutableAttributedString(string: block.text, attributes: [.font:NSFont.systemFont(ofSize: bodySize)])
                    originalRichText = nil
                }
                sanitizeLinks(in: content)
                if let reusable, block.richText == nil || originalRichText?.isEqual(to: content) == true {
                    reusable(block)
                }
                if list?.kind == "bullet", content.string.hasPrefix("• ") { content.deleteCharacters(in: NSRange(location: 0, length: 2)) }
                let unscaled = NSAttributedString(attributedString: content)
                unscaled.enumerateAttribute(.font, in: NSRange(location: 0, length: unscaled.length)) { value, range, _ in
                    let font = value as? NSFont ?? NSFont.systemFont(ofSize: bodySize)
                    content.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale), range: range)
                }
                if block.richText == nil, heading > 0, content.length > 0 {
                    content.addAttribute(.font, value: NSFont.systemFont(ofSize: bodySize * (heading == 1 ? 1.65 : 1.28) * scale, weight: .semibold), range: NSRange(location: 0, length: content.length))
                }
                if let list { content.insert(NotesListEditing.marker(kind: list.kind, number: list.number, checked: block.isChecked, font: NSFont.systemFont(ofSize: bodySize * scale)), at: 0) }
            }
            if index < note.blocks.count - 1 { content.append(NSAttributedString(string: "\n")) }
            if content.length > 0 { content.addAttributes(metadata, range: NSRange(location: 0, length: content.length)) }
            result.append(content)
        }
        NotesListEditing.normalize(result, selection: NSRange(location: 0, length: 0))
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
        token.attachmentCell = NotesChecklistAttachmentCell(image: image, font: baselineFont ?? NSFont.systemFont(ofSize: size),
                                                             opticalLift: checkboxOpticalLift, checked: checked)
        let marker = NSMutableAttributedString(attachment: token)
        marker.append(NSAttributedString(string: "\t"))
        marker.addAttributes([.notesMarker:true, .foregroundColor:NSColor(NotesTheme.accent), .font:NSFont.systemFont(ofSize: size)], range: NSRange(location: 0, length: marker.length))
        return marker
    }
    static func normalizeLayout(_ value: NSMutableAttributedString, scale: CGFloat, paragraph: NSRange? = nil) {
        let text = value.string as NSString
        let color = NSColor(NotesTheme.text)
        var cursor = paragraph?.location ?? 0
        let end = paragraph.map(NSMaxRange) ?? text.length
        while cursor < end {
            let range = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let attributes = value.attributes(at: range.location, effectiveRange: nil)
            let kind = attributes[.notesKind] as? String ?? "paragraph"
            let isList = NotesListEditing.isList(kind)
            let separator = NSMaxRange(range) - 1
            let hasListSeparator = isList && text.character(at: separator) == 10
            let contentRange = NSRange(location: range.location, length: range.length - (hasListSeparator ? 1 : 0))
            // The synthetic marker can retain the default font when only the
            // body is resized. It must share the body's font metrics, otherwise
            // fractional zoom gives the attachment and CJK text different baselines.
            var baselineFont: NSFont?
            value.enumerateAttributes(in: contentRange) { attributes, _, _ in
                guard attributes[.notesMarker] as? Bool != true, let font = attributes[.font] as? NSFont else { return }
                if font.pointSize > (baselineFont?.pointSize ?? 0) { baselineFont = font }
            }
            let layoutFont = baselineFont ?? (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: bodySize * scale)
            let size = layoutFont.pointSize
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = size * 1.75
            style.paragraphSpacing = size * 0.8
            if isList {
                let level = min(1, max(0, attributes[.notesListLevel] as? Int ?? 0))
                let indent = CGFloat(level) * size * 1.8
                style.headIndent = size * 1.55
                if kind == "ordered" {
                    let marker = "\(attributes[.notesListNumber] as? Int ?? 1)."
                    style.headIndent = max(style.headIndent, (marker as NSString).size(withAttributes: [.font: layoutFont]).width + size * 0.5)
                }
                if kind == "checklist" {
                    // The minimum-size checkbox must still fit before the tab
                    // at small fonts; wrapped text uses the same body column.
                    style.headIndent = max(style.headIndent, max(14, size) + 2 + size * 0.35)
                }
                style.headIndent += indent
                style.firstLineHeadIndent = attributes[.notesMarker] as? Bool == true ? indent : style.headIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                style.defaultTabInterval = style.headIndent
                let marker = NotesListEditing.markerRange(in: value, paragraph: range)
                value.updateNotesAttribute(.font, value: layoutFont, range: marker)
                if hasListSeparator {
                    // AppKit can supply a default font on the separator. It must
                    // not size the empty row or seed typing when the caret returns.
                    let lastBodyFont = separator > NSMaxRange(marker)
                        ? value.attribute(.font, at: separator - 1, effectiveRange: nil) as? NSFont
                        : nil
                    value.updateNotesAttribute(.font, value: lastBodyFont ?? layoutFont, range: NSRange(location: separator, length: 1))
                }
            }
            value.updateNotesAttribute(.paragraphStyle, value: style, range: range)
            value.updateNotesAttribute(.foregroundColor, value: color, range: range)
            if kind == "checklist", attributes[.notesMarker] as? Bool == true,
               range.length >= 2, text.substring(with: NSRange(location: cursor, length: 2)) == "\u{FFFC}\t" {
                let checked = attributes[.notesChecked] as? Bool ?? false
                let cell = (attributes[.attachment] as? NSTextAttachment)?.attachmentCell as? NotesChecklistAttachmentCell
                let canvas = max(14, size) + 2
                let offset = (layoutFont.capHeight - canvas) / 2 + checkboxOpticalLift
                if cell?.checked != checked || cell?.image?.size.width != canvas || cell?.verticalOffset != offset {
                    let marker = taskMarker(checked: checked, size: size, baselineFont: layoutFont)
                    value.addAttribute(.attachment, value: marker.attribute(.attachment, at: 0, effectiveRange: nil)!, range: NSRange(location: cursor, length: 1))
                }
            }
            cursor = NSMaxRange(range)
        }
    }
    @MainActor final class BodyEncodingCache {
        fileprivate struct Entry {
            let source: NSAttributedString
            let block: NoteBlock
        }
        fileprivate var scale: CGFloat?
        fileprivate var entries: [UUID: Entry] = [:]

        func seed(from document: NSAttributedString, scale: CGFloat, blocks: [String: NoteBlock]) {
            entries.removeAll(keepingCapacity: true)
            self.scale = scale
            let text = document.string as NSString
            document.enumerateAttribute(.notesBlock, in: NSRange(location: 0, length: document.length)) { id, range, _ in
                // Match a stored paragraph to a single export range. Empty and
                // multiline blocks can be split by the editor's export rules.
                guard let id = id as? String, let block = blocks[id], range.length > 0,
                      !block.text.isEmpty, block.text.rangeOfCharacter(from: .newlines) == nil else { return }
                let list = NotesListEditing.descriptor(block)
                let attributes = document.attributes(at: range.location, effectiveRange: nil)
                guard attributes[.notesKind] as? String == (list?.kind ?? block.kind.rawValue),
                      (attributes[.notesListLevel] as? Int ?? 0) == (list?.level ?? 0),
                      (attributes[.notesListNumber] as? Int ?? 1) == (list?.number ?? 1) else { return }
                let separatorLength = text.character(at: NSMaxRange(range) - 1) == 10 ? 1 : 0
                let source = document.attributedSubstring(from: NSRange(location: range.location, length: range.length - separatorLength))
                entries[block.id] = Entry(source: source, block: block)
            }
        }
    }

    static func blocks(from value: NSAttributedString, scale: CGFloat = 1, trailingAttributes: [NSAttributedString.Key: Any] = [:],
                       cache: BodyEncodingCache? = nil) throws -> [NoteBlock] {
        let emptyID = (trailingAttributes[.notesBlock] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        guard value.length > 0 else { return [NoteBlock(id: emptyID)] }
        let text = value.string as NSString
        struct Part { var id: UUID; var kind: String; var heading: Int; var checked: Bool; var level: Int; var number: Int; var range: NSRange }
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
            let level = min(1, max(0, attrs[.notesListLevel] as? Int ?? 0))
            let number = max(1, attrs[.notesListNumber] as? Int ?? 1)
            if let last = parts.last, last.id == id, last.kind == kind, last.heading == heading, last.checked == checked, last.level == level, !NotesListEditing.isList(kind), !ownedAttachment, last.kind != "image", last.kind != "file" {
                parts[parts.count - 1].range.length = NSMaxRange(range) - last.range.location
            } else { parts.append(Part(id:id, kind:kind, heading:heading, checked:checked, level:level, number:number, range:range)) }
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
        if text.hasSuffix("\n") { parts.append(Part(id:emptyID, kind:trailingAttributes[.notesKind] as? String ?? "paragraph", heading:trailingAttributes[.notesHeading] as? Int ?? 0, checked:false, level:trailingAttributes[.notesListLevel] as? Int ?? 0, number:trailingAttributes[.notesListNumber] as? Int ?? 1, range:NSRange(location:text.length, length:0))) }
        var seen = Set<UUID>(), blocks: [NoteBlock] = []
        var nextEntries: [UUID: BodyEncodingCache.Entry] = [:]
        for part in parts {
            var id = part.id
            while !seen.insert(id).inserted { id = UUID() }
            let attrs = value.attributes(at: min(part.range.location, value.length - 1), effectiveRange: nil)
            if part.kind == "image" || part.kind == "file" {
                blocks.append(NoteBlock(id:id, kind:part.kind == "image" ? .image : .file, text:attrs[.notesAttachmentName] as? String ?? "附件", attachmentID:(attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)), imageWide: attrs[.notesImageWide] as? Bool, imageCaption: attrs[.notesImageCaption] as? String))
                continue
            }
            let source = value.attributedSubstring(from: part.range)
            if part.range.length > 0, cache?.scale == scale, let previous = cache?.entries[id],
               previous.source.isEqual(to: source) {
                blocks.append(previous.block)
                nextEntries[id] = previous
                continue
            }
            let body = NSMutableAttributedString(attributedString: source)
            var markerRanges: [NSRange] = []
            body.enumerateAttribute(.notesMarker, in: NSRange(location: 0, length: body.length)) { marked, range, _ in if marked as? Bool == true { markerRanges.append(range) } }
            for range in markerRanges.reversed() { body.deleteCharacters(in: range) }
            let original = NSAttributedString(attributedString: body)
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, range, _ in
                if let font = attributes[.font] as? NSFont { body.addAttribute(.font, value:NSFontManager.shared.convert(font, toSize:font.pointSize / max(0.1, scale)), range:range) }
                for key in [.notesBlock, .notesKind, .notesChecked, .notesHeading, .notesAttachment, .notesAttachmentName, .notesImageWide, .notesImageCaption, .notesMarker, .notesPendingLink, .notesListLevel, .notesListNumber, .notesListStart, .notesListStartLevel] as [NSAttributedString.Key] { body.removeAttribute(key, range:range) }
            }
            var markdown = RichNoteTextView.Coordinator.markdown(body)
            if part.heading > 0 { markdown = String(repeating:"#", count:part.heading) + " " + markdown }
            if part.kind == "bullet" { body.insert(NSAttributedString(string:"• ", attributes:[.font:NSFont.systemFont(ofSize:bodySize)]), at:0) }
            // Historical top-level checklist Markdown remains unchanged.
            if NotesListEditing.isList(part.kind), part.kind != "checklist" || part.level > 0 {
                markdown = NotesListEditing.markdownPrefix(.init(kind: part.kind, level: part.level, number: part.number), checked: part.checked) + markdown
            }
            let rich = try body.data(from:NSRange(location:0,length:body.length), documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
            let block = NoteBlock(id:id, kind:part.kind == "checklist" ? .checklist : .paragraph, text:body.string, richText:rich, markdown:markdown, isChecked:part.checked)
            if cache != nil, part.range.length > 0 { nextEntries[id] = .init(source: source, block: block) }
            blocks.append(block)
        }
        cache?.scale = scale
        cache?.entries = nextEntries
        return blocks.isEmpty ? [NoteBlock()] : blocks
    }
}

/// An image cell normally puts its bottom on the text baseline, making a
/// checkbox sit too high. Centre its canvas on the font's visible capital band.
@MainActor final class NotesChecklistAttachmentCell: NSTextAttachmentCell {
    let verticalOffset: CGFloat
    let checked: Bool?
    init(image: NSImage, font: NSFont, opticalLift: CGFloat = 0, checked: Bool? = nil) {
        verticalOffset = (font.capHeight - image.size.height) / 2 + opticalLift
        self.checked = checked
        super.init(imageCell: image)
    }
    required init(coder: NSCoder) {
        verticalOffset = coder.decodeDouble(forKey: "shipian.checkboxBaseline")
        checked = nil
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
    let wide: Bool
    let caption: String?
    let scale: CGFloat
    private(set) var imageSize: NSSize = .zero
    // TextKit queries cellSize through the nonisolated NSCell API.
    nonisolated(unsafe) private(set) var displaySize: NSSize = .zero
    var entranceProgress: CGFloat = 1

    init(name: String, image: NSImage?, imageKind: Bool, width: CGFloat, scale: CGFloat,
         wide: Bool = false, caption: String? = nil) {
        self.name = name; previewImage = image; self.imageKind = imageKind
        self.wide = wide; self.caption = caption; self.scale = scale
        super.init(textCell: "")
        updateWidth(width)
    }

    required init(coder: NSCoder) {
        name = coder.decodeObject(forKey: "shipian.name") as? String ?? "附件"
        previewImage = coder.decodeObject(forKey: "shipian.preview") as? NSImage
        imageKind = coder.decodeBool(forKey: "shipian.image")
        wide = coder.decodeBool(forKey: "shipian.wide")
        caption = coder.decodeObject(forKey: "shipian.caption") as? String
        scale = coder.containsValue(forKey: "shipian.scale") ? CGFloat(coder.decodeDouble(forKey: "shipian.scale")) : 1
        displaySize = coder.decodeSize(forKey: "shipian.size")
        imageSize = coder.containsValue(forKey: "shipian.imageSize") ? coder.decodeSize(forKey: "shipian.imageSize") : displaySize
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(name, forKey: "shipian.name"); coder.encode(previewImage, forKey: "shipian.preview")
        coder.encode(imageKind, forKey: "shipian.image"); coder.encode(displaySize, forKey: "shipian.size")
        coder.encode(wide, forKey: "shipian.wide"); coder.encode(caption, forKey: "shipian.caption")
        coder.encode(Double(scale), forKey: "shipian.scale"); coder.encode(imageSize, forKey: "shipian.imageSize")
    }

    private var captionFont: NSFont { .systemFont(ofSize: 12 * scale) }

    @discardableResult func updateWidth(_ available: CGFloat) -> Bool {
        let previous = displaySize
        let width = wide ? available : min(380 * scale, available)
        if let previewImage, imageKind, previewImage.size.width > 0 {
            let w = wide ? width : min(width, previewImage.size.width * scale)
            imageSize = NSSize(width: w, height: w * previewImage.size.height / previewImage.size.width)
        } else {
            imageSize = NSSize(width: min(available, max(150, min(width, 470 * scale))), height: (imageKind ? 110 : 68) * scale)
        }
        displaySize = imageSize
        if imageKind, let caption, !caption.isEmpty {
            displaySize.width = min(available, max(imageSize.width, 150 * scale))
            let bounds = (caption as NSString).boundingRect(with: NSSize(width: displaySize.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: captionFont])
            displaySize.height += ceil(bounds.height) + 7 * scale
        }
        return previous != displaySize
    }

    override func cellSize() -> NSSize { displaySize }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let flipped = controlView?.isFlipped ?? true
        let imageFrame = NSRect(x: frame.minX, y: flipped ? frame.minY : frame.maxY - imageSize.height,
                                width: imageSize.width, height: imageSize.height)
        if let previewImage, imageKind {
            let movingFrame = imageFrame.offsetBy(dx: 0, dy: (flipped ? 3 : -3) * (1 - entranceProgress))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageFrame, xRadius: 12, yRadius: 12).addClip()
            previewImage.draw(in: movingFrame, from: .zero, operation: .sourceOver, fraction: entranceProgress, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor(NotesTheme.shell).withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: imageFrame, xRadius: 10, yRadius: 10).fill()
            let title = (imageKind ? "图片暂时无法读取：" : "附件：") + name
            (title as NSString).draw(in: imageFrame.insetBy(dx: 14, dy: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(NotesTheme.text)])
        }
        if imageKind, let caption, displaySize.height > imageSize.height {
            let y = flipped ? imageFrame.maxY + 7 * scale : frame.minY
            (caption as NSString).draw(with: NSRect(x: frame.minX, y: y, width: displaySize.width,
                height: displaySize.height - imageSize.height - 7 * scale),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: captionFont, .foregroundColor: NSColor(NotesTheme.muted)])
        }
    }
}
