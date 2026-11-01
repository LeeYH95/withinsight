import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class ImagePreviewTests: XCTestCase {
    @MainActor func testFitKeepsPortraitAndPanoramaInsideTheActualNativeViewport() throws {
        for dimensions in [NSSize(width: 1200, height: 2400), NSSize(width: 4000, height: 1000)] {
            let (window, canvas) = makeCanvas(image: NSImage(size: dimensions), size: NSSize(width: 640, height: 480))
            defer { window.orderOut(nil) }
            let displayed = canvas.imageFrameInViewport
            XCTAssertEqual(displayed.width / displayed.height, dimensions.width / dimensions.height, accuracy: 0.001)
            XCTAssertTrue(canvas.contentView.frame.insetBy(dx: -0.5, dy: -0.5).contains(displayed), "Fit must show every edge of a tall or wide attachment")
            XCTAssertEqual(displayed.midX, canvas.contentView.frame.midX, accuracy: 1)
            XCTAssertEqual(displayed.midY, canvas.contentView.frame.midY, accuracy: 1)

            window.setContentSize(NSSize(width: 460, height: 360))
            canvas.layoutSubtreeIfNeeded()
            XCTAssertTrue(canvas.fitted)
            XCTAssertTrue(canvas.contentView.frame.insetBy(dx: -0.5, dy: -0.5).contains(canvas.imageFrameInViewport), "An already fitted image must refit after the sheet shrinks")
        }
    }

    @MainActor func testActualSizeUsesImagePixelsRatherThanFileDPIAndDoubleClickReturnsToFit() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 300, height: 200) // A high-DPI file must still expose all 1200 × 800 pixels.
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        let (window, canvas) = makeCanvas(image: image, size: NSSize(width: 500, height: 360))
        defer { window.orderOut(nil) }
        XCTAssertTrue(canvas.fitted)
        canvas.toggleFit()
        XCTAssertFalse(canvas.fitted)
        XCTAssertEqual(canvas.magnification, 1, accuracy: 0.0001)
        XCTAssertEqual(canvas.imageFrameInViewport.width * window.backingScaleFactor, 1200, accuracy: 1)
        XCTAssertEqual(canvas.imageFrameInViewport.height * window.backingScaleFactor, 800, accuracy: 1)

        let beforePan = canvas.contentView.bounds.origin
        canvas.pan(by: NSSize(width: 80, height: 40))
        XCTAssertNotEqual(canvas.contentView.bounds.origin, beforePan, "Original-size content must be navigable without another window")
        canvas.toggleFit()
        XCTAssertTrue(canvas.fitted)
        XCTAssertTrue(canvas.contentView.frame.insetBy(dx: -0.5, dy: -0.5).contains(canvas.imageFrameInViewport))
    }

    @MainActor func testRepeatedZoomCommandsStayBoundedAndEscapeClosesOnlyThePreview() throws {
        let (window, canvas) = makeCanvas(image: NSImage(size: NSSize(width: 2400, height: 1600)), size: NSSize(width: 600, height: 420))
        defer { window.orderOut(nil) }
        var latest = NotesImagePreviewStatus()
        canvas.statusChanged = { latest = $0 }
        for _ in 0..<50 { canvas.perform(.zoomIn) }
        XCTAssertEqual(canvas.magnification, 8, accuracy: 0.0001)
        XCTAssertFalse(latest.canZoomIn)
        for _ in 0..<100 { canvas.perform(.zoomOut) }
        XCTAssertEqual(canvas.magnification, 0.1, accuracy: 0.0001)
        XCTAssertFalse(latest.canZoomOut)
        canvas.perform(.fit)
        let beforePan = canvas.contentView.bounds.origin
        canvas.pan(by: NSSize(width: 10_000, height: -10_000))
        XCTAssertEqual(canvas.contentView.bounds.origin, beforePan, "Dragging a fitted image should leave it centered")
        var closed = false
        canvas.close = { closed = true }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)
        XCTAssertTrue(closed)
    }

    @MainActor func testControlCCopiesFromTheFocusedNativeImageCanvas() throws {
        let (window, canvas) = makeCanvas(image: NSImage(size: NSSize(width: 1200, height: 800)), size: NSSize(width: 600, height: 420))
        defer { window.orderOut(nil) }
        var copied = false
        canvas.copyImage = { copied = true }
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        canvas.keyDown(with: copy)
        XCTAssertTrue(copied, "Control+C must reach the same attachment-copy action as the visible copy button")
    }

    @MainActor func testLightAndDarkPreviewVisualEvidenceContainsTheNativeImageCanvas() async throws {
        guard let folder = ProcessInfo.processInfo.environment["SHIPIAN_EDITOR_QA_ROOT"] else {
            throw XCTSkip("Visual evidence is opt-in through SHIPIAN_EDITOR_QA_ROOT on the verified external SSD")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard output.path.hasPrefix("/Volumes/ZERO_SSD/Development/shipian/") else {
            XCTFail("Preview evidence must use the project's external SSD output root")
            return
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixture = sampleImage()
        for (label, scheme, appearanceName) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let host = NSHostingView(rootView: NotesImagePreview(name: "合成验收素材 · Synthetic fixture.png", image: fixture, copy: {}, export: {}, close: {})
                .environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: appearanceName)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Let SwiftUI publish the native canvas's fitted zoom before capture.
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var skySamples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.greenComponent > color.redComponent + 0.10,
                       color.blueComponent > color.redComponent + 0.15 {
                        skySamples += 1
                    }
                }
            }
            XCTAssertGreaterThan(skySamples, 100, "Evidence must include the drawn sample image, not an empty native viewport")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("image-preview-\(label).png"), options: .atomic)
        }
    }

    @MainActor func testSheetHasABoundedNativeSizeAndMissingImagesKeepAUsableContainer() {
        _ = NSApplication.shared
        let smallScreen = NotesImagePreviewSizing.preferredSize(available: NSSize(width: 800, height: 600))
        XCTAssertEqual(smallScreen, NSSize(width: 720, height: 520))
        let largeScreen = NotesImagePreviewSizing.preferredSize(available: NSSize(width: 5120, height: 2880))
        XCTAssertEqual(largeScreen, NSSize(width: 840, height: 620), "A high-resolution image or display must not create a giant sheet")

        for image in [nil, NSImage(size: NSSize(width: 20_000, height: 2000))] as [NSImage?] {
            let host = NSHostingView(rootView: NotesImagePreview(name: "Fixture image.png", image: image, copy: {}, export: {}, close: {}))
            let size = host.fittingSize
            XCTAssertGreaterThan(size.width, 400)
            XCTAssertGreaterThan(size.height, 300)
            XCTAssertLessThanOrEqual(size.width, 840)
            XCTAssertLessThanOrEqual(size.height, 620)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, size)
            window.orderOut(nil)
        }
    }

    @MainActor private func makeCanvas(image: NSImage, size: NSSize) -> (NSWindow, NotesImagePreviewCanvas) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = NotesImagePreviewCanvas(frame: NSRect(origin: .zero, size: size))
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        canvas.configure(image: image, name: "Fixture image")
        canvas.layoutSubtreeIfNeeded()
        return (window, canvas)
    }

    @MainActor private func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 960, height: 640), flipped: false) { bounds in
            NSColor(srgbRed: 0.64, green: 0.80, blue: 0.88, alpha: 1).setFill()
            bounds.fill()
            NSColor(srgbRed: 0.99, green: 0.77, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 692, y: 386, width: 112, height: 112)).fill()
            let distant = NSBezierPath()
            distant.move(to: NSPoint(x: 0, y: 190))
            distant.line(to: NSPoint(x: 260, y: 440))
            distant.line(to: NSPoint(x: 530, y: 170))
            distant.line(to: NSPoint(x: 720, y: 350))
            distant.line(to: NSPoint(x: 960, y: 180))
            distant.line(to: NSPoint(x: 960, y: 0))
            distant.line(to: .zero)
            distant.close()
            NSColor(srgbRed: 0.40, green: 0.57, blue: 0.56, alpha: 1).setFill()
            distant.fill()
            let near = NSBezierPath()
            near.move(to: .zero)
            near.line(to: NSPoint(x: 0, y: 100))
            near.curve(to: NSPoint(x: 960, y: 160), controlPoint1: NSPoint(x: 300, y: 340), controlPoint2: NSPoint(x: 700, y: 5))
            near.line(to: NSPoint(x: 960, y: 0))
            near.close()
            NSColor(srgbRed: 0.23, green: 0.41, blue: 0.39, alpha: 1).setFill()
            near.fill()
            ("SYNTHETIC FIXTURE" as NSString).draw(at: NSPoint(x: 38, y: 560), withAttributes: [
                .font: NSFont.systemFont(ofSize: 27, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.17, green: 0.30, blue: 0.36, alpha: 1)
            ])
            ("Native image preview · 960 × 640 · no personal content" as NSString).draw(at: NSPoint(x: 38, y: 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white
            ])
            return true
        }
    }
}
