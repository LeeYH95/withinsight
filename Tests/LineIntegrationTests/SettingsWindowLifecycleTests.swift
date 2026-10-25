import AppKit
import NotesCore
import XCTest
@testable import Tendedero

private final class TooltipLifecycleFixtureWindow: NSWindow {
    // A pointer in the menu bar lies outside visibleFrame. The normal window
    // constraint would move this synthetic anchor out from under that pointer.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class SettingsWindowLifecycleTests: XCTestCase {
    @MainActor func testLeavingTooltipDoesNotDismissSettings() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = NotesWorkspace(store: try NotesStore(directory: directory))
        let pointer = NSEvent.mouseLocation
        let origin = TooltipLifecycleFixtureWindow(contentRect: NSRect(x:pointer.x-40,y:pointer.y-25,width:100,height:60),styleMask:[.borderless],backing:.buffered,defer:false)
        origin.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x:0,y:0,width:100,height:60))
        origin.contentView = anchor; origin.orderFront(nil)
        let tooltip = NotesTooltipPresenter.shared
        defer {
            tooltip.dismiss(); origin.orderOut(nil)
            _ = workspace
            NSApp.windows.filter { $0 is NotesWindow && $0.title == "闪念偏好设置" }.forEach { $0.orderOut(nil) }
        }
        tooltip.show("闪念偏好设置",from: anchor)
        XCTAssertTrue(tooltip.isPresented, "pointer=\(NSEvent.mouseLocation), originalPointer=\(pointer), frame=\(origin.frame), anchor=\(anchor.visibleRect), point=\(anchor.convert(origin.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)), visible=\(origin.isVisible)")
        workspace.showSettings()
        XCTAssertFalse(tooltip.isPresented,"Opening Preferences must dismiss a hint even when its source was not key")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // A tooltip's title can equal its label. Match the actual window type,
        // otherwise this test would mistake the temporary panel for Preferences.
        let settings = try XCTUnwrap(NSApp.windows.first { $0 is NotesWindow && $0.title == "闪念偏好设置" && $0.isVisible })
        tooltip.dismiss(ifAnchoredTo: anchor)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(settings.isVisible,"Leaving the gear's hover hint must not hide Preferences")
        XCTAssertNil(settings.parent)
        XCTAssertEqual(settings.alphaValue,1,accuracy:0.01)
    }

    @MainActor func testSettingsRepeatedOpenAndCloseReopen() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = NotesWorkspace(store: try NotesStore(directory: directory))
        workspace.showSettings()
        let window = try XCTUnwrap(NSApp.windows.first { $0 is NotesWindow && $0.title == "闪念偏好设置" && $0.isVisible })
        defer { window.orderOut(nil); _ = workspace }
        workspace.showSettings()
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        workspace.showSettings()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(window.isVisible,"A pending close animation must not hide reopened Preferences")
        XCTAssertEqual(window.alphaValue,1,accuracy:0.01)
    }
}
