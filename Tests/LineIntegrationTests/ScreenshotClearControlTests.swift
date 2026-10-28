import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class ScreenshotClearControlTests: XCTestCase {
    @MainActor func testEmptyControlKeepsNativeHitTargetAndExplainsDisabledState() throws {
        _ = NSApplication.shared
        let line = Line(restoring: false, gusts: false)
        let host = NSHostingView(rootView: ScreenshotClearControl(line: line))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: LineControl.hangingHeight)
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(buttons(host).first)
        XCTAssertEqual(button.frame.size, LineControl.targetSize)
        XCTAssertEqual(button.accessibilityIdentifier(), "line.clearScreenshots")
        XCTAssertEqual(button.accessibilityLabel(), "取下全部截图")
        XCTAssertTrue(button.accessibilityHelp()?.contains("没有截图") == true)
        XCTAssertNil(button.toolTip)
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(button.accessibilityPerformPress())
        XCTAssertTrue(button.hitTest(NSPoint(x: 20, y: 22)) === button)
    }

    @MainActor func testNativePressStartsOneSnapshotAndCanBeUndone() throws {
        _ = NSApplication.shared
        let suite = "shipian-clear-control-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file); defaults.removePersistentDomain(forName: suite) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        let line = Line(restoring: false, gusts: false, defaults: defaults)
        line.hang(file, quietly: true)
        let host = NSHostingView(rootView: ScreenshotClearControl(line: line))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: LineControl.hangingHeight)
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(buttons(host).first)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.accessibilityHelp()?.contains("原文件") == true)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(line.screenshotClearUndoCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(line.undoScreenshotClear(), 1)
        XCTAssertEqual(line.items.filter { !$0.falling }.map(\.url), [file])
    }

    @MainActor func testApprovedArtworkLoadsWithTransparentCompactBounds() throws {
        let picture = try XCTUnwrap(LineControlImages.picture)
        let pole = try XCTUnwrap(LineControlImages.pole)
        XCTAssertGreaterThan(picture.size.width / picture.size.height, 1)
        XCTAssertLessThan(picture.size.width / picture.size.height, 1.5)
        XCTAssertGreaterThan(pole.size.width / pole.size.height, 5)
        XCTAssertLessThan(pole.size.width / pole.size.height, 8)
        XCTAssertTrue(try XCTUnwrap(pole.cgImage(forProposedRect: nil, context: nil, hints: nil)).alphaInfo != .none)
    }

    @MainActor private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
}
