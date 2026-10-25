import AppKit
import SwiftUI
import NotesCore
import CryptoKit
import UniformTypeIdentifiers

/// One native text system owns the entire body, including selection and IME composition.
@MainActor final class NotesContinuousTextView: NotesTextView {
    private var ownedStorage: NSTextStorage?
    var trailingAttributes: [NSAttributedString.Key: Any] = [:]
    var readingScale: CGFloat = 1
    var preservePastedFormatting = false
    var imageProvider: (NoteAttachment) -> NSImage? = { _ in nil }
    var onAttachment: ((NoteAttachment) -> Void)?
    var loading = false
    private var normalizing = false
    private var renderedWidth: CGFloat = 0
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let actual: NSTextContainer
        if let container { actual = container }
        else {
            let storage = NSTextStorage(), manager = NSLayoutManager()
            actual = NSTextContainer(size:NSSize(width:max(100,frameRect.width),height:.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(actual)
            ownedStorage = storage
        }
        super.init(frame: frameRect, textContainer: actual)
        isRichText = true; importsGraphics = false; allowsUndo = false
        isEditable = true; isSelectable = true; drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = true; isAutomaticDashSubstitutionEnabled = true
        isAutomaticLinkDetectionEnabled = true
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.lineFragmentPadding = 0; textContainer?.widthTracksTextView = true
        isVerticallyResizable = true; isHorizontallyResizable = false
        autoresizingMask = [.width]
        insertionPointColor = NSColor(NotesTheme.accent)
        setAccessibilityLabel("闪念正文")
        registerForDraggedTypes([.fileURL, .tiff, .png])
        typingAttributes = defaultAttributes()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let scroll = enclosingScrollView, let paper = scroll.documentView,
              let layout = layoutManager, let container = textContainer,
              range.location <= string.utf16.count else { return }
        layout.ensureLayout(for: container)
        let line: NSRect
        if range.location == string.utf16.count, layout.extraLineFragmentRect.height > 0 {
            line = layout.extraLineFragmentRect
        } else if layout.numberOfGlyphs > 0 {
            let character = min(range.location, max(0, string.utf16.count - 1))
            line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
        } else { return }
        // The toolbar is outside the scroll viewport; leave only the normal end padding.
        var target = convert(line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), to: paper)
        if !paper.isFlipped { target.origin.y -= 24 }
        target.size.height += 24
        paper.scrollToVisible(target)
    }
    func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [.font:NSFont.systemFont(ofSize:NotesContinuousDocument.bodySize * readingScale), .foregroundColor:NSColor(NotesTheme.text), .notesBlock:UUID().uuidString, .notesKind:"paragraph", .notesHeading:0, .notesChecked:false]
    }
    func loadDocument(_ note: NoteDocument) {
        guard !hasMarkedText() else { return }
        loading = true
        let selection = selectedRange()
        textStorage?.setAttributedString(NotesContinuousDocument.render(note, scale:readingScale, width:max(150,bounds.width), image:imageProvider))
        let length = textStorage?.length ?? 0
        setSelectedRange(NSRange(location:min(selection.location,length), length:min(selection.length,max(0,length - min(selection.location,length)))))
        trailingAttributes = defaultAttributes()
        if let last = note.blocks.last, last.text.isEmpty, last.kind == .paragraph {
            trailingAttributes[.notesBlock] = last.id.uuidString
            trailingAttributes[.notesHeading] = last.markdown?.hasPrefix("# ") == true ? 1 : last.markdown?.hasPrefix("## ") == true ? 2 : 0
        }
        if length == 0 || selection.location >= length && note.blocks.last?.text.isEmpty == true { typingAttributes = trailingAttributes }
        cleanTypingAttributes()
        loading = false; onLayout?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(renderedWidth - newSize.width) > 1 { renderedWidth = newSize.width; onLayout?() }
    }
    private func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, storage.length > 0, location < storage.length else { return typingAttributes }
        return storage.attributes(at:max(0,location), effectiveRange:nil)
    }
    func cleanTypingAttributes() {
        var attrs = typingAttributes
        for key in [.attachment, .notesMarker, .notesAttachment, .notesAttachmentName] as [NSAttributedString.Key] { attrs.removeValue(forKey:key) }
        let kind = attrs[.notesKind] as? String ?? "paragraph"
        if kind == "image" || kind == "file" { attrs = defaultAttributes() }
        attrs[.font] = attrs[.font] ?? NSFont.systemFont(ofSize:NotesContinuousDocument.bodySize * readingScale)
        attrs[.foregroundColor] = NSColor(NotesTheme.text)
        attrs[.notesBlock] = attrs[.notesBlock] ?? UUID().uuidString
        attrs[.notesKind] = attrs[.notesKind] ?? "paragraph"
        typingAttributes = attrs
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, !loading, !hasMarkedText() { session?.captureBodySelection(selectedRange()) }
        return allowed
    }
    override func didChangeText() {
        if !loading, !hasMarkedText(), !normalizing, let storage = textStorage {
            normalizing = true
            let selection = selectedRange(), typing = typingAttributes
            NotesContinuousDocument.normalizeLayout(storage, scale:readingScale)
            setSelectedRange(selection); typingAttributes = typing; cleanTypingAttributes()
            normalizing = false
        }
        super.didChangeText()
        if !loading, !hasMarkedText() { publishChange(); onLayout?() }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        cleanTypingAttributes()
        if !hasMarkedText(), let value = insertString as? String, !value.isEmpty {
            let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let attrs = attributes(at:selection.location)
            if selection.length == 0, let kind = attrs[.notesKind] as? String, kind == "image" || kind == "file" {
                let paragraph = (string as NSString).paragraphRange(for:NSRange(location:selection.location,length:0))
                let before = selection.location == paragraph.location
                setSelectedRange(NSRange(location:before ? paragraph.location : NSMaxRange(paragraph),length:0))
                var attrs = defaultAttributes()
                if !before, !string.hasSuffix("\n") { super.insertText(NSAttributedString(string:"\n",attributes:attrs),replacementRange:selectedRange()) }
                attrs[.notesBlock] = UUID().uuidString
                typingAttributes = attrs
                super.insertText(NSAttributedString(string:value + (before ? "\n" : ""),attributes:attrs),replacementRange:selectedRange())
                return
            }
        }
        super.insertText(insertString, replacementRange:replacementRange)
        if !hasMarkedText() { publishChange(); onLayout?() }
    }
    override func unmarkText() {
        super.unmarkText()
        if !loading { cleanTypingAttributes(); publishChange(); onLayout?() }
    }
    private func paragraphRanges() -> [NSRange] {
        let ns = string as NSString, selection = selectedRange()
        if ns.length == 0 || selection.location == ns.length && ns.hasSuffix("\n") { return [NSRange(location:ns.length,length:0)] }
        let end = min(ns.length, selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location)
        var cursor = min(selection.location,max(0,ns.length - 1)), result:[NSRange] = []
        repeat {
            let range = ns.paragraphRange(for:NSRange(location:cursor,length:0))
            result.append(range)
            if NSMaxRange(range) > end || NSMaxRange(range) <= cursor { break }
            cursor = NSMaxRange(range)
        } while cursor < ns.length
        return result
    }
    override func format(_ action: NotesTextFormat) {
        if action == .bullets { toggleList("bullet") }
        else { super.format(action) }
        onLayout?()
    }
    func setHeading(_ level: Int) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        session?.captureBodySelection(selectedRange())
        session?.endTypingGroup()
        let selected = selectedRange()
        var emptyAttributes: [NSAttributedString.Key: Any]?
        for range in paragraphRanges() {
            guard range.length > 0 else {
                var attrs = typingAttributes; attrs[.notesHeading] = level
                attrs[.font] = headingFont(level); emptyAttributes = attrs; trailingAttributes = attrs; continue
            }
            let kind = attributes(at:range.location)[.notesKind] as? String
            if kind == "image" || kind == "file" { continue }
            storage.addAttribute(.notesBlock,value:UUID().uuidString,range:range)
            storage.addAttribute(.notesHeading,value:level,range:range)
            storage.addAttribute(.font,value:headingFont(level),range:range)
        }
        setSelectedRange(selected)
        if let emptyAttributes { typingAttributes = emptyAttributes }
        didChangeText(); session?.endTypingGroup()
    }
    private func headingFont(_ level: Int) -> NSFont {
        NSFont.systemFont(ofSize:NotesContinuousDocument.bodySize * (level == 1 ? 1.65 : level == 2 ? 1.28 : 1) * readingScale, weight:level == 0 ? .regular : .semibold)
    }
    func setTextSize(_ size: CGFloat?) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        if selectedRange().length > 0 { session?.captureBodySelection(selectedRange()) }
        session?.endTypingGroup()
        let selection = selectedRange()
        func defaultSize(_ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
            let heading = attributes[.notesHeading] as? Int ?? 0
            return NotesContinuousDocument.bodySize * (heading == 1 ? 1.65 : heading == 2 ? 1.28 : 1)
        }
        if selection.length == 0 {
            var attrs = typingAttributes
            let font = attrs[.font] as? NSFont ?? headingFont(0)
            attrs[.font] = NSFontManager.shared.convert(font,toSize:(size ?? defaultSize(attrs)) * readingScale)
            typingAttributes = attrs
        } else {
            let before = NSAttributedString(attributedString:storage)
            before.enumerateAttributes(in:selection) { attributes,range,_ in
                let font = attributes[.font] as? NSFont ?? self.headingFont(0)
                storage.addAttribute(.font,value:NSFontManager.shared.convert(font,toSize:(size ?? defaultSize(attributes)) * self.readingScale),range:range)
            }
            setSelectedRange(selection); didChangeText()
        }
        session?.endTypingGroup()
    }
    func toggleList(_ kind: String) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        session?.captureBodySelection(selectedRange())
        session?.endTypingGroup()
        let ranges = paragraphRanges(), selected = selectedRange()
        let remove = ranges.allSatisfy { attributes(at:$0.location)[.notesKind] as? String == kind }
        var start = selected.location, end = NSMaxRange(selected)
        var emptyAttributes: [NSAttributedString.Key: Any]?
        for range in ranges.reversed() {
            var attrs = attributes(at:range.location)
            if let kind = attrs[.notesKind] as? String, kind == "image" || kind == "file" { continue }
            let oldMarker = range.location < storage.length && attrs[.notesMarker] as? Bool == true ? min(2,range.length) : 0
            if oldMarker > 0 { storage.deleteCharacters(in:NSRange(location:range.location,length:oldMarker)) }
            attrs[.notesKind] = remove ? "paragraph" : kind
            attrs[.notesChecked] = false
            attrs.removeValue(forKey:.notesMarker); attrs.removeValue(forKey:.attachment)
            // A converted list item is a separate paragraph even when old plain text shared a block.
            attrs[.notesBlock] = UUID().uuidString
            let adjusted = NSRange(location:range.location,length:range.length - oldMarker)
            if adjusted.length > 0 { storage.addAttributes(attrs,range:adjusted) }
            let marker = remove ? NSAttributedString(string:"") : kind == "checklist" ? NotesContinuousDocument.taskMarker(checked:false,size:(attrs[.font] as? NSFont)?.pointSize ?? NotesContinuousDocument.bodySize * readingScale) : NSAttributedString(string:"•\t",attributes:[.notesMarker:true,.font:attrs[.font] ?? headingFont(0)])
            let inserted = NSMutableAttributedString(attributedString:marker)
            if inserted.length > 0 { inserted.addAttributes(attrs,range:NSRange(location:0,length:inserted.length)); storage.insert(inserted,at:range.location) }
            func map(_ position:Int) -> Int { position >= range.location + oldMarker ? position - oldMarker + inserted.length : position > range.location ? range.location + inserted.length : position }
            start = map(start); end = map(end)
            if adjusted.length == 0, inserted.length == 0, range.location == storage.length { emptyAttributes = attrs; trailingAttributes = attrs }
        }
        setSelectedRange(NSRange(location:min(start,storage.length),length:max(0,min(end,storage.length) - min(start,storage.length))))
        if let emptyAttributes { typingAttributes = emptyAttributes }
        cleanTypingAttributes(); didChangeText(); session?.endTypingGroup()
        window?.makeFirstResponder(self)
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { super.insertNewline(sender); return }
        let selection = selectedRange(), ranges = paragraphRanges()
        guard let range = ranges.first else { return }
        var attrs = attributes(at:range.location)
        let kind = attrs[.notesKind] as? String ?? "paragraph"
        if kind == "checklist" || kind == "bullet", range.length <= 2 || range.length == 3 && (string as NSString).substring(with:NSRange(location:NSMaxRange(range) - 1,length:1)) == "\n" {
            toggleList(kind); return
        }
        attrs[.notesBlock] = UUID().uuidString; attrs[.notesChecked] = false
        attrs.removeValue(forKey:.attachment); attrs.removeValue(forKey:.notesMarker)
        if kind == "image" || kind == "file" || (attrs[.notesHeading] as? Int ?? 0) > 0 && selection.location >= NSMaxRange(range) - (string as NSString).substring(with:range).hasSuffix("\n").intValue {
            attrs = defaultAttributes()
        }
        var newlineAttrs = attributes(at:max(range.location,selection.location - 1))
        newlineAttrs.removeValue(forKey:.notesMarker); newlineAttrs.removeValue(forKey:.attachment)
        let next = NSMutableAttributedString(string:"\n",attributes:newlineAttrs)
        if kind == "checklist" || kind == "bullet" {
            let marker = kind == "checklist" ? NotesContinuousDocument.taskMarker(checked:false,size:(attrs[.font] as? NSFont)?.pointSize ?? NotesContinuousDocument.bodySize * readingScale) : NSAttributedString(string:"•\t",attributes:[.notesMarker:true,.font:attrs[.font] ?? headingFont(0)])
            let value = NSMutableAttributedString(attributedString:marker); value.addAttributes(attrs,range:NSRange(location:0,length:value.length)); next.append(value)
        }
        guard shouldChangeText(in:selection,replacementString:next.string) else { return }
        storage.replaceCharacters(in:selection,with:next)
        let caret = selection.location + next.length
        // A split paragraph gets its own identity and semantic type, including existing trailing text.
        if caret < storage.length {
            let tail = (storage.string as NSString).paragraphRange(for:NSRange(location:caret,length:0))
            storage.addAttributes(attrs,range:tail)
        }
        if caret == storage.length { trailingAttributes = attrs }
        setSelectedRange(NSRange(location:caret,length:0)); typingAttributes = attrs
        didChangeText(); scrollRangeToVisible(selectedRange())
    }
    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0, let range = paragraphRanges().first else { super.deleteBackward(sender); return }
        let attrs = attributes(at:range.location), kind = attrs[.notesKind] as? String
        if (kind == "checklist" || kind == "bullet"), selectedRange().location <= range.location + 2 { toggleList(kind!); return }
        super.deleteBackward(sender)
    }
    @discardableResult func insertPasted(_ value: NSAttributedString) -> Bool {
        let safe = NSMutableAttributedString(attributedString:value)
        let source = NSAttributedString(attributedString:safe)
        source.enumerateAttributes(in:NSRange(location:0,length:source.length)) { attrs,range,_ in
            for key in [.notesBlock,.notesKind,.notesHeading,.notesChecked,.notesMarker,.notesAttachment,.notesAttachmentName] as [NSAttributedString.Key] { safe.removeAttribute(key,range:range) }
            let original = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize:NotesContinuousDocument.bodySize)
            let heading = min(2,max(0,(attrs[.paragraphStyle] as? NSParagraphStyle)?.headerLevel ?? 0))
            var font: NSFont
            if preservePastedFormatting { font = NSFontManager.shared.convert(original,toSize:original.pointSize * readingScale) }
            else {
                font = headingFont(heading)
                let traits = NSFontManager.shared.traits(of:original)
                if traits.contains(.boldFontMask) { font = NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
                if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) }
            }
            if !preservePastedFormatting { font = NSFontManager.shared.convert(font,toSize:NotesContinuousDocument.bodySize * (heading == 1 ? 1.65 : heading == 2 ? 1.28 : 1) * readingScale) }
            safe.addAttributes([.font:font,.foregroundColor:NSColor(NotesTheme.text)],range:range)
        }
        let ns = source.string as NSString
        var paragraphs:[NSRange] = [], cursor = 0
        while cursor < ns.length { let range = ns.paragraphRange(for:NSRange(location:cursor,length:0)); paragraphs.append(range); cursor = NSMaxRange(range) }
        for range in paragraphs.reversed() {
            let style = source.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle
            let heading = min(2,max(0,style?.headerLevel ?? 0))
            let text = ns.substring(with:range)
            let bullet = style?.textLists.isEmpty == false || text.hasPrefix("• ") || text.hasPrefix("•\t") || text.hasPrefix("\t•\t")
            let attrs:[NSAttributedString.Key:Any] = [.notesBlock:UUID().uuidString,.notesKind:bullet ? "bullet" : "paragraph",.notesHeading:heading,.notesChecked:false]
            safe.addAttributes(attrs,range:range)
            if bullet {
                let prefix = text.hasPrefix("\t•\t") ? 3 : text.hasPrefix("• ") || text.hasPrefix("•\t") ? 2 : 0
                if prefix > 0 { safe.deleteCharacters(in:NSRange(location:range.location,length:prefix)) }
                let marker = NSMutableAttributedString(string:"•\t",attributes:[.notesMarker:true,.font:headingFont(0)])
                marker.addAttributes(attrs,range:NSRange(location:0,length:marker.length)); safe.insert(marker,at:range.location)
            }
        }
        var embedded: [(NSTextAttachment, NSRange)] = []
        safe.enumerateAttribute(.attachment, in: NSRange(location: 0, length: safe.length)) { token, range, _ in
            if let token = token as? NSTextAttachment { embedded.append((token, range)) }
        }
        if !embedded.isEmpty {
            do {
                var assets: [ClipboardAsset] = [], total = 0
                for (token, range) in embedded {
                    guard range.length == 1, (safe.string as NSString).character(at: range.location) == 0xFFFC,
                          let wrapper = token.fileWrapper, wrapper.isRegularFile,
                          let bytes = wrapper.regularFileContents else { throw ClipboardError.unavailable }
                    guard bytes.count <= Self.clipboardLimit - total else { throw ClipboardError.tooLarge }
                    let name = wrapper.preferredFilename ?? wrapper.filename ?? "粘贴附件"
                    guard Self.validClipboardName(name) else { throw ClipboardError.invalid }
                    let image = UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true
                    let asset = ClipboardAsset(id: UUID(), name: name, kind: image ? .image : .file, bytes: bytes, digest: Self.digest(bytes))
                    assets.append(asset); total += bytes.count
                    safe.addAttributes([.notesAttachment: asset.id.uuidString, .notesAttachmentName: name, .notesKind: image ? "image" : "file"], range: range)
                }
                let blocks = try NotesContinuousDocument.blocks(from: safe, scale: readingScale)
                let payload = ClipboardSelection(version: 1, blocks: clipboardBlocks(blocks), assets: assets)
                return pasteClipboardSelection(payload)
            } catch {
                session?.reportAttachmentFailure("粘贴未完成：" + error.localizedDescription); return false
            }
        }
        NotesContinuousDocument.normalizeLayout(safe,scale:readingScale)
        let selection = selectedRange()
        guard shouldChangeText(in:selection,replacementString:safe.string) else { return false }
        textStorage?.replaceCharacters(in:selection,with:safe)
        setSelectedRange(NSRange(location:selection.location + safe.length,length:0))
        cleanTypingAttributes(); didChangeText()
        return true
    }
    /// Native RTFD drops our display-only attachment cells. The private flavor
    /// carries a self-contained, validated value; it never grants access to a path.
    static let ownedSelectionType = NSPasteboard.PasteboardType("local.shipian.owned-selection.v1")
    private struct ClipboardStyle: Codable {
        var location: Int; var length: Int; var size: Double; var fontName: String
        var bold: Bool; var italic: Bool; var underline: Int; var strike: Int
    }
    private struct ClipboardBlock: Codable {
        var kind: NoteBlock.Kind; var text: String; var heading: Int; var bullet: Bool
        var checked: Bool; var attachment: UUID?; var styles: [ClipboardStyle]
    }
    private struct ClipboardAsset: Codable {
        var id: UUID; var name: String; var kind: NoteAttachment.Kind; var bytes: Data; var digest: String
    }
    private struct ClipboardSelection: Codable { var version: Int; var blocks: [ClipboardBlock]; var assets: [ClipboardAsset] }
    private enum ClipboardError: LocalizedError {
        case invalid, unavailable, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "剪贴板内容不完整或未通过校验。原内容已保留，请重新复制。"
            case .unavailable: return "附件副本暂时无法读取。原内容已保留，请重试或先导出完整副本。"
            case .tooLarge: return "所选内容超过单次剪贴板容量，请分批复制或导出闪念。"
            }
        }
    }
    private static let clipboardLimit = 256 * 1024 * 1024
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validClipboardName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && name.utf8.count <= 255
    }
    private func clipboardBlocks(_ blocks: [NoteBlock]) -> [ClipboardBlock] {
        blocks.map { block in
            var styles: [ClipboardStyle] = []
            if let rtf = block.richText, let rich = NSAttributedString(rtf: rtf, documentAttributes: nil), rich.string == block.text {
                rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, range, _ in
                    let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: NotesContinuousDocument.bodySize)
                    let traits = NSFontManager.shared.traits(of: font)
                    styles.append(ClipboardStyle(location: range.location, length: range.length, size: Double(font.pointSize), fontName: font.fontName, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask), underline: attrs[.underlineStyle] as? Int ?? 0, strike: attrs[.strikethroughStyle] as? Int ?? 0))
                }
            }
            return ClipboardBlock(kind: block.kind, text: block.text, heading: block.markdown?.hasPrefix("# ") == true ? 1 : block.markdown?.hasPrefix("## ") == true ? 2 : 0, bullet: block.kind == .paragraph && block.markdown?.hasPrefix("- ") == true, checked: block.isChecked, attachment: block.attachmentID, styles: styles)
        }
    }
    private func clipboardSelection() throws -> ClipboardSelection {
        let selection = selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= attributedString().length, !hasMarkedText() else { throw ClipboardError.invalid }
        let selected = attributedString().attributedSubstring(from: selection)
        let blocks = try NotesContinuousDocument.blocks(from: selected, scale: readingScale)
        var assets: [ClipboardAsset] = [], copied = Set<UUID>()
        var total = 0
        for block in blocks {
            if block.kind == .image || block.kind == .file {
                guard let session, let id = block.attachmentID, let attachment = session.note.attachments.first(where: { $0.id == id }), Self.validClipboardName(attachment.name) else { throw ClipboardError.unavailable }
                if copied.insert(id).inserted {
                    let url = try session.localURL(for: attachment)
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ClipboardError.unavailable }
                    guard let count = info.fileSize, count <= Self.clipboardLimit - total else { throw ClipboardError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count == attachment.byteCount else { throw ClipboardError.unavailable }
                    total += data.count
                    assets.append(ClipboardAsset(id: id, name: attachment.name, kind: attachment.kind, bytes: data, digest: Self.digest(data)))
                }
            }
        }
        return ClipboardSelection(version: 1, blocks: clipboardBlocks(blocks), assets: assets)
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.ownedSelectionType] + super.writablePasteboardTypes }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.ownedSelectionType] + super.readablePasteboardTypes }
    override func writeSelection(to board: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        do {
            let payload = try clipboardSelection()
            try validate(payload)
            let data = try JSONEncoder().encode(payload)
            guard data.count <= Self.clipboardLimit else { throw ClipboardError.tooLarge }
            let selected = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: selectedRange()))
            // Give other applications real file wrappers, instead of a drawing cell.
            selected.enumerateAttribute(.notesAttachment, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
                guard let id = (value as? String).flatMap(UUID.init(uuidString:)), let asset = payload.assets.first(where: { $0.id == id }) else { return }
                let wrapper = FileWrapper(regularFileWithContents: asset.bytes); wrapper.preferredFilename = asset.name
                selected.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: wrapper), range: NSRange(location: range.location, length: 1))
            }
            let external = try selected.data(from: NSRange(location: 0, length: selected.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            board.declareTypes([Self.ownedSelectionType, .rtfd, .string], owner: nil)
            guard board.setData(data, forType: Self.ownedSelectionType) else { throw ClipboardError.unavailable }
            _ = board.setData(external, forType: .rtfd)
            _ = board.setString(payload.blocks.map { block in block.kind == .checklist ? "\(block.checked ? "☑" : "☐") \(block.text)" : block.text }.joined(separator: "\n"), forType: .string)
            return true
        } catch { session?.reportAttachmentFailure("复制未完成：" + error.localizedDescription); return false }
    }
    override func copy(_ sender: Any?) { _ = writeSelection(to: .general, types: writablePasteboardTypes) }
    override func cut(_ sender: Any?) { _ = cut(to: .general) }
    @discardableResult func cut(to board: NSPasteboard) -> Bool {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length > 0, shouldChangeText(in: selection, replacementString: "") else { return false }
        do {
            let payload = try clipboardSelection()
            if let session { try session.prepareAttachmentsForRemoval(session.note.attachments.filter { asset in payload.assets.contains(where: { $0.id == asset.id }) }) }
            guard writeSelection(to: board, types: writablePasteboardTypes) else { return false }
            session?.endTypingGroup()
            textStorage?.replaceCharacters(in: selection, with: "")
            setSelectedRange(NSRange(location: selection.location, length: 0)); cleanTypingAttributes(); didChangeText(); session?.endTypingGroup()
            return true
        } catch { session?.reportAttachmentFailure("剪切未完成：" + error.localizedDescription); return false }
    }
    private func validate(_ payload: ClipboardSelection) throws {
        guard payload.version == 1, !payload.blocks.isEmpty, payload.blocks.count <= 100_000, payload.assets.count <= 10_000 else { throw ClipboardError.invalid }
        let ids = Set(payload.assets.map(\.id)); guard ids.count == payload.assets.count else { throw ClipboardError.invalid }
        var total = 0, referenced = Set<UUID>()
        for asset in payload.assets {
            guard Self.validClipboardName(asset.name), asset.bytes.count <= Self.clipboardLimit - total, Self.digest(asset.bytes) == asset.digest else { throw ClipboardError.invalid }
            total += asset.bytes.count
            let inferred = UTType(filenameExtension: (asset.name as NSString).pathExtension)?.conforms(to: .image) == true
            guard inferred == (asset.kind == .image), asset.kind != .image || NSImage(data: asset.bytes) != nil else { throw ClipboardError.invalid }
        }
        for block in payload.blocks {
            guard (0...2).contains(block.heading), block.text.utf16.count <= Self.clipboardLimit else { throw ClipboardError.invalid }
            if block.kind == .image || block.kind == .file {
                guard let id = block.attachment, let asset = payload.assets.first(where: { $0.id == id }), (block.kind == .image) == (asset.kind == .image) else { throw ClipboardError.invalid }
                referenced.insert(id)
            } else if block.attachment != nil { throw ClipboardError.invalid }
            for style in block.styles {
                guard style.location >= 0, style.length >= 0, style.location <= block.text.utf16.count, style.length <= block.text.utf16.count - style.location, style.size.isFinite, style.size >= 1, style.size <= 1000, style.fontName.utf8.count <= 255 else { throw ClipboardError.invalid }
            }
        }
        guard ids == referenced else { throw ClipboardError.invalid }
    }
    private func pasteOwnedSelection(_ data: Data) -> Bool {
        do {
            guard data.count <= Self.clipboardLimit else { throw ClipboardError.tooLarge }
            return pasteClipboardSelection(try JSONDecoder().decode(ClipboardSelection.self, from: data))
        } catch { session?.reportAttachmentFailure("粘贴未完成：" + error.localizedDescription); return false }
    }
    private func pasteClipboardSelection(_ payload: ClipboardSelection) -> Bool {
        var rollback: (NotesEditorSession, NoteDocument, NSRange)?
        do {
            guard !hasMarkedText() else { throw ClipboardError.invalid }
            try validate(payload)
            guard let session else { throw ClipboardError.unavailable }
            let original = NSMutableAttributedString(attributedString: attributedString()), selection = selectedRange()
            guard shouldChangeText(in: selection, replacementString: payload.blocks.map(\.text).joined(separator: "\n")) else { return false }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-clipboard-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var urls: [URL] = []
            for asset in payload.assets {
                let parent = folder.appendingPathComponent(asset.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = parent.appendingPathComponent(asset.name); try asset.bytes.write(to: url, options: .atomic); urls.append(url)
            }
            try session.commit()
            let old = session.note, oldIDs = Set(old.attachments.map(\.id))
            try session.prepareAttachmentsForRemoval(old.attachments)
            rollback = (session, old, selection)
            let previousAttachmentFailure = session.attachmentFailure
            session.endTypingGroup(); session.undoManager.beginUndoGrouping()
            defer { session.undoManager.endUndoGrouping(); session.endTypingGroup() }
            if !urls.isEmpty { session.importURLs(urls) }
            let additions = session.note.attachments.filter { !oldIDs.contains($0.id) }
            guard additions.count == payload.assets.count, session.attachmentFailure == nil || session.attachmentFailure == previousAttachmentFailure else { throw ClipboardError.unavailable }
            var replacements: [UUID: NoteAttachment] = [:]
            for (asset, attachment) in zip(payload.assets, additions) { replacements[asset.id] = attachment }
            let blocks = try payload.blocks.map { value -> NoteBlock in
                if let assetID = value.attachment, let attachment = replacements[assetID] { return NoteBlock(kind: value.kind, text: attachment.name, attachmentID: attachment.id) }
                let rich = NSMutableAttributedString(string: value.text, attributes: [.font: NSFont.systemFont(ofSize: NotesContinuousDocument.bodySize * (value.heading == 1 ? 1.65 : value.heading == 2 ? 1.28 : 1))])
                for style in value.styles {
                    let size = preservePastedFormatting ? style.size : NotesContinuousDocument.bodySize * (value.heading == 1 ? 1.65 : value.heading == 2 ? 1.28 : 1)
                    var font = preservePastedFormatting ? (NSFont(name: style.fontName, size: size) ?? NSFont.systemFont(ofSize: size)) : NSFont.systemFont(ofSize: size)
                    if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    rich.addAttributes([.font: font, .underlineStyle: style.underline, .strikethroughStyle: style.strike], range: NSRange(location: style.location, length: style.length))
                }
                let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                let markdown = value.heading == 1 ? "# " + value.text : value.heading == 2 ? "## " + value.text : value.bullet ? "- " + value.text : value.text
                return NoteBlock(kind: value.kind, text: value.text, richText: rtf, markdown: markdown, isChecked: value.checked)
            }
            let fragment = NotesContinuousDocument.render(NoteDocument(blocks: blocks, attachments: additions), scale: readingScale, width: max(150, bounds.width), image: { attachment in (try? session.localURL(for: attachment)).flatMap(NSImage.init(contentsOf:)) })
            original.replaceCharacters(in: selection, with: fragment)
            let result = try NotesContinuousDocument.blocks(from: original, scale: readingScale, trailingAttributes: trailingAttributes)
            session.change("粘贴闪念内容") { note in
                let references = Set(result.compactMap(\.attachmentID))
                note.blocks = result; note.attachments.removeAll { !references.contains($0.id) }
            }
            loadDocument(session.note)
            setSelectedRange(NSRange(location: min(selection.location + fragment.length, string.utf16.count), length: 0)); cleanTypingAttributes(); onLayout?()
            rollback = nil
            return true
        } catch {
            if let (session, original, selection) = rollback {
                // Store import may publish a partial addition before a disk/conflict
                // error. Keep the target's original contents in memory and journal.
                session.note = original; session.edited()
                loadDocument(original); setSelectedRange(selection); onLayout?()
                try? session.commit()
            }
            session?.reportAttachmentFailure("粘贴未完成：" + error.localizedDescription); return false
        }
    }
    override func readSelection(from board: NSPasteboard) -> Bool {
        if board.types?.contains(Self.ownedSelectionType) == true {
            guard let data = board.data(forType: Self.ownedSelectionType) else { session?.reportAttachmentFailure(ClipboardError.invalid.localizedDescription); return false }
            return pasteOwnedSelection(data)
        }
        return paste(from: board)
    }
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if board.types?.contains(Self.ownedSelectionType) == true { return readSelection(from: board) }
        return paste(from: board)
    }
    override func paste(_ sender: Any?) { _ = readSelection(from: .general) }
    private func paste(from board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty { session?.importURLs(urls); return true }
        var rich: NSAttributedString?
        if let data = board.data(forType:.rtfd) { rich = NSAttributedString(rtfd:data,documentAttributes:nil) }
        if rich == nil, let data = board.data(forType:.rtf) { rich = NSAttributedString(rtf:data,documentAttributes:nil) }
        if rich == nil, let data = board.data(forType:.html) { rich = NSAttributedString(html:data,documentAttributes:nil) }
        if let rich, rich.length > 0 { return insertPasted(rich) }
        if let text = board.string(forType:.string) { insertText(text,replacementRange:selectedRange()); return true }
        if let image = NSImage(pasteboard:board) { session?.pasteImage(image); return true }
        return false
    }
    override func mouseDown(with event: NSEvent) {
        if let location = character(at:event) {
            let attrs = attributes(at:location)
            if attrs[.notesMarker] as? Bool == true, attrs[.notesKind] as? String == "checklist", let storage = textStorage {
                let range = (string as NSString).paragraphRange(for:NSRange(location:location,length:0))
                session?.captureBodySelection(selectedRange())
                session?.endTypingGroup(); storage.addAttribute(.notesChecked,value:!(attrs[.notesChecked] as? Bool ?? false),range:range); didChangeText(); session?.endTypingGroup(); return
            }
            if let id = (attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)), let attachment = session?.note.attachments.first(where:{$0.id == id}) { onAttachment?(attachment); return }
        }
        super.mouseDown(with:event)
    }
    private func character(at event:NSEvent) -> Int? {
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else { return nil }
        let point = convert(event.locationInWindow,from:nil), local = NSPoint(x:point.x - textContainerOrigin.x,y:point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for:local,in:textContainer,fractionOfDistanceBetweenInsertionPoints:nil)
        guard index < textStorage!.length else { return nil }
        let glyph = layoutManager.glyphRange(forCharacterRange:NSRange(location:index,length:1),actualCharacterRange:nil)
        return layoutManager.boundingRect(forGlyphRange:glyph,in:textContainer).contains(local) ? index : nil
    }
    override func rightMouseDown(with event: NSEvent) {
        if let location = character(at:event), let id = (attributes(at:location)[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)), let attachment = session?.note.attachments.first(where:{$0.id == id}), let session {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(attachment.kind == .image ? "放大图片" : "打开附件") { [weak self] in self?.onAttachment?(attachment) }.notesSymbol(attachment.kind == .image ? "photo" : "arrow.up.forward.app"))
            menu.addItem(ClosureMenuItem("导出附件…") { session.exportAttachment(attachment) }.notesSymbol("square.and.arrow.up"))
            menu.addItem(.separator()); let remove = ClosureMenuItem("移除附件") { session.removeAttachment(attachment) }.notesSymbol("trash"); remove.notesDestructive = true; menu.addItem(remove)
            NotesMenuPresenter.shared.show(menu,from:self,at:convert(event.locationInWindow,from:nil)); return
        }
        super.rightMouseDown(with:event)
    }
    var plainTextForBackup: String {
        let source = attributedString(), copy = NSMutableAttributedString(attributedString: attributedString())
        var replacements: [(NSRange,String)] = []
        source.enumerateAttribute(.attachment,in:NSRange(location:0,length:source.length)) { value,range,_ in
            guard value != nil else { return }
            let attrs = source.attributes(at:range.location,effectiveRange:nil)
            let label = attrs[.notesMarker] as? Bool == true ? ((attrs[.notesChecked] as? Bool == true) ? "☑" : "☐") : "[" + (attrs[.notesAttachmentName] as? String ?? "附件") + "]"
            replacements.append((range,label))
        }
        for (range,label) in replacements.reversed() { copy.replaceCharacters(in:range,with:label) }
        return copy.string
    }
    var selectionHeading: Int? { selectedValues(.notesHeading).compactMap{$0 as? Int}.uniqueValue }
    var selectionSize: CGFloat? { selectedValues(.font).compactMap{($0 as? NSFont).map{$0.pointSize / readingScale}}.uniqueValue }
    func isSelected(_ action:NotesTextFormat) -> Bool {
        let attrs = selectedRange().length == 0 ? typingAttributes : attributes(at:selectedRange().location)
        let font = attrs[.font] as? NSFont ?? headingFont(0)
        switch action { case .bold:return NSFontManager.shared.traits(of:font).contains(.boldFontMask); case .italic:return NSFontManager.shared.traits(of:font).contains(.italicFontMask); case .underline:return (attrs[.underlineStyle] as? Int ?? 0) != 0; case .bullets:return attrs[.notesKind] as? String == "bullet" }
    }
    private func selectedValues(_ key:NSAttributedString.Key) -> [Any] {
        let selection = selectedRange()
        if selection.length == 0 { return [typingAttributes[key] ?? attributes(at:selection.location)[key] ?? 0] }
        var values:[Any] = []; textStorage?.enumerateAttribute(key,in:selection) { value,_,_ in if let value { values.append(value) } }; return values
    }
}
private extension Bool { var intValue:Int { self ? 1 : 0 } }
private extension Array where Element: Equatable { var uniqueValue:Element? { guard let first, allSatisfy({$0 == first}) else { return nil }; return first } }

