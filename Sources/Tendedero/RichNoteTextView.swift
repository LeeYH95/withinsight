import AppKit
import SwiftUI
import NotesCore

 enum NotesTextFormat { case bold, italic, underline, bullets }

@MainActor
class NotesTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) { NotesTextMenu.show(for: self, event: event, session: session) }
    weak var session: NotesEditorSession?
    var blockID: UUID?
    var checklist = false
    var publish: (() -> Void)?
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @discardableResult func activateLink(at index: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.intersection([.control, .option, .shift]).isEmpty,
              index >= 0, index < (textStorage?.length ?? 0),
              let url = NotesWebLink.destination(from: textStorage?.attribute(.link, at: index, effectiveRange: nil)) else { return false }
        openLink(url); return true
    }
    // Native text undo targets become stale when a block view is removed. The session
    // records document snapshots, so NSTextView must not register its own targets.
    override var undoManager: UndoManager? { nil }
    @objc func undo(_ sender: Any?) { session?.undo() }
    @objc func redo(_ sender: Any?) { session?.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return session?.undoManager.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return session?.undoManager.canRedo == true }
        return super.validateMenuItem(menuItem)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { session?.textView = self; session?.focusedBlock = blockID }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z":
                if !hasMarkedText() { if event.modifierFlags.contains(.shift) { session?.redo() } else { session?.undo() }; return }
            case "b": format(.bold); return
            case "i": format(.italic); return
            case "u": format(.underline); return
            default: break
            }
        }
        if !hasMarkedText(), checklist, event.keyCode == 36 {
            if let blockID { session?.addBlock(.checklist, after: blockID) }
            return
        }
        if !hasMarkedText(), checklist, event.keyCode == 51, string.isEmpty, let blockID {
            session?.removeEmptyBlock(blockID); return
        }
        super.keyDown(with: event)
    }
    func publishChange() { publish?() }
    func format(_ action: NotesTextFormat) {
        guard !hasMarkedText() else { return }
        session?.endTypingGroup()
        let range = selectedRange()
        if action == .bullets {
            guard let storage = textStorage else { return }
            let ns = string as NSString
            let paragraphRange = ns.paragraphRange(for: range)
            guard shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
            var paragraphs: [NSRange] = []
            var cursor = paragraphRange.location
            let limit = NSMaxRange(paragraphRange)
            repeat {
                let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
                paragraphs.append(paragraph)
                let next = NSMaxRange(paragraph)
                if next <= cursor || next >= limit { break }
                cursor = next
            } while cursor < limit
            let remove = paragraphs.allSatisfy { $0.length >= 2 && ns.substring(with: NSRange(location: $0.location, length: 2)) == "• " }
            let changed = NSMutableAttributedString(attributedString: storage)
            for paragraph in paragraphs.reversed() {
                if remove { changed.deleteCharacters(in: NSRange(location: paragraph.location, length: 2)) }
                else {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    let existing = paragraph.location < storage.length ? storage.attributes(at: paragraph.location, effectiveRange: nil) : typingAttributes
                    attributes[.paragraphStyle] = existing[.paragraphStyle]
                    attributes[.foregroundColor] = existing[.foregroundColor] ?? NSColor(NotesTheme.text)
                    // Paragraph markers carry no inline emphasis. Existing runs are untouched.
                    attributes[.font] = NSFont.systemFont(ofSize: (existing[.font] as? NSFont)?.pointSize ?? CGFloat(NotesTheme.fontSize))
                    attributes[.underlineStyle] = 0
                    changed.insert(NSAttributedString(string: "• ", attributes: attributes), at: paragraph.location)
                }
            }
            func mapped(_ position: Int) -> Int {
                var result = position
                for paragraph in paragraphs {
                    if remove {
                        if position >= paragraph.location + 2 { result -= 2 }
                        else if position > paragraph.location { result -= position - paragraph.location }
                    } else if position >= paragraph.location { result += 2 }
                }
                return max(0, min(result, changed.length))
            }
            storage.setAttributedString(changed)
            let start = mapped(range.location), end = mapped(NSMaxRange(range))
            setSelectedRange(NSRange(location: start, length: max(0, end - start)))
            didChangeText()
            return
        }
        guard range.length > 0 else {
            var attributes = typingAttributes
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: NotesTheme.fontSize)
            let manager = NSFontManager.shared
            switch action {
            case .bold: attributes[.font] = manager.convert(font, toHaveTrait: manager.traits(of: font).contains(.boldFontMask) ? .unboldFontMask : .boldFontMask)
            case .italic: attributes[.font] = manager.convert(font, toHaveTrait: manager.traits(of: font).contains(.italicFontMask) ? .unitalicFontMask : .italicFontMask)
            case .underline: attributes[.underlineStyle] = (attributes[.underlineStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
            case .bullets: break
            }
            typingAttributes = attributes; return
        }
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        let before = storage.attributedSubstring(from: range)
        let after = NSMutableAttributedString(attributedString: before)
        let manager = NSFontManager.shared
        let firstFont = before.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: NotesTheme.fontSize)
        let removeTrait: Bool
        switch action {
        case .bold: removeTrait = manager.traits(of: firstFont).contains(.boldFontMask)
        case .italic: removeTrait = manager.traits(of: firstFont).contains(.italicFontMask)
        case .underline: removeTrait = (before.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0) != 0
        case .bullets: removeTrait = false
        }
        before.enumerateAttributes(in: NSRange(location: 0, length: before.length)) { attrs, subrange, _ in
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: NotesTheme.fontSize)
            switch action {
            case .bold: after.addAttribute(.font, value: manager.convert(font, toHaveTrait: removeTrait ? .unboldFontMask : .boldFontMask), range: subrange)
            case .italic: after.addAttribute(.font, value: manager.convert(font, toHaveTrait: removeTrait ? .unitalicFontMask : .italicFontMask), range: subrange)
            case .underline: after.addAttribute(.underlineStyle, value: removeTrait ? 0 : NSUnderlineStyle.single.rawValue, range: subrange)
            case .bullets: break
            }
        }
        replaceFormatting(in: range, with: after, inverse: before)
    }
    private func replaceFormatting(in range: NSRange, with value: NSAttributedString, inverse: NSAttributedString) {
        textStorage?.replaceCharacters(in: range, with: value)
        setSelectedRange(range)
        didChangeText()
    }
    override func paste(_ sender: Any?) {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { session?.importURLs(urls); return }
        if let image = NSImage(pasteboard: NSPasteboard.general) { session?.pasteImage(image); return }
        super.paste(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { session?.importURLs(urls); return true }
        if let image = NSImage(pasteboard: sender.draggingPasteboard) { session?.pasteImage(image); return true }
        return super.performDragOperation(sender)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let start = convert(event.locationInWindow, from: nil)
        guard event.modifierFlags.intersection([.option, .shift]).isEmpty,
              event.clickCount == 1, let window, let target = linkHit(at: start) else {
            super.mouseDown(with: event); return
        }
        defer { withExtendedLifetime(window) {} }
        if event.modifierFlags.contains(.command) {
            _ = activateLink(at: target.index, modifiers: event.modifierFlags); return
        }
        // Decide on release: a normal click opens, while a drag is returned to
        // NSTextView's own selection tracking with its first drag event intact.
        while let next = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            let point = convert(next.locationInWindow, from: nil)
            let distance = hypot(point.x - start.x, point.y - start.y)
            if next.type == .leftMouseDragged, next.windowNumber == event.windowNumber, distance < 4 { continue }
            if next.type == .leftMouseUp, next.windowNumber == event.windowNumber, distance < 4,
               let released = linkHit(at: point), released.url == target.url {
                _ = activateLink(at: released.index, modifiers: next.modifierFlags)
                return
            }
            NSApp.postEvent(next, atStart: true)
            super.mouseDown(with: event)
            return
        }
    }

    private var interactionTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let interactionTracking { removeTrackingArea(interactionTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); interactionTracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    /// NSTextView updates its I-beam during tracking, after cursor rectangles.
    /// Resolve from live glyphs so edits, wrapping and scrolling cannot leave stale hotspots.
    func interactionCursor(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> NSCursor {
        modifiers.intersection([.option, .shift, .control]).isEmpty && linkHit(at: point) != nil ? .pointingHand : .iBeam
    }
    private func updateInteractionCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return }
        interactionCursor(at: point, modifiers: event.modifierFlags).set()
        let hint = interactionHint(at: point)
        if toolTip != hint { toolTip = hint }
    }
    func interactionHint(at point: NSPoint) -> String? {
        guard let hit = linkHit(at: point) else { return nil }
        return String(hit.url.absoluteString.prefix(220)) + "\n点击打开 · Option 点击编辑文字"
    }
    func removeLink(in range: NSRange) {
        guard !hasMarkedText(), let storage = textStorage, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: nil) else { return }
        session?.captureBodySelection(selectedRange()); session?.endTypingGroup()
        storage.removeAttribute(.link, range: range)
        storage.removeAttribute(.toolTip, range: range)
        storage.removeAttribute(.notesPendingLink, range: range)
        toolTip = nil
        storage.addAttributes([.foregroundColor: NSColor(NotesTheme.text), .underlineStyle: 0], range: range)
        didChangeText(); session?.endTypingGroup()
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateInteractionCursor(event)
    }
    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updateInteractionCursor(event)
    }
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) { interactionCursor(at: point, modifiers: event.modifierFlags).set() }
    }
    override func didChangeText() {
        super.didChangeText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    func linkRange(containing index: Int, matching url: URL) -> NSRange? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard NotesWebLink.destination(from: storage.attribute(.link, at: index, effectiveRange: &range)) == url else { return nil }
        return range
    }
    func linkContext(at point: NSPoint) -> (range: NSRange, url: URL)? {
        guard let hit = linkHit(at: point), let storage = textStorage else { return nil }
        var range = NSRange()
        _ = storage.attribute(.link, at: hit.index, effectiveRange: &range)
        return (range, hit.url)
    }

    private func linkHit(at point: NSPoint) -> (index: Int, url: URL)? {
        guard bounds.contains(point), let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let url = NotesWebLink.destination(from: storage.attribute(.link, at: index, effectiveRange: nil)) else { return nil }
        return (index, url)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in
            guard NotesWebLink.destination(from: value) != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                let area = rect.offsetBy(dx: origin.x, dy: origin.y).intersection(self.visibleRect)
                if !area.isEmpty { self.addCursorRect(area, cursor: .pointingHand) }
            }
        }
    }
}

