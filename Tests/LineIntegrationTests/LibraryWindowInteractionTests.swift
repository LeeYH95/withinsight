import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class LibraryWindowInteractionTests: XCTestCase {
    @MainActor private func fixture() throws -> (NotesWorkspace, NSWindow) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-window-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let name = "NSWindow Frame NotesLibraryWindow-compact-v1"
        let previous = UserDefaults.standard.object(forKey: name)
        UserDefaults.standard.removeObject(forKey: name)
        addTeardownBlock { if let previous { UserDefaults.standard.set(previous, forKey: name) } else { UserDefaults.standard.removeObject(forKey: name) } }
        let workspace = NotesWorkspace(store: try NotesStore(directory: directory))
        workspace.showLibrary()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let window = try XCTUnwrap(NSApp.windows.first { $0 is NotesWindow && $0.title == "全部闪念" && $0.isVisible })
        return (workspace, window)
    }

    @MainActor private func isDragHit(_ point: NSPoint, in window: NSWindow) throws -> Bool {
        let content = try XCTUnwrap(window.contentView)
        // NSView.hitTest takes coordinates in the receiver's superview, not
        // the flipped NSHostingView's own coordinate system.
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let candidate = view {
            if String(describing: type(of: candidate)).contains("NotesDragView") { return true }
            view = candidate.superview
        }
        return false
    }

    @MainActor func testDefaultLibraryUsesCompactSize() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        let visible = try XCTUnwrap(window.screen).visibleFrame
        XCTAssertEqual(window.frame.width, min(820, visible.width), accuracy: 1)
        XCTAssertEqual(window.frame.height, min(560, visible.height), accuracy: 1)
    }

    @MainActor func testHeaderAndFilterWhitespaceDragWithoutCoveringControls() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        window.setContentSize(NSSize(width: 820, height: 560))
        XCTAssertTrue(window.isMovable, "A borderless library must permit native window dragging")
        window.contentView?.layoutSubtreeIfNeeded()
        let height = window.contentView!.bounds.height
        XCTAssertTrue(try isDragHit(NSPoint(x: 330, y: height - 60), in: window), "Title-row whitespace must drag beyond the old top 24pt")
        XCTAssertTrue(try isDragHit(NSPoint(x: 450, y: height - 118), in: window), "Filter-row whitespace must drag")
        XCTAssertFalse(try isDragHit(NSPoint(x: 650, y: height - 50), in: window), "New Note remains clickable")
        XCTAssertFalse(try isDragHit(NSPoint(x: 665, y: height - 113), in: window), "Search remains editable")
    }

    @MainActor func testWindowCanShrinkAndReopenWithoutResettingManualFrame() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        let requested = NSRect(x: window.frame.minX + 10, y: window.frame.minY + 20, width: 680, height: 460)
        window.setFrame(requested, display: true)
        window.performClose(nil); workspace.showLibrary()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(window.frame.width, 680, accuracy: 1)
        XCTAssertEqual(window.frame.height, 460, accuracy: 1)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor func testWholeTopAreaDragsAndWholeSearchBoxIsExcluded() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        window.contentView?.layoutSubtreeIfNeeded()
        let height = window.contentView!.bounds.height
        // Include title text, both outer margins, the inter-row gap and the
        // padding below tabs. These are the full two rows in the approved UI.
        for (x, top) in [(40.0, 38.0), (150, 38), (15, 65), (400, 12),
                         (400, 72), (450, 92), (15, 110), (800, 118), (400, 125)] {
            XCTAssertTrue(try isDragHit(NSPoint(x: x, y: height - top), in: window), "Blank/title at \(x),\(top) must drag")
        }
        for (x, top) in [(555.0, 90.0), (560, 105), (580, 110), (775, 108), (778, 80),
                         (600, 40), (735, 40), (770, 40), (75, 95)] {
            XCTAssertFalse(try isDragHit(NSPoint(x: x, y: height - top), in: window), "Control at \(x),\(top) must never drag")
        }
    }

    @MainActor func testDragStartsOnFirstPressAndTracksThePointerWithoutClickActions() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        let content = try XCTUnwrap(window.contentView)
        let point = NSPoint(x: 330, y: content.bounds.height - 60)
        let hit = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point))
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "Dragging an inactive library must work on the first press")
        let before = window.frame
        func event(_ type: NSEvent.EventType, at screen: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let start = window.convertPoint(toScreen: point)
        hit.mouseDown(with: try event(.leftMouseDown, at: start))
        XCTAssertEqual(window.frame, before, "A click alone must not move the window")
        hit.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: start.x + 60, y: start.y - 30)))
        XCTAssertEqual(window.frame.minX, before.minX + 60, accuracy: 1)
        XCTAssertEqual(window.frame.minY, before.minY - 30, accuracy: 1)
        // The second event is relative to the moved window: avoid accumulating
        // window movement into the pointer delta and making the window jump.
        let end = NSPoint(x: start.x + 90, y: start.y - 45)
        hit.mouseDragged(with: try event(.leftMouseDragged, at: end))
        XCTAssertEqual(window.frame.minX, before.minX + 90, accuracy: 1)
        XCTAssertEqual(window.frame.minY, before.minY - 45, accuracy: 1)
        hit.mouseUp(with: try event(.leftMouseUp, at: end))
        let released = window.frame
        hit.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: end.x + 50, y: end.y)))
        XCTAssertEqual(window.frame, released, "Released drag must not keep moving")
    }

    @MainActor func testLibraryHasInvisibleRightBottomAndCornerResizeRegions() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        let content = try XCTUnwrap(window.contentView)
        for point in [NSPoint(x: 817, y: 280), NSPoint(x: 400, y: 3), NSPoint(x: 805, y: 15)] {
            let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            XCTAssertTrue(hit is NotesEditorResizeHandle.Handle, "Resize edge must use the existing invisible native handle: \(point)")
        }
    }

    @MainActor func testResizeTracksNativeEventsAndKeepsTheTopEdgeFixed() throws {
        let (workspace, window) = try fixture()
        defer { window.orderOut(nil); _ = workspace }
        let content = try XCTUnwrap(window.contentView)
        let point = NSPoint(x: 805, y: 15)
        let hit = try XCTUnwrap(content.hitTest(content.superview?.convert(point, from: nil) ?? point) as? NotesEditorResizeHandle.Handle)
        let before = window.frame, start = window.convertPoint(toScreen: point)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(hit.acceptsFirstMouse(for: nil))
        guard hit.acceptsFirstMouse(for: nil) else { return }
        hit.mouseDown(with: try event(.leftMouseDown, start))
        let end = NSPoint(x: start.x - 100, y: start.y + 75)
        hit.mouseDragged(with: try event(.leftMouseDragged, end))
        XCTAssertEqual(window.frame.width, before.width - 100, accuracy: 1)
        XCTAssertEqual(window.frame.height, before.height - 75, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 1)
        hit.mouseUp(with: try event(.leftMouseUp, end))
    }
}
