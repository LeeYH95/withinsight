import AppKit
import XCTest
@testable import Tendedero

final class LineMenuLifecycleTests: XCTestCase {
    @MainActor func testRopeMenuDoesNotLowerRopeBehindUnrelatedMainWindow() throws {
        _ = NSApplication.shared
        let library = NotesWorkspace.makeWindow(title: "独立菜单验收", size: NSSize(width: 600, height: 400), minimum: NSSize(width: 300, height: 200))
        library.orderFront(nil)
        let anchor = NSButton(frame: NSRect(x: 500, y: 150, width: 40, height: 44))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        content.addSubview(anchor)
        let rope = LinePanel(content: content)
        rope.setFrame(NSRect(x: 0, y: 500, width: 800, height: 300), display: false)
        rope.orderFrontRegardless()
        let presenter = NotesMenuPresenter.shared
        defer { presenter.dismiss(animated: false); rope.orderOut(nil); library.orderOut(nil) }
        presenter.show(LineControl.templateMenu(for: Line(restoring: false, gusts: false)), from: anchor)
        let popup = try XCTUnwrap(presenter.panel)
        XCTAssertTrue(popup.isVisible)
        let foreground = LinePanel.foregroundNotesWindow(key: popup, main: library, active: true)
        XCTAssertNil(foreground, "The rope's popup must not use an unrelated library as its owning window")
        rope.orderBehindNotesWindow(foreground)
        XCTAssertEqual(rope.level, .floating, "Opening the rope menu must retain its floating layer")
        let ordered = NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: popup.windowNumber)), try XCTUnwrap(ordered.firstIndex(of: rope.windowNumber)))
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: rope.windowNumber)), try XCTUnwrap(ordered.firstIndex(of: library.windowNumber)))
        if let path = ProcessInfo.processInfo.environment["SHIPIAN_MENU_QA_CAPTURE"], let view = popup.contentView {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        presenter.dismiss(animated: false)
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: library, main: library, active: true) === library,
                      "Normal notes-window ordering resumes after the rope menu closes")
    }

    @MainActor func testHidingRopeAlsoDismissesItsPopup() throws {
        _ = NSApplication.shared
        let anchor = NSButton(frame: NSRect(x: 500, y: 150, width: 40, height: 44))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        content.addSubview(anchor)
        let rope = LinePanel(content: content)
        rope.setFrame(NSRect(x: 0, y: 500, width: 800, height: 300), display: false)
        rope.orderFrontRegardless()
        let presenter = NotesMenuPresenter.shared
        defer { presenter.dismiss(animated: false); rope.orderOut(nil) }
        presenter.show(LineControl.templateMenu(for: Line(restoring: false, gusts: false)), from: anchor)
        let popup = try XCTUnwrap(presenter.panel)
        XCTAssertTrue(popup.isVisible)
        rope.orderOut(nil)
        XCTAssertFalse(presenter.isPresented, "A hidden rope must not leave its popup floating by itself")
        XCTAssertFalse(popup.isVisible)
    }

    @MainActor func testHidingRopePreservesMenuOwnedByNotesWindow() throws {
        _ = NSApplication.shared
        let library = NotesWorkspace.makeWindow(title: "库菜单验收", size: NSSize(width: 600, height: 400), minimum: NSSize(width: 300, height: 200))
        let anchor = NSButton(frame: NSRect(x: 200, y: 200, width: 40, height: 44))
        library.contentView?.addSubview(anchor)
        library.orderFront(nil)
        let rope = LinePanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)))
        rope.setFrame(NSRect(x: 0, y: 500, width: 800, height: 300), display: false)
        rope.orderFrontRegardless()
        let presenter = NotesMenuPresenter.shared
        defer { presenter.dismiss(animated: false); rope.orderOut(nil); library.orderOut(nil) }
        presenter.show(LineControl.templateMenu(for: Line(restoring: false, gusts: false)), from: anchor)
        let popup = try XCTUnwrap(presenter.panel)
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: popup, main: library, active: true) === library)
        rope.orderOut(nil)
        XCTAssertTrue(presenter.isPresented, "Hiding the rope must not dismiss an unrelated library menu")
        XCTAssertTrue(popup.isVisible)
        _ = presenter.handleKey(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        XCTAssertFalse(presenter.isPresented, "Escape still dismisses the notes menu")
    }

    @MainActor func testChoosingTemplateClosesPopupBeforeCreatingNote() throws {
        _ = NSApplication.shared
        let line = Line(restoring: false, gusts: false)
        let anchor = NSButton(frame: NSRect(x: 500, y: 150, width: 40, height: 44))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        content.addSubview(anchor)
        let rope = LinePanel(content: content)
        rope.setFrame(NSRect(x: 0, y: 500, width: 800, height: 300), display: false)
        rope.orderFrontRegardless()
        let presenter = NotesMenuPresenter.shared
        defer { presenter.dismiss(animated: false); rope.orderOut(nil) }
        var called: [String] = []
        line.onNewNote = { template in
            called.append(template)
            XCTAssertFalse(presenter.isPresented, "Dismiss before an editor changes window focus")
        }
        presenter.show(LineControl.templateMenu(for: line), from: anchor)
        let popup = try XCTUnwrap(presenter.panel)
        presenter.choose(1)
        XCTAssertEqual(called, ["checklist"])
        XCTAssertFalse(popup.isVisible)
    }
}
