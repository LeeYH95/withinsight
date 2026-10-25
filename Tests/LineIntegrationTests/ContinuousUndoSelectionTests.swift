import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class ContinuousUndoSelectionTests: XCTestCase {
    @MainActor private func withEditor(_ run: (NotesEditorSession, NotesContinuousTextView, NotesContinuousBody.Coordinator) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        var note = try store.create()
        note.title = "原标题"
        note.blocks = [NoteBlock(text: "第一段"), NoteBlock(text: "第二段"), NoteBlock(text: "第三段")]
        try store.update(note)
        let session = NotesEditorSession(note: note, store: store)
        session.undoManager.groupsByEvent = false
        let coordinator = NotesContinuousBody(session: session, scale: 1, onHeight: { _ in }, onAttachment: { _ in }).makeCoordinator()
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.session = session; session.textView = view
        view.delegate = coordinator; coordinator.view = view
        view.publish = { coordinator.publish() }
        coordinator.load()
        try run(session, view, coordinator)
    }

    @MainActor func testUndoListConversionRestoresTheSelectedParagraphInsteadOfShiftingIntoTheNextOne() throws {
        _ = NSApplication.shared
        for kind in ["bullet", "checklist"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-undo-selection-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try NotesStore(directory: root)
            var note = try store.create()
            note.blocks = [NoteBlock(text: "第一段"), NoteBlock(text: "第二段"), NoteBlock(text: "第三段")]
            try store.update(note)
            let session = NotesEditorSession(note: note, store: store)
            session.undoManager.groupsByEvent = false
            let body = NotesContinuousBody(session: session, scale: 1, onHeight: { _ in }, onAttachment: { _ in })
            let coordinator = body.makeCoordinator()
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
            view.session = session; session.textView = view
            view.delegate = coordinator; coordinator.view = view
            view.publish = { coordinator.publish() }
            coordinator.load()
            let originalSelection = NSRange(location: 4, length: 3)
            view.setSelectedRange(originalSelection)
            session.undoManager.beginUndoGrouping()
            view.toggleList(kind)
            session.undoManager.endUndoGrouping()
            let formattedSelection = NSRange(location: 6, length: 3)
            XCTAssertEqual(view.selectedRange(), formattedSelection)
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "第二段")
            session.undo()
            coordinator.load() // The same refresh that the observed SwiftUI session performs.
            XCTAssertEqual(view.string, "第一段\n第二段\n第三段")
            XCTAssertEqual(view.selectedRange(), originalSelection, "Undo \(kind) must restore the original selection")
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "第二段", "Undo \(kind) must not select text from the next paragraph")
            session.redo()
            coordinator.load()
            XCTAssertEqual(view.selectedRange(), formattedSelection, "Redo \(kind) must restore the formatted selection")
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "第二段")
        }
    }

    @MainActor func testReplacementUndoRestoresTheReplacedSelectionAndRedoRestoresItsCaret() throws {
        try withEditor { session, view, coordinator in
            let selection = NSRange(location: 5, length: 1)
            view.setSelectedRange(selection)
            session.undoManager.beginUndoGrouping()
            view.insertText("新的文字", replacementRange: view.selectedRange())
            session.undoManager.endUndoGrouping()
            XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 0))
            session.undo(); coordinator.load()
            XCTAssertEqual(view.string, "第一段\n第二段\n第三段")
            XCTAssertEqual(view.selectedRange(), selection)
            session.redo(); coordinator.load()
            XCTAssertEqual(view.string, "第一段\n第新的文字段\n第三段")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 0))
        }
    }

    @MainActor func testContinuousTypingStaysOneUndoGroupAndRestoresBothHistorySelections() throws {
        try withEditor { session, view, coordinator in
            let selection = NSRange(location: 4, length: 3)
            view.setSelectedRange(selection)
            session.undoManager.beginUndoGrouping()
            view.insertText("甲", replacementRange: view.selectedRange())
            view.insertText("乙", replacementRange: view.selectedRange())
            session.undoManager.endUndoGrouping()
            XCTAssertEqual(view.string, "第一段\n甲乙\n第三段")
            session.undo(); coordinator.load()
            XCTAssertEqual(view.string, "第一段\n第二段\n第三段")
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertFalse(session.undoManager.canUndo)
            session.redo(); coordinator.load()
            XCTAssertEqual(view.string, "第一段\n甲乙\n第三段")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
        }
    }

    @MainActor func testReadingScaleReloadKeepsTheCurrentSelectionAfterHistoryWasConsumed() throws {
        try withEditor { session, view, coordinator in
            view.setSelectedRange(NSRange(location: 4, length: 3))
            session.undoManager.beginUndoGrouping(); view.toggleList("bullet"); session.undoManager.endUndoGrouping()
            session.undo(); coordinator.load()
            let current = NSRange(location: 0, length: 2)
            view.setSelectedRange(current)
            view.readingScale = 1.33; coordinator.load()
            XCTAssertEqual(view.selectedRange(), current)
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "第一")
        }
    }

    @MainActor func testTitleUndoRedoKeepsTitleHistoryAndTheCurrentBodySelection() throws {
        try withEditor { session, view, coordinator in
            let selection = NSRange(location: 4, length: 3)
            view.setSelectedRange(selection)
            session.undoManager.beginUndoGrouping(); session.changeTitle("新标题"); session.undoManager.endUndoGrouping()
            session.undo(); coordinator.load()
            XCTAssertEqual(session.note.title, "原标题")
            XCTAssertEqual(view.selectedRange(), selection)
            session.redo(); coordinator.load()
            XCTAssertEqual(session.note.title, "新标题")
            XCTAssertEqual(view.selectedRange(), selection)
        }
    }
}
