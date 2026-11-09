import AppKit
import SwiftUI
import NotesCore
import CryptoKit
import UniformTypeIdentifiers

/// One native text system owns the entire body, including selection and IME composition.
@MainActor final class NotesContinuousTextView: NotesTextView {
    let linkPastes = NotesLinkPasteController()
    let bodyEncodingCache = NotesContinuousDocument.BodyEncodingCache()
    private var ownedStorage: NSTextStorage?
    var trailingAttributes: [NSAttributedString.Key: Any] = [:]
    var readingScale: CGFloat = 1
    var preservePastedFormatting = false
    var clipboard: NSPasteboard = .general
    var imageProvider: (NoteAttachment) -> NSImage? = { _ in nil }
    private var visibleImages: [UUID: NSImage] = [:]
    func pruneVisibleImages(to references: Set<UUID>) { visibleImages = visibleImages.filter { references.contains($0.key) } }
    @discardableResult func refreshVisibleImages(_ note: NoteDocument) -> Bool {
        let active = Set(note.attachments.map(\.id))
        visibleImages = visibleImages.filter { active.contains($0.key) }
        var changed = false
        for attachment in note.attachments where attachment.kind == .image && visibleImages[attachment.id] == nil {
            if let image = imageProvider(attachment) { visibleImages[attachment.id] = image; changed = true }
        }
        return changed
    }
    lazy var contextTools = NotesEditorContextTools(view: self)
    private var imageEntrance: Timer?
    private var dropCaret: NSRect?
    var onAttachment: ((NoteAttachment) -> Void)?
    var onDropTargetChange: (Bool) -> Void = { _ in }
    private var dropTargeted = false
    private func showDropTarget(_ targeted: Bool) {
        guard dropTargeted != targeted else { return }; dropTargeted = targeted; onDropTargetChange(targeted)
    }
    var loading = false
    private var normalizing = false
    private var publicationRevision = 0
    private var typingInsertion: NSRange?
    private var renderedWidth: CGFloat = 0
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let actual: NSTextContainer
        if let container { actual = container }
        else {
            let storage = NSTextStorage(), manager = NotesBodyLayoutManager()
            actual = NSTextContainer(size:NSSize(width:max(100,frameRect.width),height:.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(actual)
            ownedStorage = storage
        }
        super.init(frame: frameRect, textContainer: actual)
        isRichText = true; importsGraphics = false; allowsUndo = false
        isEditable = true; isSelectable = true; drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = true; isAutomaticDashSubstitutionEnabled = true
        isAutomaticLinkDetectionEnabled = true
        linkTextAttributes = [.foregroundColor: NSColor(NotesTheme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
        selectedTextAttributes = [.backgroundColor: NotesBodyLayoutManager.selectionColor]
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
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            linkPastes.cancelAll()
            showDropTarget(false)
            contextTools.detach()
        }
        super.viewWillMove(toWindow: newWindow)
    }
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
        linkPastes.cancelAll()
        loading = true
        imageEntrance?.invalidate()
        let selection = selectedRange()
        refreshVisibleImages(note)
        if let storage = textStorage {
            var reusableBlocks: [String: NoteBlock] = [:]
            storage.setAttributedString(NotesContinuousDocument.render(note, scale: readingScale, width: max(150, bounds.width),
                reusable: { reusableBlocks[$0.id.uuidString] = $0 }, image: { self.visibleImages[$0.id] }))
            bodyEncodingCache.seed(from: storage, scale: readingScale, blocks: reusableBlocks)
        }
        updateCompletedTaskAppearance()
        let length = textStorage?.length ?? 0
        setSelectedRange(NSRange(location:min(selection.location,length), length:min(selection.length,max(0,length - min(selection.location,length)))))
        trailingAttributes = defaultAttributes()
        if let last = note.blocks.last, last.text.isEmpty, last.kind == .paragraph {
            trailingAttributes[.notesBlock] = last.id.uuidString
            trailingAttributes[.notesHeading] = last.markdown?.hasPrefix("# ") == true ? 1 : last.markdown?.hasPrefix("## ") == true ? 2 : 0
        }
        if length == 0 || selection.location >= length && note.blocks.last?.text.isEmpty == true { typingAttributes = trailingAttributes }
        cleanTypingAttributes()
        loading = false
        onLayout?()
        animateNewImages()
        contextTools.selectionChanged()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(renderedWidth - newSize.width) > 1 {
            renderedWidth = newSize.width
            if let storage = textStorage, let layout = layoutManager, !hasMarkedText() {
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    if let cell = (value as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell,
                       cell.updateWidth(max(1, newSize.width)) {
                        layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                    }
                }
            }
            onLayout?()
            contextTools.selectionChanged()
        }
    }
    private func attributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, storage.length > 0, location < storage.length else { return typingAttributes }
        return storage.attributes(at:max(0,location), effectiveRange:nil)
    }
    func cleanTypingAttributes() {
        var attrs = typingAttributes
        for key in [.attachment, .notesMarker, .notesAttachment, .notesAttachmentName, .notesImageWide, .notesImageCaption, .notesPendingLink] as [NSAttributedString.Key] { attrs.removeValue(forKey:key) }
        let caret = selectedRange()
        var insideLink: URL?
        if caret.length == 0, caret.location > 0, let storage = textStorage, caret.location < storage.length {
            let left = NotesWebLink.destination(from: storage.attribute(.link, at: caret.location - 1, effectiveRange: nil))
            let right = NotesWebLink.destination(from: storage.attribute(.link, at: caret.location, effectiveRange: nil))
            if left == right { insideLink = right }
        } else if caret.length > 0, let storage = textStorage, NSMaxRange(caret) <= storage.length,
                  let target = NotesWebLink.destination(from: storage.attribute(.link, at: caret.location, effectiveRange: nil)) {
            var shared = true
            storage.enumerateAttribute(.link, in: caret) { value, _, _ in
                if NotesWebLink.destination(from: value) != target { shared = false }
            }
            if shared { insideLink = target }
        }
        if let insideLink { attrs[.link] = insideLink; attrs[.toolTip] = insideLink.absoluteString }
        else { attrs.removeValue(forKey: .link); attrs.removeValue(forKey: .toolTip) }
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
            let typing = typingAttributes
            storage.beginEditing()
            let paragraph = normalizeTypingInsertion(in: storage)
            let selection = paragraph == nil ? NotesListEditing.normalize(storage, selection: selectedRange()) : selectedRange()
            NotesContinuousDocument.normalizeLayout(storage, scale: readingScale, paragraph: paragraph)
            storage.endEditing()
            updateCompletedTaskAppearance(in: paragraph)
            setSelectedRange(selection); typingAttributes = typing; cleanTypingAttributes()
            normalizing = false
        }
        super.didChangeText()
        if !loading, !hasMarkedText() {
            publicationRevision &+= 1
            publishChange(); onLayout?(); contextTools.selectionChanged()
        }
    }
    private func normalizeTypingInsertion(in storage: NSTextStorage) -> NSRange? {
        guard let insertion = typingInsertion, NSMaxRange(insertion) <= storage.length,
              selectedRange() == NSRange(location: NSMaxRange(insertion), length: 0) else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: insertion)
        guard paragraph.location < insertion.location, NSMaxRange(insertion) <= NSMaxRange(paragraph) else { return nil }
        let attrs = storage.attributes(at: insertion.location - 1, effectiveRange: nil)
        guard attrs[.notesMarker] as? Bool != true, attrs[.attachment] == nil else { return nil }
        // Inserting within an existing text run leaves markers and numbering
        // intact. Only the inserted character needs the paragraph metadata.
        for key in [.notesBlock, .notesKind, .notesChecked, .notesHeading, .notesListLevel,
                    .notesListNumber, .notesListStart, .notesListStartLevel] as [NSAttributedString.Key] {
            storage.updateNotesAttribute(key, value: attrs[key] as? NSObject, range: insertion)
        }
        return paragraph
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let publicationBeforeInsertion = publicationRevision
        cleanTypingAttributes()
        if !hasMarkedText(), let value = insertString as? String, value == " ", convertListShortcut(replacementRange: replacementRange) { return }
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
        if let text = insertString as? String, !hasMarkedText() {
            let insertion = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let adjacent = [insertion.location - 1, insertion.location, NSMaxRange(insertion) - 1]
            let touchesLink = adjacent.contains { index in
                guard let storage = textStorage, index >= 0, index < storage.length else { return false }
                return storage.attribute(.link, at: index, effectiveRange: nil) != nil
                    || storage.attribute(.notesPendingLink, at: index, effectiveRange: nil) != nil
            }
            if touchesLink {
                // Only link boundaries need explicit cleanup. Ordinary typing
                // keeps the existing single native edit/publish path.
                let attrs = typingAttributes
                super.insertText(NSAttributedString(string: text, attributes: attrs), replacementRange: replacementRange)
                let inserted = NSRange(location: insertion.location, length: text.utf16.count)
                if let storage = textStorage, NSMaxRange(inserted) <= storage.length,
                   (storage.string as NSString).substring(with: inserted) == text {
                    storage.setAttributes(attrs, range: inserted)
                    didChangeText()
                }
            } else {
                if insertion.length == 0, insertion.location > 0, text.utf16.count == 1,
                   text.rangeOfCharacter(from: .newlines) == nil {
                    typingInsertion = NSRange(location: insertion.location, length: 1)
                }
                defer { typingInsertion = nil }
                super.insertText(insertString, replacementRange: replacementRange)
            }
        } else { super.insertText(insertString, replacementRange:replacementRange) }
        if !hasMarkedText() {
            // The native edit usually publishes from didChangeText. An input
            // method can commit without that callback, so retain the fallback.
            if publicationRevision == publicationBeforeInsertion { publishChange(); onLayout?() }
            linkPastes.flushCompletedTitles(in: self)
        }
    }
    override func unmarkText() {
        super.unmarkText()
        if !loading {
            updateCompletedTaskAppearance()
            cleanTypingAttributes(); publishChange(); onLayout?()
        }
        linkPastes.flushCompletedTitles(in: self)
    }
    private func updateCompletedTaskAppearance(in paragraph: NSRange? = nil) {
        guard let storage = textStorage, let layout = layoutManager else { return }
        let muted = NSColor(NotesTheme.muted)
        let strike = NSNumber(value: NSUnderlineStyle.single.rawValue)
        // Draw completion separately from the RTF and clipboard styles.
        func update(_ key: NSAttributedString.Key, value: NSObject, enabled: Bool, in range: NSRange) {
            var cursor = range.location
            while cursor < NSMaxRange(range) {
                var run = NSRange()
                let current = layout.temporaryAttribute(key, atCharacterIndex: cursor, longestEffectiveRange: &run, in: range) as? NSObject
                if enabled && current != value {
                    layout.addTemporaryAttribute(key, value: value, forCharacterRange: run)
                } else if !enabled && current == value {
                    layout.removeTemporaryAttribute(key, forCharacterRange: run)
                }
                cursor = NSMaxRange(run)
            }
        }
        let text = storage.string as NSString
        let range = paragraph ?? NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            let completed = attributes[.notesKind] as? String == "checklist"
                && attributes[.notesChecked] as? Bool == true && attributes[.notesMarker] as? Bool != true
            var body = run
            if text.character(at: NSMaxRange(body) - 1) == 10 { body.length -= 1 }
            let hasManualStrike = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            update(.strikethroughStyle, value: strike, enabled: completed && !hasManualStrike, in: body)
            update(.foregroundColor, value: muted, enabled: completed && attributes[.link] == nil, in: body)
            if body.length != run.length {
                let separator = NSRange(location: NSMaxRange(body), length: 1)
                update(.strikethroughStyle, value: strike, enabled: false, in: separator)
                update(.foregroundColor, value: muted, enabled: false, in: separator)
            }
        }
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
    var selectionListKind: String? { paragraphRanges().map { attributes(at: $0.location)[.notesKind] as? String ?? "paragraph" }.uniqueValue }
    var selectionListLevel: Int? { paragraphRanges().map { attributes(at: $0.location)[.notesListLevel] as? Int ?? 0 }.uniqueValue }
    func toggleList(_ kind: String) {
        guard NotesListEditing.isList(kind), !hasMarkedText(), let storage = textStorage else { return }
        session?.captureBodySelection(selectedRange()); session?.endTypingGroup()
        let ranges = paragraphRanges()
        let remove = ranges.allSatisfy { attributes(at: $0.location)[.notesKind] as? String == kind }
        var selection = selectedRange(), finalTyping: [NSAttributedString.Key: Any]?
        for range in ranges.reversed() {
            var attrs = attributes(at: range.location)
            if let kind = attrs[.notesKind] as? String, kind == "image" || kind == "file" { continue }
            let oldMarker = NotesListEditing.markerRange(in: storage, paragraph: range)
            attrs[.notesKind] = remove ? "paragraph" : kind; attrs[.notesChecked] = false
            attrs[.notesBlock] = UUID().uuidString
            attrs[.notesListLevel] = remove ? 0 : min(1, max(0, attrs[.notesListLevel] as? Int ?? 0))
            attrs[.notesListNumber] = 1
            attrs[.notesListStart] = 1; attrs[.notesListStartLevel] = attrs[.notesListLevel]
            for key in [.notesMarker, .attachment, .notesAttachment, .notesAttachmentName] as [NSAttributedString.Key] { attrs.removeValue(forKey: key) }
            let marker = remove ? NSMutableAttributedString(string: "") : NSMutableAttributedString(attributedString: NotesListEditing.marker(kind: kind, font: attrs[.font] as? NSFont ?? headingFont(0)))
            var markerAttrs = attrs
            for key in [.link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { markerAttrs.removeValue(forKey: key) }
            marker.addAttributes(markerAttrs, range: NSRange(location: 0, length: marker.length))
            storage.replaceCharacters(in: oldMarker, with: marker)
            selection = NotesListEditing.map(selection, replacing: oldMarker, length: marker.length, moveStart: oldMarker.length == 0)
            let changed = NSRange(location: range.location, length: range.length - oldMarker.length + marker.length)
            let metadata: [NSAttributedString.Key: Any] = [.notesKind: attrs[.notesKind]!, .notesChecked: false, .notesBlock: attrs[.notesBlock]!, .notesListLevel: attrs[.notesListLevel]!, .notesListNumber: 1, .notesListStart: 1, .notesListStartLevel: attrs[.notesListLevel] ?? 0]
            if changed.length > 0 { storage.addAttributes(metadata, range: changed) }
            if NSMaxRange(changed) == storage.length { trailingAttributes = attrs }
            if range.location <= selection.location { finalTyping = attrs }
        }
        setSelectedRange(selection)
        if let finalTyping { typingAttributes = finalTyping }
        cleanTypingAttributes(); didChangeText(); session?.endTypingGroup(); window?.makeFirstResponder(self)
    }
    /// Space commits the shortcut as the same edit, before a transient literal
    /// prefix can enter the session history or trigger link-title work.
    private func convertListShortcut(replacementRange: NSRange) -> Bool {
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard selection.length == 0, let storage = textStorage, selection.location <= storage.length else { return false }
        let paragraph = (string as NSString).paragraphRange(for: selection)
        let attrs = attributes(at: paragraph.location)
        guard (attrs[.notesKind] as? String ?? "paragraph") == "paragraph", (attrs[.notesHeading] as? Int ?? 0) == 0 else { return false }
        let prefix = NSRange(location: paragraph.location, length: selection.location - paragraph.location)
        guard let list = NotesListEditing.shortcut((string as NSString).substring(with: prefix) + " ") else { return false }
        var next = attrs
        next[.notesKind] = list.kind; next[.notesListLevel] = list.level; next[.notesListNumber] = list.number
        next[.notesListStart] = list.number; next[.notesListStartLevel] = list.level
        next[.notesBlock] = UUID().uuidString; next[.notesChecked] = false
        for key in [.attachment, .notesMarker, .link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { next.removeValue(forKey: key) }
        let marker = NSMutableAttributedString(attributedString: NotesListEditing.marker(kind: list.kind, number: list.number, font: next[.font] as? NSFont ?? headingFont(0)))
        marker.addAttributes(next, range: NSRange(location: 0, length: marker.length))
        guard shouldChangeText(in: prefix, replacementString: marker.string) else { return false }
        session?.endTypingGroup()
        storage.replaceCharacters(in: prefix, with: marker)
        let updated = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        storage.addAttributes([.notesKind: list.kind, .notesListLevel: list.level, .notesListNumber: list.number, .notesListStart: list.number, .notesListStartLevel: list.level, .notesBlock: next[.notesBlock]!, .notesChecked: false], range: updated)
        setSelectedRange(NSRange(location: paragraph.location + marker.length, length: 0)); typingAttributes = next
        if NSMaxRange(updated) == storage.length { trailingAttributes = next }
        didChangeText(); session?.endTypingGroup(); return true
    }
    func changeListIndent(_ delta: Int) {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let ranges = paragraphRanges().filter { NotesListEditing.isList(attributes(at: $0.location)[.notesKind] as? String) }
        guard !ranges.isEmpty else { return }
        session?.captureBodySelection(selectedRange()); session?.endTypingGroup()
        let selection = selectedRange()
        for range in ranges {
            let old = attributes(at: range.location)[.notesListLevel] as? Int ?? 0
            let level = min(1, max(0, old + delta))
            guard level != old else { continue }
            if range.length > 0 { storage.addAttributes([.notesListLevel: level, .notesListNumber: 1, .notesListStart: 1, .notesListStartLevel: level], range: range) }
            if NSMaxRange(range) == storage.length { trailingAttributes[.notesListLevel] = level }
        }
        setSelectedRange(selection)
        var typing = typingAttributes
        typing[.notesListLevel] = attributes(at: selection.location)[.notesListLevel] as? Int ?? 0
        typingAttributes = typing
        didChangeText(); session?.endTypingGroup()
    }
    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), paragraphRanges().contains(where: { NotesListEditing.isList(attributes(at: $0.location)[.notesKind] as? String) }) { changeListIndent(1) }
        else { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), paragraphRanges().contains(where: { NotesListEditing.isList(attributes(at: $0.location)[.notesKind] as? String) }) { changeListIndent(-1) }
        else { super.insertBacktab(sender) }
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { super.insertNewline(sender); return }
        var selection = selectedRange()
        guard let range = paragraphRanges().first else { return }
        var attrs = attributes(at: range.location)
        let kind = attrs[.notesKind] as? String ?? "paragraph", list = NotesListEditing.isList(kind)
        let marker = NotesListEditing.markerRange(in: storage, paragraph: range)
        let bodyEnd = NSMaxRange(range) - ((string as NSString).substring(with: range).hasSuffix("\n") ? 1 : 0)
        if list, bodyEnd <= NSMaxRange(marker) {
            if (attrs[.notesListLevel] as? Int ?? 0) > 0 { changeListIndent(-1) }
            else { toggleList(kind) }
            return
        }
        if list, selection.length == 0, selection.location < NSMaxRange(marker) { selection.location = NSMaxRange(marker) }
        attrs[.notesBlock] = UUID().uuidString; attrs[.notesChecked] = false
        for key in [.attachment, .notesMarker, .link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { attrs.removeValue(forKey: key) }
        if kind == "image" || kind == "file" || (attrs[.notesHeading] as? Int ?? 0) > 0 && selection.location >= bodyEnd { attrs = defaultAttributes() }
        var newlineAttrs = attributes(at: max(range.location, selection.location - 1))
        for key in [.notesMarker, .attachment, .link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { newlineAttrs.removeValue(forKey: key) }
        let next = NSMutableAttributedString(string: "\n", attributes: newlineAttrs)
        if list {
            let marker = NSMutableAttributedString(attributedString: NotesListEditing.marker(kind: kind, number: attrs[.notesListNumber] as? Int ?? 1, font: attrs[.font] as? NSFont ?? headingFont(0)))
            marker.addAttributes(attrs, range: NSRange(location: 0, length: marker.length)); next.append(marker)
        }
        guard shouldChangeText(in: selection, replacementString: next.string) else { return }
        storage.replaceCharacters(in: selection, with: next)
        let caret = selection.location + next.length
        if caret < storage.length {
            let tail = (storage.string as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
            storage.addAttributes([.notesKind: attrs[.notesKind] ?? "paragraph", .notesBlock: attrs[.notesBlock]!, .notesChecked: false, .notesHeading: attrs[.notesHeading] ?? 0, .notesListLevel: attrs[.notesListLevel] ?? 0, .notesListNumber: attrs[.notesListNumber] ?? 1], range: tail)
        }
        if caret == storage.length { trailingAttributes = attrs }
        setSelectedRange(NSRange(location: caret, length: 0)); typingAttributes = attrs
        didChangeText(); scrollRangeToVisible(selectedRange())
    }
    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0, let range = paragraphRanges().first, let storage = textStorage else { super.deleteBackward(sender); return }
        let attrs = attributes(at: range.location), kind = attrs[.notesKind] as? String
        if NotesListEditing.isList(kind), selectedRange().location <= NSMaxRange(NotesListEditing.markerRange(in: storage, paragraph: range)) {
            if (attrs[.notesListLevel] as? Int ?? 0) > 0 { changeListIndent(-1) }
            else { toggleList(kind!) }
            return
        }
        super.deleteBackward(sender)
    }
    private func paragraphDelimited(_ fragment: NSAttributedString, at selection: NSRange) -> NSAttributedString {
        guard fragment.length > 0 else { return fragment }
        var structural = false
        fragment.enumerateAttribute(.notesKind, in: NSRange(location: 0, length: fragment.length)) { value, _, _ in
            let kind = value as? String
            if NotesListEditing.isList(kind) || kind == "image" || kind == "file" { structural = true }
        }
        guard structural else { return fragment }
        let result = NSMutableAttributedString(attributedString: fragment), original = string as NSString
        func separator(_ source: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attrs = source
            for key in [.attachment, .notesMarker, .notesAttachment, .notesAttachmentName, .link, .toolTip, .notesPendingLink] as [NSAttributedString.Key] { attrs.removeValue(forKey: key) }
            return NSAttributedString(string: "\n", attributes: attrs)
        }
        if selection.location > 0, original.character(at: selection.location - 1) != 10, !fragment.string.hasPrefix("\n") {
            result.insert(separator(attributes(at: selection.location - 1)), at: 0)
        }
        if NSMaxRange(selection) < original.length, original.character(at: NSMaxRange(selection)) != 10, !fragment.string.hasSuffix("\n") {
            result.append(separator(fragment.attributes(at: fragment.length - 1, effectiveRange: nil)))
        }
        return result
    }
    @discardableResult func insertPasted(_ value: NSAttributedString) -> Bool {
        cleanTypingAttributes()
        let target = typingAttributes
        let targetFont = target[.font] as? NSFont ?? headingFont(0)
        let safe = NSMutableAttributedString(attributedString:value)
        NotesContinuousDocument.sanitizeLinks(in: safe)
        let source = NSAttributedString(attributedString:safe)
        source.enumerateAttributes(in:NSRange(location:0,length:source.length)) { attrs,range,_ in
            for key in [.notesBlock,.notesKind,.notesHeading,.notesChecked,.notesMarker,.notesAttachment,.notesAttachmentName,.notesListLevel,.notesListNumber,.notesListStart,.notesListStartLevel] as [NSAttributedString.Key] { safe.removeAttribute(key,range:range) }
            let original = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize:NotesContinuousDocument.bodySize)
            let font = preservePastedFormatting ? NSFontManager.shared.convert(original, toSize: original.pointSize * readingScale) : targetFont
            safe.addAttributes([.font:font,.foregroundColor:target[.foregroundColor] ?? NSColor(NotesTheme.text)],range:range)
            if !preservePastedFormatting {
                for key in [.backgroundColor, .shadow, .strokeColor, .strokeWidth, .baselineOffset, .underlineStyle, .strikethroughStyle] as [NSAttributedString.Key] {
                    safe.removeAttribute(key, range: range)
                    if let value = target[key], key == .underlineStyle || key == .strikethroughStyle { safe.addAttribute(key, value: value, range: range) }
                }
            }
        }
        let ns = source.string as NSString
        var paragraphs:[NSRange] = [], cursor = 0
        while cursor < ns.length { let range = ns.paragraphRange(for:NSRange(location:cursor,length:0)); paragraphs.append(range); cursor = NSMaxRange(range) }
        for range in paragraphs.reversed() {
            let style = source.attribute(.paragraphStyle,at:range.location,effectiveRange:nil) as? NSParagraphStyle
            let heading = min(2,max(0,style?.headerLevel ?? 0))
            let text = ns.substring(with:range)
            let textList = style?.textLists.last
            let trimmed = text.hasPrefix("\t") ? String(text.dropFirst()) : text
            let literalOrdered = NotesListEditing.orderedPrefix(trimmed)
            let literalBullet = text.hasPrefix("• ") || text.hasPrefix("•\t") || text.hasPrefix("\t•\t")
            let listKind: String? = textList.map { $0.markerFormat == .decimal ? "ordered" : "bullet" } ?? (literalOrdered != nil ? "ordered" : literalBullet ? "bullet" : nil)
            let sourceFont = source.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let level = textList != nil ? min(1, max(0, (style?.textLists.count ?? 0) - 1)) : ((style?.firstLineHeadIndent ?? 0) >= (sourceFont?.pointSize ?? 15) ? 1 : 0)
            let ordered = listKind == "ordered" ? literalOrdered : nil
            let number = ordered?.number ?? textList?.startingItemNumber ?? 1
            let attrs:[NSAttributedString.Key:Any] = [.notesBlock:UUID().uuidString,.notesKind:listKind ?? "paragraph",.notesHeading:heading,.notesChecked:false,.notesListLevel:level,.notesListNumber:number]
            safe.addAttributes(attrs,range:range)
            if let listKind {
                let prefix = listKind == "ordered" ? (ordered?.length ?? 0) + (ordered != nil && text.hasPrefix("\t") ? 1 : 0) : text.hasPrefix("\t•\t") ? 3 : text.hasPrefix("• ") || text.hasPrefix("•\t") ? 2 : 0
                if prefix > 0 { safe.deleteCharacters(in:NSRange(location:range.location,length:prefix)) }
                let marker = NSMutableAttributedString(attributedString: NotesListEditing.marker(kind:listKind,number:number,font:headingFont(0)))
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
        let fragment = paragraphDelimited(safe, at: selection)
        textStorage?.replaceCharacters(in:selection,with:fragment)
        setSelectedRange(NSRange(location:selection.location + fragment.length,length:0))
        cleanTypingAttributes(); didChangeText()
        return true
    }
    /// Native RTFD drops our display-only attachment cells. The private flavor
    /// carries a self-contained, validated value; it never grants access to a path.
    static let ownedSelectionType = NSPasteboard.PasteboardType("local.shipian.owned-selection.v1")
    private struct ClipboardStyle: Codable {
        var location: Int; var length: Int; var size: Double; var fontName: String
        var bold: Bool; var italic: Bool; var underline: Int; var strike: Int
        var link: String?
    }
    private struct ClipboardBlock: Codable {
        var kind: NoteBlock.Kind; var text: String; var heading: Int; var bullet: Bool
        var checked: Bool; var attachment: UUID?; var styles: [ClipboardStyle]
        var listKind: String? = nil; var listLevel: Int? = nil; var listNumber: Int? = nil
        var imageWide: Bool? = nil; var imageCaption: String? = nil
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
                    styles.append(ClipboardStyle(location: range.location, length: range.length, size: Double(font.pointSize), fontName: font.fontName, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask), underline: attrs[.underlineStyle] as? Int ?? 0, strike: attrs[.strikethroughStyle] as? Int ?? 0, link: NotesWebLink.destination(from: attrs[.link])?.absoluteString))
                }
            }
            let list = NotesListEditing.descriptor(block)
            return ClipboardBlock(kind: block.kind, text: block.text, heading: block.markdown?.hasPrefix("# ") == true ? 1 : block.markdown?.hasPrefix("## ") == true ? 2 : 0, bullet: list?.kind == "bullet", checked: block.isChecked, attachment: block.attachmentID, styles: styles, listKind: list?.kind, listLevel: list?.level, listNumber: list?.number, imageWide: block.imageWide, imageCaption: block.imageCaption)
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
            NotesContinuousDocument.sanitizeLinks(in: selected)
            selected.removeAttribute(.notesPendingLink, range: NSRange(location: 0, length: selected.length))
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
            if payload.blocks.count == 1, let block = payload.blocks.first, block.kind == .image,
               let id = block.attachment, let asset = payload.assets.first(where: { $0.id == id }) {
                _ = NotesEditorPasteboard.writeImage(asset.bytes, to: board)
            }
            _ = board.setString(payload.blocks.map { block in
                let indent = (block.listLevel ?? 0) > 0 ? "  " : ""
                if block.kind == .checklist { return indent + "\(block.checked ? "☑" : "☐") \(block.text)" }
                if block.listKind == "ordered" { return indent + "\(block.listNumber ?? 1). " + block.text }
                return indent + block.text
            }.joined(separator: "\n"), forType: .string)
            return true
        } catch { session?.reportAttachmentFailure("复制未完成：" + error.localizedDescription); return false }
    }
    override func copy(_ sender: Any?) { _ = writeSelection(to: clipboard, types: writablePasteboardTypes) }
    override func cut(_ sender: Any?) { _ = cut(to: clipboard) }
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
            guard (0...2).contains(block.heading), block.text.utf16.count <= Self.clipboardLimit,
                  block.listLevel == nil || (0...1).contains(block.listLevel!),
                  block.listNumber == nil || block.listNumber! > 0 && block.listNumber! < Int.max,
                  block.listKind == nil || NotesListEditing.isList(block.listKind) else { throw ClipboardError.invalid }
            if let kind = block.listKind {
                guard block.kind == .paragraph || block.kind == .checklist,
                      (kind == "checklist") == (block.kind == .checklist) else { throw ClipboardError.invalid }
            }
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
            cleanTypingAttributes()
            let target = typingAttributes
            let targetFont = target[.font] as? NSFont ?? headingFont(0)
            let unscaledTarget = NSFontManager.shared.convert(targetFont, toSize: targetFont.pointSize / readingScale)
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
                if let assetID = value.attachment, let attachment = replacements[assetID] { return NoteBlock(kind: value.kind, text: attachment.name, attachmentID: attachment.id, imageWide: value.imageWide, imageCaption: value.imageCaption.map { String($0.prefix(180)) }) }
                let rich = NSMutableAttributedString(string: value.text, attributes: [.font: preservePastedFormatting ? NSFont.systemFont(ofSize: NotesContinuousDocument.bodySize * (value.heading == 1 ? 1.65 : value.heading == 2 ? 1.28 : 1)) : unscaledTarget])
                for style in value.styles {
                    let size = preservePastedFormatting ? style.size : unscaledTarget.pointSize
                    var font = preservePastedFormatting ? (NSFont(name: style.fontName, size: size) ?? NSFont.systemFont(ofSize: size)) : unscaledTarget
                    if preservePastedFormatting && style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if preservePastedFormatting && style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    let range = NSRange(location: style.location, length: style.length)
                    rich.addAttributes([.font: font, .underlineStyle: preservePastedFormatting ? style.underline : (target[.underlineStyle] as? Int ?? 0), .strikethroughStyle: preservePastedFormatting ? style.strike : (target[.strikethroughStyle] as? Int ?? 0)], range: range)
                    if let url = NotesWebLink.destination(from: style.link) { rich.addAttribute(.link, value: url, range: range) }
                    else { rich.removeAttribute(.link, range: range) }
                }
                let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                var markdown = value.heading == 1 ? "# " + value.text : value.heading == 2 ? "## " + value.text : value.text
                if let kind = value.listKind ?? (value.bullet ? "bullet" : nil), kind != "checklist" || (value.listLevel ?? 0) > 0 {
                    let body = kind == "bullet" && value.text.hasPrefix("• ") ? String(value.text.dropFirst(2)) : value.text
                    markdown = NotesListEditing.markdownPrefix(.init(kind: kind, level: value.listLevel ?? 0, number: value.listNumber ?? 1), checked: value.checked) + body
                }
                return NoteBlock(kind: value.kind, text: value.text, richText: rtf, markdown: markdown, isChecked: value.checked)
            }
            let fragment = paragraphDelimited(NotesContinuousDocument.render(NoteDocument(blocks: blocks, attachments: additions), scale: readingScale, width: max(150, bounds.width), image: { attachment in (try? session.localURL(for: attachment)).flatMap(NSImage.init(contentsOf:)) }), at: selection)
            original.replaceCharacters(in: selection, with: fragment)
            let pastedSelection = NotesListEditing.normalize(original, selection: NSRange(location: selection.location + fragment.length, length: 0))
            let result = try NotesContinuousDocument.blocks(from: original, scale: readingScale, trailingAttributes: trailingAttributes)
            session.change("粘贴闪念内容") { note in
                let references = Set(result.compactMap(\.attachmentID))
                note.blocks = result; note.attachments.removeAll { !references.contains($0.id) }
            }
            loadDocument(session.note)
            setSelectedRange(NSRange(location: min(pastedSelection.location, string.utf16.count), length: 0)); cleanTypingAttributes(); onLayout?()
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
    override func paste(_ sender: Any?) { _ = readSelection(from: clipboard) }
    private func handleControlClipboard(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]) == .control else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        default: return false
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleControlClipboard(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        contextTools.hide()
        if !handleControlClipboard(event) { super.keyDown(with: event) }
    }
    /// The native destination owns the insertion point, so dragging from the
    /// rope copies into the place under the pointer rather than a stale caret.
    @discardableResult func importDroppedContent(from board: NSPasteboard, at point: NSPoint) -> Bool {
        guard !hasMarkedText() else { return false }
        let entries = NotesEditorPasteboard.imports(from: board)
        guard !entries.isEmpty, let session else { return false }
        let location = min(string.utf16.count, characterIndexForInsertion(at: point))
        setSelectedRange(NSRange(location: location, length: 0))
        window?.makeFirstResponder(self)
        session.importItems(entries)
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || sender.draggingPasteboard.types?.contains(where: { $0 == .png || $0 == .tiff }) == true {
            guard !hasMarkedText() else { return [] }
            showDropTarget(true)
            contextTools.hide()
            updateDropCaret(sender)
            return .copy
        }
        showDropTarget(false)
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropTargeted else { return super.draggingUpdated(sender) }
        updateDropCaret(sender)
        return .copy
    }
    private func updateDropCaret(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let index = min(string.utf16.count, characterIndexForInsertion(at: point))
        guard let window else { return }
        let screen = firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
        let rect = convert(window.convertFromScreen(screen), from: nil)
        setDropCaret(rect.isEmpty && rect.height == 0 ? nil : NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
    }
    private func setDropCaret(_ rect: NSRect?) {
        guard dropCaret != rect else { return }
        if let old = dropCaret { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        dropCaret = rect
        if let rect { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropCaret(nil)
        showDropTarget(false); super.draggingExited(sender)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropCaret(nil)
        showDropTarget(false); super.concludeDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropCaret(nil); showDropTarget(false) }
        if importDroppedContent(from: sender.draggingPasteboard, at: convert(sender.draggingLocation, from: nil)) { return true }
        return super.performDragOperation(sender)
    }
    private func paste(from board: NSPasteboard) -> Bool {
        var rich: NSAttributedString?
        if let data = board.data(forType:.rtfd) { rich = NSAttributedString(rtfd:data,documentAttributes:nil) }
        if let rich {
            var hasOwnedImage = false
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let wrapper = (value as? NSTextAttachment)?.fileWrapper, wrapper.isRegularFile { hasOwnedImage = true }
            }
            if hasOwnedImage { return insertPasted(rich) }
        }
        let entries = NotesEditorPasteboard.imports(from: board)
        if !entries.isEmpty, let session { session.importItems(entries); return true }
        if rich == nil, let data = board.data(forType:.rtf) { rich = NSAttributedString(rtf:data,documentAttributes:nil) }
        if rich == nil, let data = board.data(forType:.html) { rich = NSAttributedString(html:data,documentAttributes:nil) }
        if let rich, rich.length > 0 {
            var hasLink = false
            let address = NotesWebLink.url(from: rich.string)
            var matchesAddress = address != nil
            rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
                if let value {
                    hasLink = true
                    if NotesWebLink.destination(from: value) != address { matchesAddress = false }
                }
            }
            if hasLink {
                if matchesAddress, let address { return linkPastes.paste(address, into: self) }
                return insertPasted(rich)
            }
        }
        let text = board.string(forType: .string) ?? board.string(forType: .URL)
        if let text, let url = NotesWebLink.url(from: text) { return linkPastes.paste(url, into: self) }
        if let rich, rich.length > 0 { return insertPasted(rich) }
        if let text { insertText(text,replacementRange:selectedRange()); return true }
        if let image = NSImage(pasteboard:board) { session?.pasteImage(image); return true }
        return false
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let dropCaret {
            NSColor(NotesTheme.accent).setFill()
            NSBezierPath(roundedRect: dropCaret, xRadius: 1, yRadius: 1).fill()
        }
        guard string.isEmpty, !hasMarkedText() else { return }
        let hint = "写下一点想法，或粘贴、拖入图片…"
        hint.draw(in: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y,
                             width: max(0, bounds.width - textContainerOrigin.x), height: 52 * readingScale),
                  withAttributes: [.font: NSFont.systemFont(ofSize: NotesContinuousDocument.bodySize * readingScale),
                                   .foregroundColor: NSColor.placeholderTextColor])
    }
    override func interactionHint(at point: NSPoint) -> String? {
        if let location = character(at: point) {
            let attrs = attributes(at: location)
            if attrs[.notesMarker] as? Bool == true, attrs[.notesKind] as? String == "checklist" { return "点击切换完成状态" }
            if let id = (attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)),
               let attachment = session?.note.attachments.first(where: { $0.id == id }) {
                return attachment.kind == .image ? "点按查看大图 · 右键复制或导出" : "点按打开附件 · 右键查看更多操作"
            }
        }
        return super.interactionHint(at: point)
    }
    override func interactionCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> NSCursor {
        if contextTools.hasButton(at: point) { return .pointingHand }
        if let location = character(at: point) {
            let attrs = attributes(at: location)
            if attrs[.notesMarker] as? Bool == true, attrs[.notesKind] as? String == "checklist" { return .pointingHand }
            if let id = (attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)),
               session?.note.attachments.contains(where: { $0.id == id }) == true { return .pointingHand }
        }
        return super.interactionCursor(at: point, modifiers: modifiers)
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard contextTools.enabled, session?.note.attachments.isEmpty == false else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = character(at: point)
        let id = index.flatMap { (attributes(at: $0)[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)) }
        let attachment = session?.note.attachments.first { $0.id == id }
        contextTools.mouseMoved(to: point, attachment: attachment, at: index)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !visibleRect.contains(convert(event.locationInWindow, from: nil)) { contextTools.hide() }
    }

    override func scrollWheel(with event: NSEvent) {
        contextTools.hide()
        super.scrollWheel(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { contextTools.selectionChanged() }
        return result
    }

    func applyContextLink(_ url: URL?, to range: NSRange) {
        guard !hasMarkedText(), let storage = textStorage, range.length > 0,
              NSMaxRange(range) <= storage.length else { return }
        setSelectedRange(range)
        guard let url else { removeLink(in: range); return }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        session?.captureBodySelection(range)
        session?.endTypingGroup()
        storage.removeAttribute(.notesPendingLink, range: range)
        storage.addAttributes([.link: url, .toolTip: url.absoluteString], range: range)
        didChangeText()
        session?.endTypingGroup()
    }

    private func animateNewImages() {
        guard let session, !session.pendingImageInsertions.isEmpty, let storage = textStorage,
              let layout = layoutManager, let container = textContainer else { return }
        let retained = Set(session.note.attachments.map(\.id))
        session.pendingImageInsertions.formIntersection(retained)
        if NotesMotion.reduced {
            session.pendingImageInsertions.removeAll()
            return
        }
        var cells: [NotesDocumentAttachmentCell] = []
        var dirty = NSRect.null
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell,
                  cell.previewImage != nil,
                  let id = (storage.attribute(.notesAttachment, at: range.location, effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:)),
                  session.pendingImageInsertions.remove(id) != nil else { return }
            let glyph = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            guard visibleRect.intersects(rect) else { return }
            cell.entranceProgress = 0
            cells.append(cell)
            dirty = dirty.union(rect)
        }
        guard !cells.isEmpty else { return }
        let animatedCells = cells
        let dirtyRect = dirty
        let start = ProcessInfo.processInfo.systemUptime
        imageEntrance = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let progress = NotesMotion.reduced || self?.window == nil
                    ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.18)
                for cell in animatedCells { cell.entranceProgress = CGFloat(1 - pow(1 - progress, 2)) }
                self?.setNeedsDisplay(dirtyRect)
                if progress == 1 { timer.invalidate(); self?.imageEntrance = nil }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        contextTools.trackingSelection = true
        contextTools.hide()
        defer { contextTools.trackingSelection = false; contextTools.selectionChanged() }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        if let location = character(at:event) {
            let attrs = attributes(at:location)
            if attrs[.notesMarker] as? Bool == true, attrs[.notesKind] as? String == "checklist", let storage = textStorage {
                let range = (string as NSString).paragraphRange(for:NSRange(location:location,length:0))
                session?.captureBodySelection(selectedRange())
                session?.endTypingGroup(); storage.addAttribute(.notesChecked,value:!(attrs[.notesChecked] as? Bool ?? false),range:range); didChangeText(); session?.endTypingGroup(); return
            }
            if let id = (attrs[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)), let attachment = session?.note.attachments.first(where:{$0.id == id}) {
                setSelectedRange(NSRange(location: location, length: 1))
                onAttachment?(attachment); return
            }
        }
        super.mouseDown(with:event)
    }
    private func character(at event:NSEvent) -> Int? { character(at: convert(event.locationInWindow, from: nil)) }
    private func character(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else { return nil }
        let local = NSPoint(x:point.x - textContainerOrigin.x,y:point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for:local,in:textContainer,fractionOfDistanceBetweenInsertionPoints:nil)
        guard index < textStorage!.length else { return nil }
        let glyph = layoutManager.glyphRange(forCharacterRange:NSRange(location:index,length:1),actualCharacterRange:nil)
        return layoutManager.boundingRect(forGlyphRange:glyph,in:textContainer).contains(local) ? index : nil
    }
    override func rightMouseDown(with event: NSEvent) {
        if let location = character(at:event), let id = (attributes(at:location)[.notesAttachment] as? String).flatMap(UUID.init(uuidString:)), let attachment = session?.note.attachments.first(where:{$0.id == id}), let session {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(attachment.kind == .image ? "放大图片" : "打开附件") { [weak self] in self?.onAttachment?(attachment) }.notesSymbol(attachment.kind == .image ? "photo" : "arrow.up.forward.app"))
            if attachment.kind == .image { menu.addItem(ClosureMenuItem("复制图片") { session.copyAttachment(attachment) }.notesSymbol("doc.on.doc")) }
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

/// Keep the document's line spacing, but paint the selection around the text
/// baseline rather than filling the extra space in each TextKit line.
private final class NotesBodyLayoutManager: NSLayoutManager {
    static let selectionColor = NSColor(NotesTheme.adaptive(0xC8D7F3, 0x536E9E))
    private var drawingOrigin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawingOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let container = textContainers.first, let view = container.textView,
              !view.hasMarkedText(), charRange.length > 0,
              NSIntersectionRange(charRange, view.selectedRange()) == charRange,
              color == Self.selectionColor || color == .selectedTextBackgroundColor ||
                color == .unemphasizedSelectedTextBackgroundColor || color == .selectedContentBackgroundColor ||
                color == .unemphasizedSelectedContentBackgroundColor,
              let storage = textStorage, NSMaxRange(charRange) <= storage.length else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let rects = UnsafeBufferPointer(start: rectArray, count: rectCount).map { rect in
            let point = NSPoint(x: rect.midX - drawingOrigin.x, y: rect.midY - drawingOrigin.y)
            let index = glyphIndex(for: point, in: container)
            guard index < numberOfGlyphs else { return rect }
            var lineGlyphs = NSRange()
            let line = lineFragmentRect(forGlyphAt: index, effectiveRange: &lineGlyphs)
            let characters = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            guard NSIntersectionRange(charRange, characters).length > 0 else { return rect }
            var textMetrics: (font: NSFont, character: Int)?
            var includesImage = false
            storage.enumerateAttributes(in: characters) { attributes, run, stop in
                // The checklist's attachment is a marker on a text line.
                guard attributes[.notesMarker] as? Bool != true else { return }
                if attributes[.attachment] != nil { includesImage = true; stop.pointee = true; return }
                if let candidate = attributes[.font] as? NSFont, candidate.pointSize > (textMetrics?.font.pointSize ?? 0) {
                    textMetrics = (candidate, run.location)
                }
            }
            guard let (font, character) = textMetrics, !includesImage else { return rect }
            let textGlyph = glyphIndexForCharacter(at: character)
            let baseline = drawingOrigin.y + line.minY + location(forGlyphAt: textGlyph).y
            let height = min(rect.height, ceil(font.ascender - font.descender) + 2)
            let center = baseline - (font.ascender + font.descender) / 2
            let y = min(max(center - height / 2, rect.minY), rect.maxY - height)
            return NSRect(x: rect.minX, y: y, width: rect.width, height: height)
        }
        rects.withUnsafeBufferPointer { rects in
            if let start = rects.baseAddress {
                super.fillBackgroundRectArray(start, count: rects.count, forCharacterRange: charRange, color: color)
            }
        }
    }
}
private extension Bool { var intValue:Int { self ? 1 : 0 } }
private extension Array where Element: Equatable { var uniqueValue:Element? { guard let first, allSatisfy({$0 == first}) else { return nil }; return first } }
