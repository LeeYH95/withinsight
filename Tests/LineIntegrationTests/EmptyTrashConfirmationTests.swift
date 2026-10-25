import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class EmptyTrashConfirmationTests: XCTestCase {
    @MainActor func testRequestCapturesAllTrashAndExplainsSearchScope() throws {
        var first = NoteDocument(); first.title = "匹配搜索"; first.deletedAt = Date()
        var hidden = NoteDocument(); hidden.title = "其他内容"; hidden.deletedAt = Date()
        let live = NoteDocument()
        let request = NotesEmptyTrashConfirmation(documents: [first, hidden, live], query: "匹配搜索")
        XCTAssertEqual(request.ids, [first.id, hidden.id])
        XCTAssertTrue(request.informativeText.contains("2 条闪念"))
        XCTAssertTrue(request.informativeText.contains("包含搜索未显示的闪念"))
        XCTAssertTrue(request.informativeText.contains("原始文件不受影响"))
        XCTAssertFalse(NotesEmptyTrashConfirmation(documents: [first], query: "  ").informativeText.contains("搜索"))
    }

    @MainActor func testConfirmationDefaultsToCancelAndHasNoDestructiveReturnShortcut() throws {
        _ = NSApplication.shared
        var deleted = NoteDocument(); deleted.deletedAt = Date()
        let alert = NotesEmptyTrashConfirmation(documents: [deleted], query: "").makeAlert()
        XCTAssertEqual(alert.messageText, "清空最近删除？")
        XCTAssertEqual(alert.buttons.map(\.title), ["永久删除全部", "取消"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[1].cell)
        XCTAssertTrue(alert.window.initialFirstResponder === alert.buttons[1])
    }

    @MainActor func testCancelSheetKeepsDataAndConfirmUsesCapturedScope() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-trash-sheet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let first = try store.create(), second = try store.create(), newer = try store.create()
        try store.trash(first.id); try store.trash(second.id)
        let workspace = NotesWorkspace(store: store)
        workspace.showLibrary()
        let library = try XCTUnwrap(NSApp.windows.first { $0 is NotesWindow && $0.title == "全部闪念" && $0.isVisible })
        defer { library.orderOut(nil); _ = workspace }
        let saved = try Data(contentsOf: root.appendingPathComponent("notes.json"))
        var removedCount: Int?
        workspace.requestEmptyTrash(query: "没有匹配项") { removedCount = $0 }
        let cancelSheet = try XCTUnwrap(library.attachedSheet)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: cancelSheet.windowNumber,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(library.attachedSheet, "Esc must activate cancellation")
        if library.attachedSheet != nil { library.endSheet(cancelSheet, returnCode: .alertSecondButtonReturn) }
        XCTAssertNil(removedCount)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes.json")), saved)

        workspace.requestEmptyTrash(query: "没有匹配项") { removedCount = $0 }
        let confirmSheet = try XCTUnwrap(library.attachedSheet)
        try store.restore(second.id); try store.trash(newer.id)
        library.endSheet(confirmSheet, returnCode: .alertFirstButtonReturn)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(removedCount, 1)
        XCTAssertNil(store.document(id: first.id))
        XCTAssertNil(store.document(id: second.id)?.deletedAt)
        XCTAssertNotNil(store.document(id: newer.id)?.deletedAt)
        XCTAssertEqual(try NotesStore(directory: root).documents, store.documents)
    }
}
