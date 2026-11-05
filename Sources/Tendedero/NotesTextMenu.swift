import AppKit

/// The text engine stays native; only its contextual action surface is custom.
@MainActor enum NotesTextMenu {
    static func session(for view: NSTextView) -> NotesEditorSession? {
        (view as? NotesTextView)?.session ?? (view as? NotesTitleFieldEditor)?.session
    }
    static func make(for view: NSTextView, session: NotesEditorSession? = nil, at point: NSPoint? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key).notesSymbol(symbol)
            item.target = view
            item.isEnabled = view.validateMenuItem(item)
            menu.addItem(item)
        }
        if let text = view as? NotesTextView, let point, let link = text.linkContext(at: point) {
            menu.addItem(ClosureMenuItem("打开链接") { text.openLink(link.url) }.notesSymbol("arrow.up.forward.app"))
            menu.addItem(ClosureMenuItem("复制链接地址") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }.notesSymbol("link"))
            let edit = ClosureMenuItem("编辑链接文字") {
                guard let range = text.linkRange(containing: link.range.location, matching: link.url) else { return }
                text.window?.makeFirstResponder(text); text.setSelectedRange(range); text.scrollRangeToVisible(range)
            }.notesSymbol("pencil")
            edit.isEnabled = !text.hasMarkedText(); menu.addItem(edit)
            let remove = ClosureMenuItem("移除链接，保留文字") {
                guard let range = text.linkRange(containing: link.range.location, matching: link.url) else { return }
                text.removeLink(in: range)
            }.notesSymbol("link")
            remove.isEnabled = !text.hasMarkedText(); menu.addItem(remove)
            menu.addItem(.separator())
        }
        if let session {
            let undo = ClosureMenuItem("撤销", key: "z") { session.undo() }.notesSymbol("arrow.uturn.backward")
            undo.isEnabled = session.undoManager.canUndo; menu.addItem(undo)
            let redo = ClosureMenuItem("重做", key: "z") { session.redo() }.notesSymbol("arrow.uturn.forward")
            redo.keyEquivalentModifierMask = [.command, .shift]
            redo.isEnabled = session.undoManager.canRedo; menu.addItem(redo)
            menu.addItem(.separator())
        } else {
            let undo = ClosureMenuItem("撤销", key: "z") { view.undoManager?.undo() }.notesSymbol("arrow.uturn.backward")
            undo.isEnabled = view.undoManager?.canUndo == true; menu.addItem(undo)
            let redo = ClosureMenuItem("重做", key: "z") { view.undoManager?.redo() }.notesSymbol("arrow.uturn.forward")
            redo.keyEquivalentModifierMask = [.command, .shift]
            redo.isEnabled = view.undoManager?.canRedo == true; menu.addItem(redo)
            menu.addItem(.separator())
        }
        add("剪切", #selector(NSText.cut(_:)), key: "x", symbol: "scissors")
        add("复制", #selector(NSText.copy(_:)), key: "c", symbol: "doc.on.doc")
        add("粘贴", #selector(NSText.paste(_:)), key: "v", symbol: "doc.on.clipboard")
        add("全选", #selector(NSText.selectAll(_:)), key: "a", symbol: "selection.pin.in.out")
        if let text = view as? NotesTextView {
            menu.addItem(.separator())
            for (title, symbol, format) in [("粗体", "bold", NotesTextFormat.bold), ("斜体", "italic", .italic), ("下划线", "underline", .underline), ("项目列表", "list.bullet", .bullets)] {
                let item = ClosureMenuItem(title) { text.format(format) }.notesSymbol(symbol)
                item.isEnabled = !text.hasMarkedText()
                menu.addItem(item)
            }
        }
        return menu
    }
    static func show(for view: NSTextView, event: NSEvent, session: NotesEditorSession? = nil) {
        view.window?.makeFirstResponder(view)
        let point = view.convert(event.locationInWindow, from: nil)
        NotesMenuPresenter.shared.show(make(for: view, session: session, at: point), from: view, at: point)
    }
    /// SwiftUI can route text-field clicks through a hosting view rather than
    /// its native field's hitTest chain. Find only the field inside this anchor;
    /// keep its private field editor and text selection completely intact.
    static func field(inside anchor: NSView) -> NSTextField? {
        guard let root = anchor.window?.contentView else { return nil }
        let region = anchor.convert(anchor.visibleRect, to: nil)
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.isEnabled,
               !field.isHiddenOrHasHiddenAncestor, field.convert(field.visibleRect, to: nil).intersects(region) { return field }
            for child in view.subviews { if let match = find(child) { return match } }
            return nil
        }
        return find(root)
    }
    @discardableResult static func showFieldMenu(inside anchor: NSView, event: NSEvent) -> Bool {
        guard let window = anchor.window, let field = field(inside: anchor) else { return false }
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        NotesMenuPresenter.shared.show(make(for: editor), from: anchor,
                                       at: anchor.convert(event.locationInWindow, from: nil))
        return true
    }
}
