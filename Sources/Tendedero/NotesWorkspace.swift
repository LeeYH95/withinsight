import AppKit
import SwiftUI
import NotesCore

@MainActor
final class NotesWorkspace {
    let store: NotesStore
    var settingsActions = NotesSettingsActions()
    var onHang: ((UUID) -> Void)?
    var onTakeOff: ((UUID) -> Void)?
    var onFocus: ((UUID?) -> Void)?
    /// Screen-space hanging card, or the library paper entry for off-line
    /// notes. The strip supplies this geometry without changing membership.
    var editorTransitionAnchor: ((UUID) -> NSRect?)?
    private var editors: [UUID: NotesEditorController] = [:]
    private var library: NSWindowController?
    private var settings: NSWindowController?
    private var defaultsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    init(store: NotesStore) {
        self.store = store
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.allWindows.forEach { NotesEditorTransition.finish($0); Self.clamp($0) }
            }
        }
    }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }; if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    private var allWindows: [NSWindow] { editors.values.compactMap(\.window) + [library?.window, settings?.window].compactMap { $0 } }
    var hasVisibleEditor: Bool { editors.values.contains { $0.window?.isVisible == true } }
    func open(_ id: UUID) {
        NotesTooltipPresenter.shared.dismiss()
        guard let document = store.document(id: id), document.deletedAt == nil else { return }
        let controller: NotesEditorController
        if let existing = editors[id] { controller = existing; if !existing.session.dirty { existing.session.reload() } }
        else { controller = NotesEditorController(note: document, workspace: self); editors[id] = controller }
        NSApp.activate(ignoringOtherApps: true)
        if let window = controller.window {
            Self.clamp(window)
            NotesEditorTransition.show(window, from: editorTransitionAnchor?(id))
        }
        onFocus?(id)
        if controller.session.note.title.isEmpty && controller.session.note.blocks.allSatisfy({ $0.text.isEmpty }) && controller.session.note.attachments.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak controller] in
                guard let controller, controller.window?.isKeyWindow == true else { return }
                if let first = controller.session.note.blocks.first, first.kind == .checklist { controller.session.focusedBlock = first.id }
                if let body = controller.session.textView { controller.window?.makeFirstResponder(body) }
            }
        }
    }
    func newNote(template: NoteTemplate = .text) {
        perform {
            let note = try store.create(template: template, paper: NotesTheme.defaultPaper)
            if UserDefaults.standard.bool(forKey: "notesAutoHang") { try store.setOnLine(note.id, true); onHang?(note.id) }
            open(note.id)
        }
    }
    func showLibrary() {
        if library == nil {
            let window = Self.makeWindow(title: "全部闪念", size: NSSize(width: 820, height: 560), minimum: NSSize(width: 640, height: 420))
            window.contentView = NSHostingView(rootView: NotesLibraryView(workspace: self, store: store))
            let frameName = "NotesLibraryWindow-compact-v1"
            _ = window.setFrameUsingName(frameName)
            window.setFrameAutosaveName(frameName)
            library = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = library?.window { window.appearance = NotesTheme.appearance(); Self.clamp(window); NotesWindowMotion.show(window) }
        NotificationCenter.default.post(name: .notesFocusSearch, object: nil)
    }
    func showSettings() {
        NotesTooltipPresenter.shared.dismiss()
        if settings == nil {
            let window = Self.makeWindow(title: "闪念偏好设置", size: NSSize(width: 760, height: 500), minimum: NSSize(width: 650, height: 440))
            window.contentView = NSHostingView(rootView: NotesSettingsView(actions: settingsActions))
            settings = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = settings?.window { window.appearance = NotesTheme.appearance(); Self.clamp(window); NotesWindowMotion.show(window) }
    }
    func copy(_ id: UUID) {
        perform {
            try commit(id)
            guard let note = store.document(id: id) else { return }
            let text = editors[id]?.session.readableText ?? ([note.displayTitle] + note.blocks.map { $0.kind == .checklist ? "\($0.isChecked ? "☑" : "☐") \($0.text)" : $0.text }).joined(separator: "\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func showRecoveryFolder() {
        let folder = store.directory.appendingPathComponent("recovery", isDirectory: true)
        perform { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(folder) }
    }
    func duplicate(_ id: UUID) {
        perform { try commit(id); let note = try store.duplicate(id); try store.setOnLine(note.id, true); onHang?(note.id); open(note.id) }
    }
    func export(_ id: UUID) {
        perform {
            try commit(id)
            guard let note = store.document(id: id) else { return }
            let panel = NSSavePanel(); panel.title = "导出闪念及附件"; panel.allowedContentTypes = [.init(filenameExtension: "md")!]
            panel.nameFieldStringValue = Self.safeFilename(note.displayTitle) + ".md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try store.exportMarkdown(id, to: url)
        }
    }
    func requestTrash(_ id: UUID) {
        guard let note = store.document(id: id) else { return }
        let alert = NSAlert(); alert.messageText = "将“\(note.displayTitle)”移到最近删除？"
        alert.informativeText = "正文和附件副本将保留，你可以在全部闪念的最近删除中恢复。原始文件不会被删除。"
        alert.addButton(withTitle: "移到最近删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try commit(id); try store.trash(id); hideEditor(id); onTakeOff?(id) }
    }
    func restore(_ id: UUID) {
        perform { try store.restore(id); if store.document(id: id)?.onLine == true { onHang?(id) } }
    }
    func permanentlyDelete(_ id: UUID) {
        guard let note = store.document(id: id), note.deletedAt != nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "永久删除“\(note.displayTitle)”？"; alert.informativeText = "此操作无法撤销。闪念及应用内的附件副本会被永久删除，原始文件不受影响。"
        alert.addButton(withTitle: "永久删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try store.permanentlyDelete(id); hideEditor(id); editors.removeValue(forKey: id) }
    }
    func requestEmptyTrash(query: String, completion: @escaping (Int) -> Void) {
        guard let window = library?.window, window.attachedSheet == nil else { return }
        let request = NotesEmptyTrashConfirmation(documents: store.documents, query: query)
        guard !request.ids.isEmpty else { return }
        NotesTooltipPresenter.shared.dismiss()
        let alert = request.makeAlert()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.perform {
                let removed = try self.store.emptyTrash(request.ids)
                for id in removed {
                    self.hideEditor(id)
                    self.editors.removeValue(forKey: id)
                }
                completion(removed.count)
            }
        }
    }
    @discardableResult func takeOff(_ id: UUID) -> Bool {
        do { try commit(id); try store.setOnLine(id, false); editors[id]?.session.reload(); hideEditor(id); onTakeOff?(id); return true }
        catch { editors[id]?.session.failure = error.localizedDescription; editors[id]?.window?.makeKeyAndOrderFront(nil); showError(error); return false }
    }
    func hang(_ id: UUID, hide: Bool = false) {
        perform { try commit(id); try store.setOnLine(id, true); editors[id]?.session.reload(); onHang?(id); if hide { hideEditor(id) } }
    }
    func closeEditor(_ id: UUID) {
        guard let controller = editors[id] else { return }
        if resolvePending(controller.session, quitting: false) { hideEditor(id) }
    }
    private func hideEditor(_ id: UUID) {
        NotesTooltipPresenter.shared.dismiss()
        if let window = editors[id]?.window {
            NotesEditorTransition.hide(window, to: editorTransitionAnchor?(id))
        }
        onFocus?(editors.first(where: { $0.key != id && $0.value.window?.isKeyWindow == true && $0.value.window?.isVisible == true })?.key)
    }
    func prepareToQuit() -> Bool {
        for controller in editors.values { if !resolvePending(controller.session, quitting: true) { return false } }
        do {
            if store.hasPendingChanges { try store.flush() }
            return true
        }
        catch {
            showError(error); return false
        }
    }
    private func resolvePending(_ session: NotesEditorSession, quitting: Bool) -> Bool {
        do { try session.commit(); return true }
        catch {
            session.window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "“\(session.note.displayTitle)”尚未保存"
            alert.informativeText = error.localizedDescription + "\n内容仍保留在此窗口。请重试保存。"
            alert.addButton(withTitle: "重试"); alert.addButton(withTitle: quitting ? "取消退出" : "继续编辑")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return resolvePending(session, quitting: quitting)
            default: return false
            }
        }
    }
    func thumbnail(for note: NoteDocument) -> NSImage { NoteThumbnail.image(for: note) }
    func commit(_ id: UUID) throws { try editors[id]?.session.commit() }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { showError(error) } }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "操作未能完成"; alert.informativeText = error.localizedDescription; alert.runModal()
    }
    private func applyAppearance() { allWindows.forEach { $0.appearance = NotesTheme.appearance() } }
    static func safeFilename(_ name: String) -> String { String(name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(100)) }
    static func makeWindow(title: String, size: NSSize, minimum: NSSize) -> NSWindow {
        let window = NotesWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = minimum; window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.appearance = NotesTheme.appearance(); window.center()
        return window
    }
    static func clamp(_ window: NSWindow) {
        let frame = clampedFrame(window.frame, for: window)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
    static func clampedFrame(_ requested: NSRect, for window: NSWindow) -> NSRect {
        let screens = NSScreen.screens
        guard let screen = screens.max(by: { $0.visibleFrame.intersection(requested).area < $1.visibleFrame.intersection(requested).area }) ?? NSScreen.main else { return requested }
        let available = screen.visibleFrame
        var frame = requested
        frame.size.width = min(max(frame.width, window.minSize.width), available.width)
        frame.size.height = min(max(frame.height, window.minSize.height), available.height)
        frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        return frame
    }
}

private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

final class NotesWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control), let contentView {
            var candidate = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
            while let view = candidate {
                if let body = view as? NotesContinuousTextView {
                    // SwiftUI's expanded empty paper can hit the text view while
                    // AppKit keeps the title field editor. Focus before routing
                    // the click; native caret placement and dragging still run.
                    if firstResponder !== body { makeFirstResponder(body) }
                    break
                }
                candidate = view.superview
            }
        }
        let contextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if contextClick, let contentView {
            var candidate = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
            while let view = candidate {
                if let text = view as? NSTextView {
                    if let notesText = text as? NotesTextView {
                        notesText.rightMouseDown(with: event)
                    } else {
                        NotesTextMenu.show(for: text, event: event, session: NotesTextMenu.session(for: text))
                    }
                    return
                }
                if let field = view as? NSTextField, field.isEditable, field.isEnabled {
                    makeFirstResponder(field)
                    if let text = field.currentEditor() as? NSTextView {
                        NotesTextMenu.show(for: text, event: event, session: NotesTextMenu.session(for: text)); return
                    }
                }
                candidate = view.superview
            }
        }
        super.sendEvent(event)
    }
    var onEscape: (() -> Void)?
    var notesUndo: (() -> Void)?
    var notesRedo: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, attachedSheet == nil, (firstResponder as? NSTextView)?.hasMarkedText() != true {
            cancelOperation(nil); return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z", (firstResponder as? NSTextView)?.hasMarkedText() != true, notesUndo != nil {
            if event.modifierFlags.contains(.shift) { notesRedo?() } else { notesUndo?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) {
        guard attachedSheet == nil else { return }
        if delegate?.windowShouldClose?(self) == false { return }
        NotesWindowMotion.hide(self)
    }
    override func cancelOperation(_ sender: Any?) { if let onEscape { onEscape() } else { performClose(sender) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, attachedSheet == nil, (firstResponder as? NSTextView)?.hasMarkedText() != true { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class NotesEditorController: NSWindowController, NSWindowDelegate {
    let session: NotesEditorSession
    weak var workspace: NotesWorkspace?
    private var restoredFrame: NSRect?
    private lazy var titleFieldEditor: NotesTitleFieldEditor = {
        let editor = NotesTitleFieldEditor(frame: .zero)
        editor.session = session; editor.isFieldEditor = true; editor.isRichText = false; editor.allowsUndo = false
        return editor
    }()
    init(note: NoteDocument, workspace: NotesWorkspace) {
        session = NotesEditorSession(note: note, store: workspace.store); self.workspace = workspace
        let window = NotesWorkspace.makeWindow(title: note.displayTitle, size: NSSize(width: 880, height: 650), minimum: NSSize(width: 420, height: 360))
        super.init(window: window)
        window.delegate = self; window.level = note.pinned ? .floating : .normal
        _ = window.setFrameUsingName("NotesEditor-" + note.id.uuidString)
        session.window = window
        session.onTitleChange = { [weak window] title in window?.title = title }
        session.onPinChange = { [weak window] pinned in window?.level = pinned ? .floating : .normal }
        (window as? NotesWindow)?.onEscape = { [weak self] in self?.workspace?.closeEditor(note.id) }
        (window as? NotesWindow)?.notesUndo = { [weak self] in self?.session.undo() }
        (window as? NotesWindow)?.notesRedo = { [weak self] in self?.session.redo() }
        window.contentView = NSHostingView(rootView: NoteEditorView(session: session, workspace: workspace, expand: { [weak self] in self?.toggleExpand() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { workspace?.closeEditor(session.note.id); return false }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field === session.titleField else { return nil }
        return titleFieldEditor
    }
    func windowDidBecomeKey(_ notification: Notification) { workspace?.onFocus?(session.note.id) }
    func windowDidResignKey(_ notification: Notification) { if window?.isVisible == false { workspace?.onFocus?(nil) } }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    private func saveFrame() { window?.saveFrame(usingName: "NotesEditor-" + session.note.id.uuidString) }
    private func toggleExpand() {
        guard let window else { return }
        NotesEditorTransition.finish(window)
        if let frame = restoredFrame { NotesWindowMotion.resize(window, to: frame); restoredFrame = nil }
        else if let screen = window.screen ?? NSScreen.main { restoredFrame = window.frame; NotesWindowMotion.resize(window, to: screen.visibleFrame.insetBy(dx: 18, dy: 18)) }
    }
}

struct NotesWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NotesDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class NotesDragView: NSView {
        private var start: (frame: NSRect, pointer: NSPoint)?
        // The first press on an inactive window must both activate and drag.
        // Track ordinary AppKit drag events rather than handing the gesture
        // back to performDrag, which can return without moving borderless hosts.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            start = nil
            guard let window, window.isMovable, window.attachedSheet == nil,
                  !event.modifierFlags.contains(.control) else { return }
            NotesTooltipPresenter.shared.dismiss()
            start = (window.frame, window.convertPoint(toScreen: event.locationInWindow))
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let start, window.attachedSheet == nil else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let dx = pointer.x - start.pointer.x, dy = pointer.y - start.pointer.y
            guard hypot(dx, dy) >= 3 else { return }
            NotesMenuPresenter.shared.dismiss()
            let requested = start.frame.offsetBy(dx: dx, dy: dy)
            window.setFrameOrigin(NotesWorkspace.clampedFrame(requested, for: window).origin)
        }
        override func mouseUp(with event: NSEvent) { start = nil }
    }
}
