import AppKit
import XCTest
@testable import Tendedero

final class ContextClickRoutingTests: XCTestCase {
    @MainActor private final class ContextTextView: NotesTextView {
        var received: [NSEvent.EventType] = []
        override func rightMouseDown(with event: NSEvent) { received.append(event.type) }
    }

    @MainActor func testWindowRoutesRightClickAndControlClickToTheTextViewsSpecializedHandler() throws {
        _ = NSApplication.shared
        let window = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ContextTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        defer { NotesMenuPresenter.shared.dismiss(animated: false); window.close() }
        for (type, flags) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 30, y: 30), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        XCTAssertEqual(view.received, [.rightMouseDown, .leftMouseDown], "The window must allow attachment-specific context actions to reach the native text view.")
    }
}