struct RichNoteTextView: NSViewRepresentable {
    let block: NoteBlock
    @ObservedObject var session: NotesEditorSession
    var fontSize: Double
    var onHeight: (CGFloat) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NotesTextView {
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
        view.delegate = context.coordinator
        view.session = session; view.blockID = block.id; view.checklist = block.kind == .checklist
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = false
        view.isEditable = true; view.isSelectable = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = true; view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel(block.kind == .checklist ? "待办内容" : "闪念正文")
        view.registerForDraggedTypes([.fileURL, .tiff, .png])
        view.publish = { [weak coordinator = context.coordinator] in coordinator?.publish() }
        context.coordinator.textView = view
        context.coordinator.load(block, into: view)
        return view
    }
    func updateNSView(_ view: NotesTextView, context: Context) {
        context.coordinator.parent = self
        if !view.hasMarkedText(), context.coordinator.lastBlock != block {
            context.coordinator.load(block, into: view)
        }
        // Text color follows the window appearance even when archived RTF came from light mode.
        if context.coordinator.lastFontSize != fontSize { context.coordinator.applyFontSize(fontSize, in: view) }
        view.textColor = NSColor(NotesTheme.text)
        view.insertionPointColor = NSColor(NotesTheme.accent)
        if session.focusedBlock == block.id, view.window?.firstResponder !== view, session.textView?.blockID != block.id {
            DispatchQueue.main.async { [weak view] in guard let view, view.window?.isKeyWindow == true else { return }; view.window?.makeFirstResponder(view) }
        }
        context.coordinator.measure()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NotesTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let used = nsView.layoutManager?.usedRect(for: nsView.textContainer!).height ?? 30
        return CGSize(width: width, height: max(fontSize * 1.7, used + 8))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteTextView
        weak var textView: NotesTextView?
        var lastBlock: NoteBlock?
        var loading = false
        var lastFontSize: Double = 0
        init(_ parent: RichNoteTextView) { self.parent = parent }
        func load(_ block: NoteBlock, into view: NotesTextView) {
            guard !view.hasMarkedText() else { return }
            loading = true
            let selection = view.selectedRange()
            if let data = block.richText, let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                view.textStorage?.setAttributedString(attributed)
            } else {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7
                view.textStorage?.setAttributedString(NSAttributedString(string: block.text, attributes: [.font: NSFont.systemFont(ofSize: parent.fontSize), .foregroundColor: NSColor(NotesTheme.text), .paragraphStyle: paragraph]))
            }
            view.typingAttributes = [.font: NSFont.systemFont(ofSize: parent.fontSize), .foregroundColor: NSColor(NotesTheme.text)]
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: min(selection.length, max(0, view.string.utf16.count - min(selection.location, view.string.utf16.count)))))
            applyFontSize(parent.fontSize, in: view)
            lastBlock = block; loading = false; measure()
        }
        func applyFontSize(_ size: Double, in view: NotesTextView) {
            guard let storage = view.textStorage, !view.hasMarkedText() else { return }
            let copy = NSAttributedString(attributedString: storage)
            storage.beginEditing()
            copy.enumerateAttribute(.font, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: size)
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: range)
            }
            storage.endEditing()
            view.typingAttributes[.font] = NSFont.systemFont(ofSize: size)
            lastFontSize = size
            measure()
        }
        func textDidChange(_ notification: Notification) { publish() }
        func textDidEndEditing(_ notification: Notification) { publish() }
        func textViewDidChangeSelection(_ notification: Notification) { parent.session.undoRevision += 1 }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // NotesTextView owns click-versus-drag activation. Avoid a second
            // native open when this legacy block editor handles selection.
            true
        }
        func publish() {
            guard !loading, let view = textView, !view.hasMarkedText() else { measure(); return }
            var block = parent.block; block.text = view.string
            do {
                block.richText = try view.attributedString().data(from: NSRange(location: 0, length: view.attributedString().length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                block.markdown = Self.markdown(view.attributedString())
                lastBlock = block
                parent.session.updateText(block)
            } catch { parent.session.failure = "富文本保存失败：" + error.localizedDescription }
            measure()
        }
        func measure() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = max(parent.fontSize * 1.7, layout.usedRect(for: container).height + 8)
            DispatchQueue.main.async { [weak self] in self?.parent.onHeight(height) }
        }
        static func markdown(_ attributed: NSAttributedString) -> String {
            let text = attributed.string as NSString
            var lines: [String] = []
            var start = 0
            while start < text.length {
                let newline = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
                let end = newline.location == NSNotFound ? text.length : newline.location
                let lineRange = NSRange(location: start, length: end - start)
                let line = text.substring(with: lineRange)
                let bullet = line.hasPrefix("• ")
                let contentRange = NSRange(location: start + (bullet ? 2 : 0), length: lineRange.length - (bullet ? 2 : 0))
                var result = bullet ? "- " : ""
                attributed.enumerateAttributes(in: contentRange) { attributes, range, _ in
                    let run = text.substring(with: range)
                    let leading = String(run.prefix(while: { $0.isWhitespace }))
                    let remainder = run.dropFirst(leading.count)
                    let trailing = String(remainder.reversed().prefix(while: { $0.isWhitespace }).reversed())
                    var value = String(remainder.dropLast(trailing.count))
                    for token in ["\\", "*", "_", "[", "]", "`", "<", ">"] { value = value.replacingOccurrences(of: token, with: "\\" + token) }
                    if !value.isEmpty {
                        let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
                        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { value = "<u>" + value + "</u>" }
                        if traits.contains(.italicFontMask) { value = "*" + value + "*" }
                        if traits.contains(.boldFontMask) { value = "**" + value + "**" }
                        if let url = NotesWebLink.destination(from: attributes[.link]) {
                            let destination = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
                            value = "[" + value + "](" + destination + ")"
                        }
                    }
                    result += leading + value + trailing
                }
                lines.append(result)
                if newline.location == NSNotFound { break }
                start = end + 1
                if start == text.length { lines.append("") }
            }
            return lines.joined(separator: "\n")
        }
    }
}

