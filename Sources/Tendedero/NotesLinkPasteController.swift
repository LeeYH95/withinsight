import AppKit
import Combine

extension NSAttributedString.Key {
    static let notesPendingLink = NSAttributedString.Key("shipian.pending-link")
}

/// Pending title requests belong to this editor instance, never to saved RTF.
@MainActor final class NotesLinkPasteController {
    typealias Completion = @MainActor (String?) -> Void
    var loadTitle: @MainActor (URL, @escaping Completion) -> AnyCancellable = NotesLinkMetadata.fetchTitle
    private var active: Set<UUID> = []
    private var requests: [UUID: AnyCancellable] = [:]
    private weak var observedManager: UndoManager?
    private var managerObservations: [AnyCancellable] = []
    private struct Result {
        let id: UUID
        let url: URL
        let title: String
        let noteID: UUID?
    }
    private var awaitingEditor: [UUID: Result] = [:]

    @discardableResult func paste(_ url: URL, into view: NotesContinuousTextView) -> Bool {
        guard !view.hasMarkedText() else { return false }
        let id = UUID(), noteID = view.session?.note.id
        let value = NSAttributedString(string: url.absoluteString, attributes: [
            .link: url, .toolTip: url.absoluteString
        ])
        let session = view.session
        observeHistory(in: view)
        let start = view.selectedRange().location
        let restoreEvents = beginBoundary(session)
        let inserted = view.insertPasted(value)
        endBoundary(session, restoreEvents: restoreEvents)
        guard inserted else { return false }
        let range = NSRange(location: start, length: value.length)
        guard let storage = view.textStorage, NSMaxRange(range) <= storage.length,
              (storage.string as NSString).substring(with: range) == value.string else { return true }
        // Generic rich import strips private markers; only this trusted path
        // assigns a fresh request identity after insertion.
        storage.addAttribute(.notesPendingLink, value: id.uuidString, range: range)
        active.insert(id)
        let request = loadTitle(url) { [weak self, weak view] title in
            guard let self, self.active.remove(id) != nil else { return }
            self.requests[id] = nil
            guard let view else { return }
            guard let title = NotesWebLink.normalizedTitle(title) else {
                self.removeMarker(id, in: view); self.stopObservingIfIdle(); return
            }
            let result = Result(id: id, url: url, title: title, noteID: noteID)
            if self.isBusy(view) { self.awaitingEditor[id] = result }
            else { self.apply(result, in: view) }
        }
        // A test or cached loader may finish synchronously.
        if active.contains(id) { requests[id] = request }
        else { request.cancel() }
        return true
    }

    func flushCompletedTitles(in view: NotesContinuousTextView) {
        guard !isBusy(view) else { return }
        let completed = Array(awaitingEditor.values)
        awaitingEditor.removeAll()
        for result in completed { apply(result, in: view) }
        stopObservingIfIdle()
    }

    func cancelAll() {
        active.removeAll(); awaitingEditor.removeAll()
        let running = Array(requests.values)
        requests.removeAll()
        managerObservations.removeAll(); observedManager = nil
        for request in running { request.cancel() }
    }

    private func isBusy(_ view: NotesContinuousTextView) -> Bool {
        view.hasMarkedText() || (view.session?.undoManager.groupingLevel ?? 0) > 0
            || view.session?.undoManager.isUndoing == true || view.session?.undoManager.isRedoing == true
    }
    private func observeHistory(in view: NotesContinuousTextView) {
        guard let manager = view.session?.undoManager, observedManager !== manager else { return }
        managerObservations.removeAll(); observedManager = manager
        for name in [NSNotification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            managerObservations.append(NotificationCenter.default.publisher(for: name, object: manager).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelAll() }
            })
        }
        managerObservations.append(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: manager).sink { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                self.flushCompletedTitles(in: view)
            }
        })
    }
    private func stopObservingIfIdle() {
        if active.isEmpty, awaitingEditor.isEmpty { managerObservations.removeAll(); observedManager = nil }
    }

    private func beginBoundary(_ session: NotesEditorSession?) -> Bool {
        session?.endTypingGroup()
        guard let manager = session?.undoManager else { return false }
        // Avoid an implicit event group enclosing two explicit paste/title groups.
        // Do not close a group owned by another editor operation.
        let restoreEvents = manager.groupingLevel == 0 && manager.groupsByEvent
        if restoreEvents { manager.groupsByEvent = false }
        manager.beginUndoGrouping()
        return restoreEvents
    }
    private func endBoundary(_ session: NotesEditorSession?, restoreEvents: Bool) {
        session?.undoManager.endUndoGrouping(); session?.endTypingGroup()
        if restoreEvents { session?.undoManager.groupsByEvent = true }
    }

    private func ranges(_ id: UUID, in view: NotesContinuousTextView) -> [NSRange] {
        guard let storage = view.textStorage else { return [] }
        var result: [NSRange] = []
        storage.enumerateAttribute(.notesPendingLink, in: NSRange(location: 0, length: storage.length)) { token, range, _ in
            if token as? String == id.uuidString { result.append(range) }
        }
        return result
    }
    private func removeMarker(_ id: UUID, in view: NotesContinuousTextView) {
        for range in ranges(id, in: view) { view.textStorage?.removeAttribute(.notesPendingLink, range: range) }
    }
    private func apply(_ result: Result, in view: NotesContinuousTextView) {
        defer { removeMarker(result.id, in: view); stopObservingIfIdle() }
        guard view.session?.note.id == result.noteID, let storage = view.textStorage else { return }
        let matches = ranges(result.id, in: view)
        guard var range = matches.first else { return }
        for next in matches.dropFirst() {
            guard next.location == NSMaxRange(range) else { return }
            range = NSUnionRange(range, next)
        }
        guard (storage.string as NSString).substring(with: range) == result.url.absoluteString else { return }
        var targetMatches = true
        storage.enumerateAttribute(.link, in: range) { value, _, _ in
            if NotesWebLink.destination(from: value) != result.url { targetMatches = false }
        }
        guard targetMatches else { return }
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        attrs.removeValue(forKey: .notesPendingLink)
        attrs[.link] = result.url; attrs[.toolTip] = result.url.absoluteString
        let title = NSAttributedString(string: result.title, attributes: attrs)
        let selected = view.selectedRange()
        let session = view.session
        let restoreEvents = beginBoundary(session)
        defer { endBoundary(session, restoreEvents: restoreEvents) }
        guard view.shouldChangeText(in: range, replacementString: title.string) else { return }
        storage.replaceCharacters(in: range, with: title)
        func shifted(_ point: Int) -> Int {
            if point <= range.location { return point }
            if point >= NSMaxRange(range) { return point + title.length - range.length }
            return range.location + min(point - range.location, title.length)
        }
        let start = shifted(selected.location), end = shifted(NSMaxRange(selected))
        view.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        view.cleanTypingAttributes(); view.didChangeText()
    }
}
