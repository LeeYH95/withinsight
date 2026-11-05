import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class EditorImageInteractionTests: XCTestCase {
    @MainActor func testWholeImageIncludingItsRightHalfShowsHandAndOpensTheSamePreview() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-hit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let image = NoteAttachment(name: "fixture.png", relativePath: "attachments/fixture.png", kind: .image, byteCount: 1)
        var note = try store.create(); note.attachments = [image]
        note.blocks = [NoteBlock(kind: .image, text: image.name, attachmentID: image.id), NoteBlock(text: "图片之后的文字")]
        let session = NotesEditorSession(note: note, store: store)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        view.session = session; session.textView = view
        view.imageProvider = { _ in NSImage(size: NSSize(width: 640, height: 360)) }
        view.loadDocument(note)
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 600, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertGreaterThan(rect.width, 200); XCTAssertGreaterThan(rect.height, 100)
        var opened: [UUID] = []; view.onAttachment = { opened.append($0.id) }
        for x: CGFloat in [0.1, 0.5, 0.9] {
            for y: CGFloat in [0.1, 0.5, 0.9] {
                let point = NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
                XCTAssertEqual(view.interactionCursor(at: point, modifiers: []), .pointingHand, "Image point \(x),\(y)")
                let location = view.convert(point, to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                NSApp.postEvent(up, atStart: true); view.mouseDown(with: down)
                XCTAssertEqual(opened.last, image.id)
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            }
        }
        XCTAssertEqual(opened.count, 9, "Every visible region must open exactly once")
        let location = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let controlClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: .control,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        view.mouseDown(with: controlClick)
        defer { NotesMenuPresenter.shared.dismiss(animated: false) }
        XCTAssertEqual(opened.count, 9, "Control-click must show image actions instead of opening a second preview")
        XCTAssertTrue(NotesMenuPresenter.shared.isPresented)
        XCTAssertEqual(NotesMenuPresenter.shared.navigator?.items.first?.title, "放大图片")
        NotesMenuPresenter.shared.dismiss(animated: false)
        session.change("待办点击验收") { $0.blocks = [NoteBlock(kind: .checklist, text: "不要因 Control 点击被勾选")] }
        view.loadDocument(session.note); manager.ensureLayout(for: container)
        let box = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let checkboxPoint = view.convert(NSPoint(x: box.midX + view.textContainerOrigin.x, y: box.midY + view.textContainerOrigin.y), to: nil)
        let checkboxControl = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: checkboxPoint, modifierFlags: .control,
            timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        view.mouseDown(with: checkboxControl)
        XCTAssertEqual(view.attributedString().attribute(.notesChecked, at: 0, effectiveRange: nil) as? Bool, false)
        XCTAssertTrue(NotesMenuPresenter.shared.isPresented, "Control-click on a checkbox must offer text actions without toggling it")
    }
}
