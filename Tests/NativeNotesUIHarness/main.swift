import AppKit
import Foundation
import SwiftUI
import NotesCore

@main struct UIHarness {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        if CommandLine.arguments.dropFirst().first == "--durability-child" {
            try DurabilityProbe.child(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LineNotes-ui-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        let note = try store.create()
        let session = NotesEditorSession(note: note, store: store)
        session.undoManager.groupsByEvent = false
        func group(_ body: () throws -> Void) rethrows { session.undoManager.beginUndoGrouping(); defer { session.undoManager.endUndoGrouping() }; try body() }
        func check(_ value: Bool, _ name: String) { if !value { fatalError("FAIL: " + name) }; print("PASS: " + name) }
        try group {
            session.changeTitle("原生闪念")
            var block = session.note.blocks[0]; block.text = "第一段"; session.updateText(block)
            try session.commit()
        }
        try store.setOnLine(note.id, true)
        try group { session.endTypingGroup(); var block = session.note.blocks[0]; block.text = "新的内容"; session.updateText(block); try store.setOnLine(note.id, false); try session.commit() }
        check(store.document(id: note.id)?.onLine == false, "editor commits preserve newer membership")
        session.undo()
        check(session.note.blocks[0].text == "第一段", "text snapshot undo")
        session.redo()
        check(session.note.blocks[0].text == "新的内容", "text snapshot redo")
        try session.commit()
        let file = root.appendingPathComponent("original.txt"); let content = Data("owned attachment bytes".utf8); try content.write(to: file)
        group { session.importURLs([file]) }
        check(session.note.attachments.count == 1, "native session attachment import")
        let imported = session.note.attachments[0]
        try group { session.removeAttachment(imported); try session.commit() }
        check(!FileManager.default.fileExists(atPath: try store.url(for: imported).path), "removed owned copy cleaned after save")
        session.undo(); try session.commit()
        let restored = session.note.attachments[0]
        check(try Data(contentsOf: store.url(for: restored)) == content, "attachment undo restores bytes after autosave cleanup")
        session.redo(); try session.commit()
        check(session.note.attachments.isEmpty, "attachment removal redo")
        session.undo(); try session.commit()
        check(try Data(contentsOf: store.url(for: session.note.attachments[0])) == content, "attachment repeated undo remaps IDs safely")
        check(try Data(contentsOf: file) == content, "source attachment remains unchanged")
        let other = NotesEditorSession(note: try store.create(), store: store)
        check(!other.undoManager.canUndo, "another editor has a separate undo history")
        let text = NotesTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80)); text.session = session; text.blockID = session.note.blocks[0].id; text.allowsUndo = false
        text.textStorage?.setAttributedString(NSAttributedString(string: "格式测试", attributes: [.font: NSFont.systemFont(ofSize: 23)]))
        text.setSelectedRange(NSRange(location: 0, length: 2))
        var published = false
        text.publish = { published = true }
        text.format(.bold)
        let font = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "native selected bold changes RTF attributes")
        check(text.selectedRange() == NSRange(location: 0, length: 2), "formatting preserves selection")
        let markdown = RichNoteTextView.Coordinator.markdown(text.attributedString())
        check(markdown.contains("**格式**"), "native rich text produces portable Markdown")
        _ = published
        session.textView = text
        group { session.endTypingGroup(); var block = session.note.blocks[0]; block.text = "输入法完成后保存"; session.updateText(block) }
        text.setMarkedText("中文组合", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: 0, length: 0))
        check(text.hasMarkedText(), "AppKit marked-text probe starts composition")
        RunLoop.current.run(until: Date().addingTimeInterval(0.95))
        check(text.hasMarkedText() && session.dirty, "autosave waits without unmarking active composition")
        text.unmarkText(); try session.commit()
        let storeFile = store.directory.appendingPathComponent("notes.json")
        let savedFile = root.appendingPathComponent("notes-backup.json")
        try FileManager.default.moveItem(at: storeFile, to: savedFile)
        try FileManager.default.createDirectory(at: storeFile, withIntermediateDirectories: false)
        group { session.changeTitle("失败后仍保留") }
        do { try session.commit(); fatalError("FAIL: write failure should throw") }
        catch { check(session.dirty && session.failure != nil && session.note.title == "失败后仍保留", "failed writes retain unsaved edits and truthful status") }
        try FileManager.default.removeItem(at: storeFile)
        try FileManager.default.moveItem(at: savedFile, to: storeFile)
        try session.commit()
        check(!session.dirty && session.failure == nil && store.document(id: note.id)?.title == "失败后仍保留", "retry saves the retained edits after write failure")
        let undoItem = NSMenuItem(title: "撤销", action: #selector(NotesTextView.undo(_:)), keyEquivalent: "z")
        check(text.validateMenuItem(undoItem), "native body Edit menu enables document undo")
        text.perform(#selector(NotesTextView.undo(_:)), with: nil)
        check(session.note.title != "失败后仍保留", "native body undo selector reaches the shared document history")
        let titleEditor = NotesTitleFieldEditor(frame: .zero); titleEditor.session = session
        titleEditor.perform(#selector(NotesTitleFieldEditor.redo(_:)), with: nil)
        check(session.note.title == "失败后仍保留", "native title redo selector shares the body history")
        // Regressions from the independent review: blocked writes must not consume undo.
        let blockedStore = try NotesStore(directory: root.appendingPathComponent("blocked-store"))
        let blocked = NotesEditorSession(note: try blockedStore.create(), store: blockedStore)
        blocked.undoManager.groupsByEvent = false
        blocked.undoManager.beginUndoGrouping(); blocked.changeTitle("unsaved edit"); blocked.undoManager.endUndoGrouping()
        let blockedFile = blockedStore.directory.appendingPathComponent("notes.json")
        let blockedSavedData = try Data(contentsOf: blockedFile)
        try FileManager.default.removeItem(at: blockedFile)
        try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: false)
        do { try blocked.commit(); fatalError("expected blocked write") } catch {}
        blocked.undo()
        check(blocked.note.title.isEmpty && blocked.undoManager.canRedo && blocked.dirty, "text undo works in memory while atomic writes fail")
        blocked.redo()
        check(blocked.note.title == "unsaved edit" && blocked.undoManager.canUndo, "failed-save undo retains redo and undo history")
        try FileManager.default.removeItem(at: blockedFile)
        try blockedSavedData.write(to: blockedFile); try blocked.commit()
        blocked.undoManager.beginUndoGrouping(); blocked.importURLs([file]); blocked.undoManager.endUndoGrouping()
        let blockedAttachment = blocked.note.attachments[0]
        blocked.undoManager.beginUndoGrouping(); blocked.removeAttachment(blockedAttachment); blocked.undoManager.endUndoGrouping(); try blocked.commit()
        let blockedAttachmentSavedData = try Data(contentsOf: blockedFile)
        try FileManager.default.removeItem(at: blockedFile); try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: false)
        blocked.undo()
        check(blocked.note.attachments.count == 1 && blocked.undoManager.canRedo, "attachment undo restores the memory document before disk recovery")
        do { try blocked.commit(); fatalError("expected blocked attachment restore") } catch {}
        check(blocked.undoManager.canRedo && blocked.dirty, "failed attachment materialization leaves retryable history")
        blocked.redo(); blocked.undo()
        try FileManager.default.removeItem(at: blockedFile)
        try blockedAttachmentSavedData.write(to: blockedFile); try blocked.commit()
        check(try Data(contentsOf: blocked.localURL(for: blocked.note.attachments[0])) == content, "attachment undo can be retried after blocked-save recovery")

        let placement = NotesEditorSession(note: try store.create(), store: store)
        placement.undoManager.groupsByEvent = false
        let original = NSMutableAttributedString(string: "before\nafter", attributes: [.font: NSFont.systemFont(ofSize: 23)])
        original.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 23), range: NSRange(location: 0, length: 6))
        original.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 23), toHaveTrait: .italicFontMask), range: NSRange(location: 7, length: 5))
        var paragraph = placement.note.blocks[0]
        paragraph.text = original.string
        paragraph.richText = try original.data(from: NSRange(location: 0, length: original.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        placement.undoManager.beginUndoGrouping(); placement.updateText(paragraph); placement.undoManager.endUndoGrouping(); try placement.commit()
        let insertion = NotesTextView(frame: .zero); insertion.session = placement; insertion.blockID = paragraph.id
        insertion.textStorage?.setAttributedString(original); insertion.setSelectedRange(NSRange(location: 7, length: 0))
        placement.textView = insertion; placement.focusedBlock = paragraph.id
        placement.undoManager.beginUndoGrouping(); placement.importURLs([file]); placement.undoManager.endUndoGrouping()
        check(placement.note.blocks.map(\.kind) == [.paragraph, .file, .paragraph], "attachment insertion splits the paragraph at the real cursor")
        check(placement.note.blocks[0].text == "before\n" && placement.note.blocks[2].text == "after", "attachment insertion preserves both sides and document order")
        let left = NSAttributedString(rtf: placement.note.blocks[0].richText!, documentAttributes: nil)!
        let right = NSAttributedString(rtf: placement.note.blocks[2].richText!, documentAttributes: nil)!
        check(NSFontManager.shared.traits(of: left.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "left split preserves bold RTF runs")
        check(NSFontManager.shared.traits(of: right.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).contains(.italicFontMask), "right split preserves italic RTF runs")
        check(placement.note.blocks[0].markdown == "**before**\n" && placement.note.blocks[2].markdown == "*after*", "split paragraphs preserve portable formatted Markdown")
        placement.undo()
        check(placement.note.blocks.count == 1 && placement.note.blocks[0].text == original.string && placement.note.attachments.isEmpty, "split plus attachment insertion undoes as one operation")
        placement.redo(); try placement.commit()
        check(placement.note.blocks.map(\.kind) == [.paragraph, .file, .paragraph], "split attachment insertion redoes as one operation")

        let listView = NotesTextView(frame: .zero)
        let mixed = NSMutableAttributedString(string: "bold normal", attributes: [.font: NSFont.systemFont(ofSize: 23)])
        mixed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 23), range: NSRange(location: 0, length: 4))
        listView.textStorage?.setAttributedString(mixed); listView.setSelectedRange(NSRange(location: 0, length: mixed.length))
        listView.format(.bullets)
        check(NSFontManager.shared.traits(of: listView.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont).contains(.boldFontMask) && !NSFontManager.shared.traits(of: listView.textStorage!.attribute(.font, at: 7, effectiveRange: nil) as! NSFont).contains(.boldFontMask), "bullet toggle preserves mixed bold and normal attributed runs")
        check(RichNoteTextView.Coordinator.markdown(listView.attributedString()) == "- **bold** normal", "bullet Markdown keeps list syntax outside inline formatting")
        listView.format(.bullets)
        check(RichNoteTextView.Coordinator.markdown(listView.attributedString()) == "**bold** normal", "removing bullets preserves original inline formatting")
        check(RichNoteTextView.Coordinator.markdown(NSAttributedString(string: "bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 23)])) == "**bold** ", "Markdown emphasis excludes trailing whitespace")

        blocked.exportAttachment(blocked.note.attachments[0], to: blockedStore.directory.appendingPathComponent("do-not-overwrite.txt"))
        check(blocked.failure == nil && blocked.attachmentFailure != nil && blocked.attachmentRetryLabel == "重试导出", "attachment export failure does not falsely mark body unsaved and offers export retry")
        let backupStore = try NotesStore(directory: root.appendingPathComponent("backup-obstruction-store"))
        let obstructed = NotesEditorSession(note: try backupStore.create(), store: backupStore)
        obstructed.undoManager.groupsByEvent = false
        obstructed.undoManager.beginUndoGrouping(); obstructed.changeTitle("history before import"); obstructed.undoManager.endUndoGrouping()
        let obstructedTemporary = Mirror(reflecting: obstructed).children.first { $0.label == "temporaryDirectory" }!.value as! URL
        try Data("block the actual session backup directory".utf8).write(to: obstructedTemporary)
        defer { try? FileManager.default.removeItem(at: obstructedTemporary) }
        obstructed.undoManager.beginUndoGrouping(); obstructed.importURLs([file]); obstructed.undoManager.endUndoGrouping()
        let obstructedAttachment = obstructed.note.attachments[0]
        let onlyOwnedCopy = try backupStore.url(for: obstructedAttachment)
        check(obstructed.attachmentFailure != nil && FileManager.default.fileExists(atPath: onlyOwnedCopy.path), "real temporary-file obstruction reports failed backup while preserving imported copy")
        obstructed.undo()
        do { try obstructed.commit(); fatalError("unrecoverable cleanup must be blocked") } catch {}
        check(FileManager.default.fileExists(atPath: onlyOwnedCopy.path) && obstructed.undoManager.canRedo && obstructed.dirty, "undo cannot delete the only owned copy when the backup directory is blocked")
        obstructed.undo()
        do { try obstructed.commit(); fatalError("older history must also protect attachments") } catch {}
        check(obstructed.note.title.isEmpty && FileManager.default.fileExists(atPath: onlyOwnedCopy.path) && obstructed.undoManager.canRedo, "older snapshots without the attachment retain the same cleanup protection")
        try FileManager.default.removeItem(at: obstructedTemporary)
        obstructed.retryAttachments()
        check(!obstructed.dirty && obstructed.failure == nil && !FileManager.default.fileExists(atPath: onlyOwnedCopy.path), "pending undo retries cleanup only after creating a recoverable backup")
        obstructed.redo(); try obstructed.commit()
        obstructed.redo(); try obstructed.commit()
        check(try Data(contentsOf: obstructed.localURL(for: obstructed.note.attachments[0])) == content, "redo restores attachment bytes after temporary backup obstruction is removed")
        check(try Data(contentsOf: file) == content, "backup failure undo and redo never modify the original source file")
        let closeProbe = WindowCloseProbe()
        let closeWindow = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        closeWindow.delegate = closeProbe
        closeWindow.performClose(nil)
        check(closeProbe.requests == 1, "borderless performClose reaches the delegate save protocol")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: closeWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        check(closeWindow.performKeyEquivalent(with: escape) && closeProbe.requests == 2, "borderless Escape reaches the same close protocol")
        let routing = MenuRoutingWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        routing.isReleasedWhenClosed = false
        let routingText = NSTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 160))
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        surface.addSubview(routingText); routing.contentView = surface
        routing.makeKeyAndOrderFront(nil); routing.makeFirstResponder(routingText)
        routingText.string = "保留原生选区"; routingText.setSelectedRange(NSRange(location: 0, length: 2))
        let actions = NSMenu(); actions.addItem(ClosureMenuItem("测试动作") {})
        let presenter = NotesMenuPresenter.shared
        presenter.show(actions, from: routingText)
        check(presenter.isPresented && routingText.selectedRange() == NSRange(location: 0, length: 2), "custom menu preserves the source native text selection")
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: presenter.panel!.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        check(presenter.handleKey(tab) == nil && !presenter.isPresented && routing.receivedKeys.last == 48, "Tab dismisses and forwards to the saved source window")
        check(routing.firstResponder === routingText, "custom menu dismissal restores the original responder")
        routingText.setMarkedText("组合中", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        let compositionKeyBefore = routing.isKeyWindow
        presenter.show(actions, from: routingText)
        check(routingText.hasMarkedText() && routing.isKeyWindow == compositionKeyBefore && presenter.panel?.isKeyWindow == false, "opening a custom menu does not take key status from active composition")
        let composing = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: routing.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        check(presenter.handleKey(composing) == nil && !presenter.isPresented && routing.receivedKeys.last == 0, "composition keys dismiss the menu and reach the source input window")
        routingText.unmarkText(); routing.orderOut(nil)
        let motion = NotesWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        motion.isReleasedWhenClosed = false
        NotesWindowMotion.show(motion); NotesWindowMotion.hide(motion); NotesWindowMotion.show(motion)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        check(motion.isVisible && motion.alphaValue > 0.99, "rapid close and reopen cancels the pending window hide")
        let savedMotion = UserDefaults.standard.object(forKey: "notesReduceMotion")
        UserDefaults.standard.set(true, forKey: "notesReduceMotion")
        NotesWindowMotion.hide(motion)
        check(!motion.isVisible && motion.alphaValue == 1, "reduced motion hides immediately without leaving a transparent window")
        NotesWindowMotion.show(motion)
        check(motion.isVisible && motion.alphaValue == 1, "reduced motion opens in the final visible state")
        motion.orderOut(nil); UserDefaults.standard.set(savedMotion, forKey: "notesReduceMotion")
        let searchWindow = NotesWorkspace.makeWindow(title: "SwiftUI search regression", size: NSSize(width: 700, height: 400), minimum: NSSize(width: 650, height: 390))
        searchWindow.contentView = NSHostingView(rootView: SearchFieldRegressionView())
        searchWindow.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.compactMap { textField(in: $0) }.first
        }
        guard let searchField = textField(in: searchWindow.contentView!) else { fatalError("SwiftUI search field must exist") }
        searchField.selectText(nil)
        let nativeFieldEditor = searchField.currentEditor()
        check(nativeFieldEditor != nil && nativeFieldEditor !== routingText, "SwiftUI search uses its own native field editor after focus traversal")
        presenter.show(actions, from: searchField)
        let searchTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: presenter.panel!.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        _ = presenter.handleKey(searchTab)
        searchField.selectText(nil)
        check(!presenter.isPresented && searchField.currentEditor() === nativeFieldEditor, "menu Tab and refocus preserve SwiftUI field editor compatibility")
        let searchAnchor = NSView(frame: searchField.convert(searchField.bounds, to: searchWindow.contentView))
        searchWindow.contentView!.addSubview(searchAnchor)
        check(NotesTextMenu.field(inside: searchAnchor) === searchField, "custom search context anchor resolves only its native field")
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: searchField.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0, windowNumber: searchWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        check(NotesTextMenu.showFieldMenu(inside: searchAnchor, event: rightClick) && presenter.isPresented && searchField.currentEditor() === nativeFieldEditor, "custom search context surface retains SwiftUI native editing compatibility")
        presenter.dismiss(animated: false); searchAnchor.removeFromSuperview(); searchWindow.orderOut(nil)
        // Put the test anchor under the existing pointer without moving it.
        let pointer = NSEvent.mouseLocation
        let helpWindow = NotesWindow(contentRect: NSRect(x: pointer.x - 40, y: pointer.y - 25, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        helpWindow.isReleasedWhenClosed = false
        let helpAnchor = NotesTooltipAnchor.AnchorView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        helpWindow.contentView = helpAnchor
        helpWindow.makeKeyAndOrderFront(nil)
        let responder = helpWindow.firstResponder
        NotesTooltipPresenter.shared.show("原生即时提示", from: helpAnchor)
        check(NotesTooltipPresenter.shared.isPresented, "immediate tooltip presents with a real visible anchor")
        check(NotesTooltipPresenter.shared.panel?.canBecomeKey == false && NotesTooltipPresenter.shared.panel?.ignoresMouseEvents == true, "tooltip never steals keyboard or pointer input")
        check(helpWindow.firstResponder === responder, "tooltip preserves the source responder")
        presenter.show(actions, from: helpAnchor)
        check(!NotesTooltipPresenter.shared.isPresented && presenter.isPresented, "opening a menu dismisses the tooltip")
        presenter.dismiss(animated: false)
        helpWindow.orderOut(nil)
        let quitStore = try NotesStore(directory: root.appendingPathComponent("clean-quit"))
        var quitNote = try quitStore.create()
        func canQuitAfterExternalSave(openEditor: Bool) throws -> Bool {
            let stale = try NotesStore(directory: quitStore.directory)
            let workspace = NotesWorkspace(store: stale)
            if openEditor { workspace.open(quitNote.id) }
            quitNote.title = UUID().uuidString; try quitStore.update(quitNote)
            // Old behavior opens a blocking error alert. Unblock only this harness.
            let escape = Timer(timeInterval: 0.15, repeats: false) { _ in NSApp.abortModal() }
            RunLoop.main.add(escape, forMode: .modalPanel)
            defer { escape.invalidate() }
            return workspace.prepareToQuit()
        }
        check(try canQuitAfterExternalSave(openEditor: false), "clean stale instance can quit without writing over a newer store")
        check(try canQuitAfterExternalSave(openEditor: true), "unchanged editor can quit after another process saves")
        try DurabilityProbe.run(root: root, check: check)
        print("UI HARNESS COMPLETE")
    }
}

@MainActor final class WindowCloseProbe: NSObject, NSWindowDelegate {
    var requests = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
}

@MainActor final class MenuRoutingWindow: NSWindow {
    var receivedKeys: [UInt16] = []
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { receivedKeys.append(event.keyCode) }
        else { super.sendEvent(event) }
    }
}

private struct SearchFieldRegressionView: View {
    @State private var query = "search fixture"
    var body: some View {
        VStack { TextField("搜索", text: $query).textFieldStyle(.plain); Button("Next") {} }.padding(20)
    }
}
