import AppKit
import SwiftUI
import NotesCore

struct NotesContinuousBody: NSViewRepresentable {
    @ObservedObject var session:NotesEditorSession
    let scale:CGFloat
    var onHeight:(CGFloat)->Void
    var onAttachment:(NoteAttachment)->Void
    var onDropTargetChange: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NotesContinuousTextView {
        let view = NotesContinuousTextView(frame:NSRect(x:0,y:0,width:500,height:100),textContainer:nil)
        // SwiftUI owns the viewport height. TextKit shrinking to its used
        // lines during edits leaves no space for the contextual toolbar.
        view.isVerticallyResizable = false
        view.session = session; session.textView = view; view.readingScale = scale
        view.preservePastedFormatting = UserDefaults.standard.string(forKey:"notesPasteMode") == "preserve"
        view.delegate = context.coordinator
        view.contextTools.enabled = true
        view.imageProvider = { [weak session] attachment in guard let session, let url = try? session.localURL(for:attachment) else { return nil }; return NotesImageCache.shared.image(at:url) }
        view.onAttachment = onAttachment
        view.onDropTargetChange = onDropTargetChange
        view.publish = { [weak coordinator = context.coordinator] in coordinator?.publish() }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.view = view; context.coordinator.load(); return view
    }
    func updateNSView(_ view:NotesContinuousTextView, context:Context) {
        context.coordinator.parent = self
        view.onAttachment = onAttachment
        view.onDropTargetChange = onDropTargetChange
        view.preservePastedFormatting = UserDefaults.standard.string(forKey:"notesPasteMode") == "preserve"
        let cacheChanged = context.coordinator.imageRevision != NotesImageCache.shared.revision
        let imagesChanged = !view.hasMarkedText() && cacheChanged && view.refreshVisibleImages(session.note)
        if !view.hasMarkedText() { context.coordinator.imageRevision = NotesImageCache.shared.revision }
        if !view.hasMarkedText(), context.coordinator.lastBlocks != session.note.blocks || view.readingScale != scale || imagesChanged || session.bodySelectionToRestore != nil {
            view.readingScale = scale; context.coordinator.load()
        }
        context.coordinator.measure()
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NotesContinuousTextView,context:Context)->CGSize? {
        let width = max(100,proposal.width ?? 500)
        // Proposal probes must not mutate the live TextKit width. The actual
        // NSTextView frame owns it through widthTracksTextView.
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
        private var pendingHeight: CGFloat?
        private var heightScheduled = false
        init(_ parent:NotesContinuousBody) { self.parent = parent }
        func load() {
            guard let view, !view.hasMarkedText() else { return }
            lastBlocks = parent.session.note.blocks; imageRevision = NotesImageCache.shared.revision
            view.loadDocument(parent.session.note)
            // Import puts the caret in the new paragraph after the attachment.
            if let focused = parent.session.focusedBlock, focused != view.blockID {
                if let last = parent.session.note.blocks.last, last.id == focused, last.kind == .paragraph, last.text.isEmpty {
                    view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                    view.blockID = focused
                }
                view.textStorage?.enumerateAttribute(.notesBlock,in:NSRange(location:0,length:view.textStorage?.length ?? 0)) { id,range,stop in
                    if id as? String == focused.uuidString { view.setSelectedRange(NSRange(location:range.location,length:0)); view.blockID = focused; stop.pointee = true }
                }
                let caret = view.selectedRange()
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.window?.firstResponder === view, view.blockID == focused,
                          view.selectedRange() == caret else { return }
                    view.scrollRangeToVisible(caret)
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
                let blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale,
                    trailingAttributes: view.trailingAttributes, cache: view.bodyEncodingCache)
                view.pruneVisibleImages(to: Set(blocks.compactMap(\.attachmentID)))
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
            view.contextTools.selectionChanged()
            let index = min(view.selectedRange().location,max(0,(view.textStorage?.length ?? 0) - 1))
            if (view.textStorage?.length ?? 0) > 0, let id = (view.textStorage?.attribute(.notesBlock,at:index,effectiveRange:nil) as? String).flatMap(UUID.init(uuidString:)) { view.blockID = id; parent.session.focusedBlock = id }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
        func measure() {
            guard let view, let container = view.textContainer, let manager = view.layoutManager else { return }
            guard !view.loading else { return }
            // IME composition may have deferred a completed decode. The first
            // safe layout after composition must consume it even without a new edit.
            if !view.hasMarkedText(), imageRevision != NotesImageCache.shared.revision {
                imageRevision = NotesImageCache.shared.revision
                if view.refreshVisibleImages(parent.session.note) { load(); return }
            }
            manager.ensureLayout(for:container)
            let height = max(100,manager.usedRect(for:container).height + 16)
            if abs(height - measured) > 0.5 {
                measured = height; pendingHeight = height
                guard !heightScheduled else { return }
                heightScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.heightScheduled = false
                    if let latest = self.pendingHeight { self.pendingHeight = nil; self.parent.onHeight(latest) }
                }
            }
        }
    }
}
