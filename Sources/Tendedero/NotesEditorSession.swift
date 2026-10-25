import AppKit
import Combine
import NotesCore

@MainActor
final class NotesEditorSession: ObservableObject {
    @Published var note: NoteDocument
    @Published var dirty = false
    @Published var recoveryProtected = false
    @Published var failure: String?
    var pendingTextFailure: String?
    @Published var attachmentFailure: String?
    @Published var attachmentRetryLabel: String?
    private var attachmentRetry: (() -> Void)?
    @Published var undoRevision = 0
    @Published var focusedBlock: UUID?
    let store: NotesStore
    let undoManager = UndoManager()
    weak var textView: NotesTextView?
    weak var window: NSWindow?
    weak var titleField: NSTextField?
    private var hasMarkedInput: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || textView?.hasMarkedText() == true || (titleField?.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }
    var onTitleChange: ((String) -> Void)?
    var onPinChange: ((Bool) -> Void)?
    private var pending: DispatchWorkItem?
    private var recoveryJournal: NotesRecoveryJournal?
    private var recoveryBase: NoteDocument
    private var lastTypingField: UUID?
    private var lastTypingTime = Date.distantPast
    private let titleFieldID = UUID()
    private var failedURLs: [URL] = []
    private var backups: [UUID: URL] = [:]
    private let temporaryDirectory: URL
    init(note: NoteDocument, store: NotesStore) {
        self.note = note; self.store = store; recoveryBase = note
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LineNotes-editor-" + UUID().uuidString, isDirectory: true)
        undoManager.groupsByEvent = true
        undoManager.levelsOfUndo = 100
    }
    deinit { pending?.cancel(); let url = temporaryDirectory; DispatchQueue.global().async { try? FileManager.default.removeItem(at: url) } }
    func edited() {
        dirty = true; pending?.cancel()
        recoveryProtected = false
        onTitleChange?(note.displayTitle)
        do {
            if recoveryJournal == nil { recoveryJournal = try NotesRecoveryJournal(directory: store.directory) }
            try recoveryJournal?.checkpoint(note, basedOn: recoveryBase, attachmentSource: { try self.localURL(for: $0) })
            recoveryProtected = true
        } catch { failure = "恢复副本尚未写入；请保持窗口打开并重试保存。" + error.localizedDescription }
        scheduleSave(after: 0.65)
    }
    private func scheduleSave(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hasMarkedInput {
                self.scheduleSave(after: 0.25)
                return
            }
            do { try self.commit() } catch { self.failure = error.localizedDescription }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func updateText(_ block: NoteBlock) {
        guard let index = note.blocks.firstIndex(where: { $0.id == block.id }), note.blocks[index] != block else { return }
        recordTypingUndo(note, field: block.id)
        note.blocks[index] = block; edited(); undoRevision += 1
    }
    private let continuousFieldID = UUID()
    private var selectionBeforeBodyEdit: NSRange?
    private(set) var bodySelectionToRestore: NSRange?
    func captureBodySelection(_ selection: NSRange) { selectionBeforeBodyEdit = selection }
    func consumeBodySelection() -> NSRange? {
        defer { bodySelectionToRestore = nil }
        return bodySelectionToRestore
    }
    func updateBlocks(_ blocks: [NoteBlock]) {
        defer { selectionBeforeBodyEdit = nil }
        guard note.blocks != blocks else { return }
        recordTypingUndo(note, field: continuousFieldID, bodySelection: selectionBeforeBodyEdit ?? (textView as? NotesContinuousTextView)?.selectedRange())
        let previousReferences = Set(note.blocks.compactMap(\.attachmentID))
        let currentReferences = Set(blocks.compactMap(\.attachmentID))
        note.blocks = blocks
        note.attachments.removeAll { previousReferences.contains($0.id) && !currentReferences.contains($0.id) }
        edited(); undoRevision += 1
    }
    func changeTitle(_ title: String) {
        guard note.title != title else { return }
        recordTypingUndo(note, field: titleFieldID)
        note.title = title; edited(); undoRevision += 1
    }
    private func recordTypingUndo(_ previous: NoteDocument, field: UUID, bodySelection: NSRange? = nil) {
        let now = Date()
        if lastTypingField != field || now.timeIntervalSince(lastTypingTime) > 0.8 {
            registerUndo(previous, name: field == titleFieldID ? "编辑标题" : "编辑正文", bodySelection: bodySelection)
        }
        lastTypingField = field; lastTypingTime = now
    }
    func endTypingGroup() { lastTypingField = nil; lastTypingTime = .distantPast }
    func change(_ name: String, _ body: (inout NoteDocument) -> Void) {
        endTypingGroup()
        let previous = note
        let selection = (textView as? NotesContinuousTextView)?.selectedRange()
        body(&note)
        guard note != previous else { return }
        registerUndo(previous, name: name, bodySelection: previous.blocks == note.blocks ? nil : selection)
        selectionBeforeBodyEdit = nil
        edited(); undoRevision += 1
    }
    private func registerUndo(_ snapshot: NoteDocument, name: String, bodySelection: NSRange? = nil) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(snapshot, name: name, bodySelection: bodySelection) }
        }
        undoManager.setActionName(name)
    }
    private func restore(_ snapshot: NoteDocument, name: String, bodySelection: NSRange?) {
        endTypingGroup()
        let previous = note
        let inverseSelection = bodySelection == nil ? nil : bodySelectionToRestore ?? (textView as? NotesContinuousTextView)?.selectedRange()
        selectionBeforeBodyEdit = nil
        if let bodySelection { bodySelectionToRestore = bodySelection }
        // Undo changes the in-memory document first. A failed disk write must never
        // consume the user's history or prevent text from being undone.
        note = snapshot
        registerUndo(previous, name: name, bodySelection: inverseSelection)
        onPinChange?(snapshot.pinned)
        edited(); undoRevision += 1
    }
    private func materializeMissingAttachments() throws {
        for attachment in note.attachments {
            let owned = try store.url(for: attachment)
            if FileManager.default.fileExists(atPath: owned.path) { continue }
            guard let backup = backups[attachment.id] else { throw NotesStoreError.attachmentNotFound }
            let before = Set((store.document(id: note.id)?.attachments ?? []).map(\.id))
            do {
                let replacement = try store.importAttachment(from: backup, to: note.id)
                replaceAttachment(attachment.id, with: replacement, backup: backup)
            } catch {
                // The store can have copied the owned file and updated memory before
                // its atomic JSON write failed. Keep that copy for the next retry.
                if let copied = store.document(id: note.id)?.attachments.first(where: { !before.contains($0.id) }) {
                    replaceAttachment(attachment.id, with: copied, backup: backup)
                }
                throw error
            }
        }
    }
    private func replaceAttachment(_ oldID: UUID, with replacement: NoteAttachment, backup: URL) {
        if let index = note.attachments.firstIndex(where: { $0.id == oldID }) { note.attachments[index] = replacement }
        for index in note.blocks.indices where note.blocks[index].attachmentID == oldID { note.blocks[index].attachmentID = replacement.id }
        backups[replacement.id] = backup
    }
    func localURL(for attachment: NoteAttachment) throws -> URL {
        let owned = try store.url(for: attachment)
        if FileManager.default.fileExists(atPath: owned.path) { return owned }
        if let backup = backups[attachment.id], FileManager.default.fileExists(atPath: backup.path) { return backup }
        throw NotesStoreError.attachmentNotFound
    }
    func commit() throws {
        pending?.cancel(); pending = nil
        if let field = titleField, let editor = field.currentEditor() as? NSTextView {
            if editor.hasMarkedText() { editor.unmarkText() }
            changeTitle(editor.string)
        }
        if let textView, textView.hasMarkedText() { textView.unmarkText(); textView.publishChange() }
        pending?.cancel(); pending = nil
        if pendingTextFailure != nil { textView?.publishChange() }
        if let pendingTextFailure {
            failure = pendingTextFailure
            throw NSError(domain: "Shipian.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: pendingTextFailure])
        }
        guard dirty else {
            if case .failed = store.saveState { try store.flush() }
            failure = nil; return
        }
        do {
            try materializeMissingAttachments()
            guard let latest = store.document(id: note.id) else { throw NotesStoreError.noteNotFound }
            // Membership belongs to the workspace. Never overwrite a newer take-off/trash.
            note.onLine = latest.onLine; note.draft = latest.draft
            note.deletedAt = latest.deletedAt; note.wasOnLine = latest.wasOnLine
            let retainedIDs = Set(note.attachments.map(\.id))
            do {
                // Every snapshot can remove attachments, including history older than
                // the import itself. Never let store cleanup delete the only owned copy.
                for removed in latest.attachments where !retainedIDs.contains(removed.id) { try backUp(removed) }
            } catch {
                reportAttachmentFailure("附件原副本已保留；暂时无法准备撤销所需的附件：" + error.localizedDescription, retryLabel: "重试保存") { [weak self] in
                    guard let self else { return }
                    do { try self.commit(); self.clearAttachmentFailure() } catch { self.failure = error.localizedDescription }
                }
                throw error
            }
            try store.update(note)
            recoveryBase = store.document(id: note.id) ?? note
            // If cleanup is interrupted, startup compares canonical content and
            // consumes the old journal without creating a duplicate.
            try? recoveryJournal?.clear()
            dirty = false; failure = nil
            recoveryProtected = false
        } catch { failure = error.localizedDescription; throw error }
    }
    func reload() { if let updated = store.document(id: note.id) { note = updated; recoveryBase = updated; dirty = false; failure = nil } }
    func addBlock(_ kind: NoteBlock.Kind, after id: UUID? = nil) {
        if let continuous = textView as? NotesContinuousTextView, id == nil, kind == .checklist {
            continuous.toggleList("checklist"); return
        }
        let new = NoteBlock(kind: kind)
        change(kind == .checklist ? "添加待办" : "添加段落") { document in
            let index = (id ?? focusedBlock).flatMap { selected in document.blocks.firstIndex { $0.id == selected } }.map { $0 + 1 } ?? document.blocks.count
            document.blocks.insert(new, at: index)
        }
        focusedBlock = new.id
    }
    func removeEmptyBlock(_ id: UUID) {
        guard let index = note.blocks.firstIndex(where: { $0.id == id }), note.blocks[index].text.isEmpty else { return }
        change("删除空白项") { document in
            document.blocks.remove(at: index)
            if document.blocks.isEmpty { document.blocks = [NoteBlock()] }
        }
        focusedBlock = note.blocks[max(0, min(index - 1, note.blocks.count - 1))].id
    }
    func toggle(_ id: UUID) { change("勾选待办") { document in if let i = document.blocks.firstIndex(where: { $0.id == id }) { document.blocks[i].isChecked.toggle() } } }
    func setPaper(_ paper: NotePaper) { change("更换纸张") { $0.editorPaper = paper } }
    func togglePin() { change("窗口置顶") { $0.pinned.toggle() }; onPinChange?(note.pinned) }
    private struct AttachmentInsertion {
        var leading: [NoteBlock]
        var trailing: [NoteBlock]
        var storePosition: Int
    }
    private func attachmentInsertion() throws -> AttachmentInsertion {
        if let view = textView as? NotesContinuousTextView {
            let value = view.attributedString(), selection = view.selectedRange()
            let start = min(selection.location, value.length), end = min(NSMaxRange(selection), value.length)
            let left = value.attributedSubstring(from: NSRange(location: 0, length: start))
            let right = value.attributedSubstring(from: NSRange(location: end, length: value.length - end))
            var leading = left.length == 0 ? [] : try NotesContinuousDocument.blocks(from: left, scale: view.readingScale)
            // A line separator before the attachment already supplies its own boundary.
            if left.string.hasSuffix("\n"), leading.last?.text.isEmpty == true, leading.last?.kind == .paragraph { leading.removeLast() }
            var trailing = try NotesContinuousDocument.blocks(from: right, scale: view.readingScale)
            let used = Set(leading.map(\.id))
            for index in trailing.indices where used.contains(trailing[index].id) { trailing[index].id = UUID() }
            return AttachmentInsertion(leading: leading, trailing: trailing, storePosition: leading.count)
        }
        guard let focusedBlock, let index = note.blocks.firstIndex(where: { $0.id == focusedBlock }) else {
            return AttachmentInsertion(leading: note.blocks, trailing: [], storePosition: note.blocks.count)
        }
        let original = note.blocks[index]
        guard original.kind == .paragraph, let textView, textView.blockID == original.id,
              textView.string == original.text else {
            return AttachmentInsertion(leading: Array(note.blocks[...index]), trailing: Array(note.blocks.dropFirst(index + 1)), storePosition: index + 1)
        }
        let attributed = textView.attributedString()
        let selection = textView.selectedRange()
        let location = min(selection.location, attributed.length)
        let end = location + min(selection.length, attributed.length - location)
        let left = attributed.attributedSubstring(from: NSRange(location: 0, length: location))
        let right = attributed.attributedSubstring(from: NSRange(location: end, length: attributed.length - end))
        var leading = Array(note.blocks.prefix(index))
        var trailing = Array(note.blocks.dropFirst(index + 1))
        if left.length > 0 { leading.append(try Self.textBlock(left, id: original.id)) }
        trailing.insert(try Self.textBlock(right, id: left.length == 0 ? original.id : UUID()), at: 0)
        return AttachmentInsertion(leading: leading, trailing: trailing, storePosition: index + 1)
    }
    private static func textBlock(_ attributed: NSAttributedString, id: UUID) throws -> NoteBlock {
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return NoteBlock(id: id, text: attributed.string, richText: rtf, markdown: RichNoteTextView.Coordinator.markdown(attributed))
    }
    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            try commit()
            endTypingGroup()
            let old = note
            let selection = (textView as? NotesContinuousTextView)?.selectedRange()
            let plan = try attachmentInsertion()
            let oldIDs = Set(old.attachments.map(\.id))
            var importError: Error?
            for (offset, url) in urls.enumerated() {
                do { _ = try store.importAttachment(from: url, to: note.id, at: plan.storePosition + offset) }
                catch { importError = error; break }
            }
            guard let latest = store.document(id: note.id) else { throw NotesStoreError.noteNotFound }
            let additions = latest.attachments.filter { !oldIDs.contains($0.id) }
            if !additions.isEmpty {
                recoveryBase = latest
                let addedIDs = Set(additions.map(\.id))
                let addedBlocks = latest.blocks.filter { $0.attachmentID.map(addedIDs.contains) == true }
                note = old
                note.attachments = latest.attachments
                note.blocks = plan.leading + addedBlocks + plan.trailing
                for attachment in additions {
                    do { try backUp(attachment) }
                    catch { reportAttachmentFailure("附件已添加，但暂不能撤销移除：" + error.localizedDescription, retryLabel: "重试") { [weak self] in self?.retryBackup(attachment) } }
                }
                registerUndo(old, name: "添加附件", bodySelection: selection); undoRevision += 1
                focusedBlock = plan.trailing.first?.id
                edited()
                do { try commit() } catch { if importError == nil { importError = error } }
            }
            failedURLs = Array(urls.dropFirst(additions.count))
            if let importError {
                let retryLabel = failedURLs.isEmpty ? "重试保存" : "重试添加"
                reportAttachmentFailure((failedURLs.isEmpty ? "附件已添加，但尚未保存：" : "附件未能全部添加：") + importError.localizedDescription, retryLabel: retryLabel) { [weak self] in
                    guard let self else { return }
                    if !self.failedURLs.isEmpty { self.importURLs(self.failedURLs) }
                    else { do { try self.commit(); self.clearAttachmentFailure() } catch { self.failure = error.localizedDescription } }
                }
            } else if attachmentFailure?.hasPrefix("附件已添加") != true { clearAttachmentFailure() }
        } catch {
            failedURLs = urls
            reportAttachmentFailure("附件未能添加：" + error.localizedDescription, retryLabel: "重试添加") { [weak self] in guard let self else { return }; self.importURLs(self.failedURLs) }
        }
    }
    func reportAttachmentFailure(_ message: String, retryLabel: String? = nil, retry: (() -> Void)? = nil) {
        attachmentFailure = message; attachmentRetryLabel = retryLabel; attachmentRetry = retry
    }
    private func clearAttachmentFailure() { attachmentFailure = nil; attachmentRetryLabel = nil; attachmentRetry = nil }
    func retryAttachments() { attachmentRetry?() }
    private func retryBackup(_ attachment: NoteAttachment) {
        do { try backUp(attachment); clearAttachmentFailure() }
        catch { reportAttachmentFailure("暂时无法准备附件撤销：" + error.localizedDescription, retryLabel: "重试") { [weak self] in self?.retryBackup(attachment) } }
    }
    func pasteImage(_ image: NSImage) {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw NotesStoreError.invalidSource }
            let url = temporaryDirectory.appendingPathComponent("粘贴图片-" + UUID().uuidString + ".png")
            try data.write(to: url)
            importURLs([url])
        } catch { reportAttachmentFailure("图片未能粘贴：" + error.localizedDescription, retryLabel: "重试粘贴") { [weak self] in self?.pasteImage(image) } }
    }
    func prepareAttachmentsForRemoval(_ attachments: [NoteAttachment]) throws {
        for attachment in attachments { try backUp(attachment) }
    }
    private func backUp(_ attachment: NoteAttachment) throws {
        if let existing = backups[attachment.id],
           let values = try? existing.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
           FileManager.default.isReadableFile(atPath: existing.path) { return }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let folder = temporaryDirectory.appendingPathComponent(attachment.id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(attachment.name)
        try FileManager.default.copyItem(at: store.url(for: attachment), to: target)
        backups[attachment.id] = target
    }
    func removeAttachment(_ attachment: NoteAttachment) {
        do {
            try backUp(attachment)
            change("移除附件") { document in
                document.attachments.removeAll { $0.id == attachment.id }
                document.blocks.removeAll { $0.attachmentID == attachment.id }
                if document.blocks.isEmpty { document.blocks = [NoteBlock()] }
            }
            clearAttachmentFailure()
        } catch { reportAttachmentFailure("暂时无法撤销附件移除：" + error.localizedDescription, retryLabel: "重试移除") { [weak self] in self?.removeAttachment(attachment) } }
    }
    static func attachmentPanel(imagesOnly: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        if imagesOnly { panel.allowedContentTypes = [.image] }
        // Set these after the content-type filter: macOS 27 derives file and
        // directory selection flags when its allowedContentTypes changes.
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = imagesOnly ? "添加图片" : "添加附件"
        return panel
    }
    func chooseAttachment(imagesOnly: Bool) {
        let panel = Self.attachmentPanel(imagesOnly: imagesOnly)
        if let window { panel.beginSheetModal(for: window) { [weak self] response in if response == .OK { self?.importURLs(panel.urls) } } }
        else if panel.runModal() == .OK { importURLs(panel.urls) }
    }
    func openAttachment(_ attachment: NoteAttachment) {
        do { let url = try localURL(for: attachment); guard NSWorkspace.shared.open(url) else { throw NotesStoreError.invalidSource }; clearAttachmentFailure() }
        catch { reportAttachmentFailure("无法打开附件：" + error.localizedDescription, retryLabel: "重试打开") { [weak self] in self?.openAttachment(attachment) } }
    }
    func exportAttachment(_ attachment: NoteAttachment) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = attachment.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportAttachment(attachment, to: destination)
    }
    func exportAttachment(_ attachment: NoteAttachment, to destination: URL) {
        do {
            let source = try localURL(for: attachment)
            let canonical = destination.standardizedFileURL.resolvingSymlinksInPath().path
            guard canonical != store.directory.path, !canonical.hasPrefix(store.directory.path + "/") else { throw NotesStoreError.unsafePath }
            let data = try Data(contentsOf: source); try data.write(to: destination, options: .atomic)
            clearAttachmentFailure()
        } catch { reportAttachmentFailure("附件导出失败：" + error.localizedDescription, retryLabel: "重试导出") { [weak self] in self?.exportAttachment(attachment) } }
    }
    var readableText: String {
        if pendingTextFailure != nil, let view = textView as? NotesContinuousTextView { return note.displayTitle + "\n" + view.plainTextForBackup }
        return ([note.displayTitle] + note.blocks.map { block in
            switch block.kind { case .checklist: return "\(block.isChecked ? "☑" : "☐") \(block.text)"; default: return block.text }
        }).joined(separator: "\n")
    }
    func copyCurrentText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(readableText, forType: .string) }
    func format(_ action: NotesTextFormat) { endTypingGroup(); textView?.format(action); textView?.window?.makeFirstResponder(textView); endTypingGroup() }
    func undo() { endTypingGroup(); undoManager.undo(); undoRevision += 1 }
    func redo() { endTypingGroup(); undoManager.redo(); undoRevision += 1 }
}