struct NotesContinuousBody: NSViewRepresentable {
    @ObservedObject var session:NotesEditorSession
    let scale:CGFloat
    var onHeight:(CGFloat)->Void
    var onAttachment:(NoteAttachment)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NotesContinuousTextView {
        let view = NotesContinuousTextView(frame:NSRect(x:0,y:0,width:500,height:100),textContainer:nil)
        view.session = session; session.textView = view; view.readingScale = scale
        view.preservePastedFormatting = UserDefaults.standard.string(forKey:"notesPasteMode") == "preserve"
        view.delegate = context.coordinator
        view.imageProvider = { [weak session] attachment in guard let session, let url = try? session.localURL(for:attachment) else { return nil }; return NotesImageCache.shared.image(at:url) }
        view.onAttachment = onAttachment
        view.publish = { [weak coordinator = context.coordinator] in coordinator?.publish() }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.view = view; context.coordinator.load(); return view
    }
    func updateNSView(_ view:NotesContinuousTextView, context:Context) {
        context.coordinator.parent = self
        view.onAttachment = onAttachment
        view.preservePastedFormatting = UserDefaults.standard.string(forKey:"notesPasteMode") == "preserve"
        if !view.hasMarkedText(), context.coordinator.lastBlocks != session.note.blocks || view.readingScale != scale || context.coordinator.imageRevision != NotesImageCache.shared.revision || session.bodySelectionToRestore != nil {
            view.readingScale = scale; context.coordinator.load()
        }
        context.coordinator.measure()
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NotesContinuousTextView,context:Context)->CGSize? {
        let width = max(100,proposal.width ?? 500)
        nsView.textContainer?.containerSize = NSSize(width:width,height:.greatestFiniteMagnitude)
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return CGSize(width:width,height:100) }
        manager.ensureLayout(for:container)
        return CGSize(width:width,height:max(proposal.height ?? 100,manager.usedRect(for:container).height + 16))
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:NotesContinuousBody
        weak var view:NotesContinuousTextView?
        var lastBlocks:[NoteBlock] = []
        var imageRevision = 0
        private var measured:CGFloat = 0
        init(_ parent:NotesContinuousBody) { self.parent = parent }
        func load() {
            guard let view, !view.hasMarkedText() else { return }
            lastBlocks = parent.session.note.blocks; imageRevision = NotesImageCache.shared.revision
            view.loadDocument(parent.session.note)
            // Import puts the caret in the new paragraph after the attachment.
            if let focused = parent.session.focusedBlock, focused != view.blockID {
                view.textStorage?.enumerateAttribute(.notesBlock,in:NSRange(location:0,length:view.textStorage?.length ?? 0)) { id,range,stop in
                    if id as? String == focused.uuidString { view.setSelectedRange(NSRange(location:range.location,length:0)); view.blockID = focused; stop.pointee = true }
                }
            }
            if let selection = parent.session.consumeBodySelection() {
                let length = view.textStorage?.length ?? 0, location = min(selection.location, view.textStorage?.length ?? 0)
                view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
                view.cleanTypingAttributes()
            }
        }
        func publish() {
            guard let view, !view.loading, !view.hasMarkedText() else { return }
            do {
                let blocks = try NotesContinuousDocument.blocks(from:view.attributedString(),scale:view.readingScale,trailingAttributes:view.trailingAttributes)
                if let previous = parent.session.pendingTextFailure, parent.session.failure == previous { parent.session.failure = nil }
                parent.session.pendingTextFailure = nil
                lastBlocks = blocks; parent.session.updateBlocks(blocks)
            } catch {
                let reason = "正文尚未保存，请保留窗口并复制内容。" + error.localizedDescription
                parent.session.pendingTextFailure = reason; parent.session.dirty = true
                parent.session.recoveryProtected = false; parent.session.failure = reason
            }
        }
        func textViewDidChangeSelection(_ notification:Notification) {
            guard let view, !view.loading, !view.hasMarkedText() else { return }
            view.cleanTypingAttributes()
            let index = min(view.selectedRange().location,max(0,(view.textStorage?.length ?? 0) - 1))
            if (view.textStorage?.length ?? 0) > 0, let id = (view.textStorage?.attribute(.notesBlock,at:index,effectiveRange:nil) as? String).flatMap(UUID.init(uuidString:)) { view.blockID = id; parent.session.focusedBlock = id }
        }
        func measure() {
            guard let view, let container = view.textContainer, let manager = view.layoutManager else { return }
            manager.ensureLayout(for:container)
            let height = max(100,manager.usedRect(for:container).height + 16)
            if abs(height - measured) > 0.5 { measured = height; DispatchQueue.main.async { [weak self] in self?.parent.onHeight(height) } }
        }
    }
}
