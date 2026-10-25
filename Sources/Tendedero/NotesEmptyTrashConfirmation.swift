import AppKit
import NotesCore

/// The confirmation freezes its target set, independently of search results.
struct NotesEmptyTrashConfirmation {
    let ids: Set<UUID>
    let informativeText: String

    init(documents: [NoteDocument], query: String) {
        ids = Set(documents.filter { $0.deletedAt != nil }.map(\.id))
        let searchReminder = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "\n包含搜索未显示的闪念。"
        informativeText = "将永久删除最近删除中的 \(ids.count) 条闪念及其应用内附件副本，此操作无法恢复。"
            + searchReminder + "\n其他闪念和原始文件不受影响。"
    }

    @MainActor func makeAlert() -> NSAlert {
        let alert = NotesEmptyTrashAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空最近删除？"
        alert.informativeText = informativeText
        let confirm = alert.addButton(withTitle: "永久删除全部")
        let cancel = alert.addButton(withTitle: "取消")
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        return alert
    }
}

/// AppKit gives a button only one key equivalent. Keep Return as the safe
/// default and route Esc to that same cancel button while this sheet is key.
private final class NotesEmptyTrashAlert: NSAlert {
    private var escapeMonitor: Any?
    override init() {
        super.init()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.window.isVisible,
                  event.window === self.window else { return event }
            self.buttons.last?.performClick(nil)
            return nil
        }
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
}
