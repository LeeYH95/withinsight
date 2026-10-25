import AppKit
import XCTest
@testable import Tendedero

final class LineWindowOrderingTests: XCTestCase {
    @MainActor private func noteWindow(_ title: String) -> NSWindow {
        let window = NotesWorkspace.makeWindow(title: title, size: NSSize(width: 500, height: 400), minimum: NSSize(width: 300, height: 200))
        window.orderFront(nil)
        return window
    }

    @MainActor func testForegroundResolutionHandlesLibrarySettingsSheetsAndMenus() throws {
        _ = NSApplication.shared
        let library = noteWindow("库验收"), settings = noteWindow("设置验收")
        let menu = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        defer { library.orderOut(nil); settings.orderOut(nil); menu.orderOut(nil) }
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: library, main: library, active: true) === library)
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: settings, main: settings, active: true) === settings)
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: menu, main: library, active: true) === library)
        XCTAssertNil(LinePanel.foregroundNotesWindow(key: library, main: library, active: false))
        library.orderOut(nil)
        XCTAssertNil(LinePanel.foregroundNotesWindow(key: library, main: library, active: true))
    }

    @MainActor func testRopeStaysBehindNormalAndPinnedWindowsWithoutChangingTheirLevels() throws {
        _ = NSApplication.shared
        let window = noteWindow("前台窗口验收")
        let rope = LinePanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)))
        rope.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY + 200, width: 800, height: 300), display: false)
        defer { rope.orderOut(nil); window.orderOut(nil) }
        for baseLevel in [NSWindow.Level.normal, .floating] {
            window.level = baseLevel
            for _ in 0..<3 {
                rope.orderBehindNotesWindow(window)
                XCTAssertEqual(rope.level, baseLevel)
                XCTAssertEqual(window.level, baseLevel)
                // NSApp.orderedWindows omits nonactivating/ignoresCycle panels.
                // The WindowServer list includes our rope in actual z-order.
                let ordered = NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
                XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: window.windowNumber)), try XCTUnwrap(ordered.firstIndex(of: rope.windowNumber)))
            }
        }
        rope.orderBehindNotesWindow(nil)
        XCTAssertEqual(rope.level, .floating)
    }

    @MainActor func testSheetUsesOwningNotesWindowForRopeOrder() throws {
        _ = NSApplication.shared
        let library = noteWindow("确认框验收")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { if library.attachedSheet != nil { library.endSheet(sheet) }; sheet.orderOut(nil); library.orderOut(nil) }
        library.beginSheet(sheet)
        XCTAssertTrue(LinePanel.foregroundNotesWindow(key: sheet, main: library, active: true) === library)
    }
}