/// A plain native field with the same document undo history as the body.
struct NotesTitleTextField: NSViewRepresentable {
    @ObservedObject var session: NotesEditorSession
    var scale: CGFloat = 1
    var compact = false
    private var titleSize: CGFloat { (compact ? 22 : 24) * scale }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.isEditable = true
        field.font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        field.textColor = NSColor(NotesTheme.text); field.placeholderString = "未命名闪念"
        field.lineBreakMode = .byWordWrapping; field.usesSingleLineMode = false
        field.cell?.wraps = true; field.cell?.isScrollable = false
        field.focusRingType = .none; field.delegate = context.coordinator
        field.setAccessibilityLabel("闪念标题")
        field.stringValue = session.note.title
        session.titleField = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        if field.stringValue != session.note.title {
            let selection = (field.currentEditor() as? NSTextView)?.selectedRange()
            field.stringValue = session.note.title
            if let selection, let editor = field.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: min(selection.location, field.stringValue.utf16.count), length: 0))
            }
        }
        field.font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        field.textColor = NSColor(NotesTheme.text)
        field.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: NSTextField,context: Context) -> CGSize? {
        let width = max(100,proposal.width ?? 500)
        let height = nsView.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:width,height:10000)).height ?? titleSize * 1.45
        return CGSize(width:width,height:max(titleSize * 1.45,ceil(height)))
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let session: NotesEditorSession
        init(_ session: NotesEditorSession) { self.session = session }
        func controlTextDidBeginEditing(_ notification: Notification) {
            session.endTypingGroup()
            if let field = notification.object as? NSTextField, let editor = field.currentEditor() as? NSTextView { editor.allowsUndo = false }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            session.changeTitle(field.stringValue)
        }
        func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(), let body = session.textView {
                control.window?.makeFirstResponder(body); return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            session.changeTitle(field.stringValue); session.endTypingGroup()
        }
    }
}

/// The title's shared AppKit field editor routes the native Edit menu to document undo.
final class NotesTitleFieldEditor: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) { NotesTextMenu.show(for: self, event: event, session: session) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    weak var session: NotesEditorSession?
    override var undoManager: UndoManager? { nil }
    @objc func undo(_ sender: Any?) { session?.undo() }
    @objc func redo(_ sender: Any?) { session?.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return session?.undoManager.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return session?.undoManager.canRedo == true }
        return super.validateMenuItem(menuItem)
    }
}
