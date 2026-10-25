import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class ContinuousBlankFocusTests: XCTestCase {
    @MainActor func testEmptyBodyHitTestingReachesTextViewAfterEditingTitle() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-blank-focus-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let workspace = NotesWorkspace(store: store)
        let note = NoteDocument(title: "空白焦点验收", blocks: [NoteBlock(text: "")])
        let controller = NotesEditorController(note: note, workspace: workspace)
        let window = try XCTUnwrap(controller.window)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let body = try XCTUnwrap(controller.session.textView)
        let content = try XCTUnwrap(window.contentView)
        let title = try XCTUnwrap(controller.session.titleField)
        window.makeFirstResponder(title)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let blank = NSPoint(x: body.bounds.midX, y: body.bounds.height * 0.65)
        let hit = content.hitTest(body.convert(blank, to: content))
        XCTAssertTrue(hit === body || hit?.isDescendant(of: body) == true,"The visible blank body must receive a click instead of leaving focus in the title")
        let location = body.convert(blank, to: nil)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        XCTAssertTrue(window.firstResponder === body,"Clicking empty body must move typing focus away from the title")
    }
}
