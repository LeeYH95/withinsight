import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Tendedero

final class ClipboardWatcherTests: XCTestCase {
    @MainActor func testPollingDetectsNewImagesWithoutManualCheck() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red)])
        let deadline = Date().addingTimeInterval(3)
        while f.received.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.received.count, 1)
    }

    @MainActor func testCopiedFeedbackFitsNativeLightAndDarkLayouts() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red), f.item(.blue)]); f.watcher.check(); try await f.finish()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: CopiedImagesResult(line: f.line))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            XCTAssertLessThan(size.width, 320)
            XCTAssertGreaterThan(size.width, 100)
            XCTAssertLessThan(size.height, 60)
            let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            defer { window.orderOut(nil) }
            if let output = ProcessInfo.processInfo.environment["SHIPIAN_CLIPBOARD_QA_ROOT"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let folder = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("copied-feedback-\(name).png"))
            }
        }
    }

    @MainActor func testFinderPhotoPreservesItsDisplayOrientation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let image = try XCTUnwrap(NSBitmapImageRep(data: f.image(.red))?.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 12, height: 8)))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = f.root.appendingPathComponent("portrait.jpg")
        try (jpeg as Data).write(to: file)
        let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL)
        f.write([item]); f.watcher.check(); try await f.finish()
        let result = try XCTUnwrap(f.received.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: result)))
        XCTAssertEqual(bitmap.pixelsWide, 8)
        XCTAssertEqual(bitmap.pixelsHigh, 12)
        XCTAssertEqual(try Data(contentsOf: file), jpeg as Data)
    }

    @MainActor func testFinderBatchKeepsOrderAndOriginalFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let files = try [NSColor.red, .blue, .green].enumerated().map { index, color in
            let url = f.root.appendingPathComponent("original-\(index).png")
            try f.image(color).write(to: url)
            return url
        }
        let originals = try files.map { try Data(contentsOf: $0) }
        f.write(files.map { url in let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item })
        f.watcher.check()
        try await f.finish()
        XCTAssertEqual(f.batches.count, 1)
        XCTAssertEqual(f.received.count, 3)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, originals)
        for (index, url) in f.received.enumerated() {
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            let color = try XCTUnwrap(image.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan([color.redComponent, color.blueComponent, color.greenComponent][index], 0.9)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    @MainActor func testSuccessiveCapturedCopiesAreNotLostWhenClipboardChanges() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red)]); f.watcher.check()
        f.write([f.item(.blue)]); f.watcher.check()
        try await f.finish()
        XCTAssertEqual(f.batches.map(\.count), [1, 1])
        let colors = try f.received.map { try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: $0))?.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)) }
        guard colors.count == 2 else { return }
        XCTAssertGreaterThan(colors[0].redComponent, 0.9)
        XCTAssertGreaterThan(colors[1].blueComponent, 0.9)
    }

    @MainActor func testDeduplicationUsesLiveMembershipAndAllowsRehangingAfterClear() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red)]); f.watcher.check(); try await f.finish()
        let first = try XCTUnwrap(f.received.first)
        f.write([f.item(.red)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 1)
        f.line.requestScreenshotClear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        f.write([f.item(.red)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 2, "A retained image file must not prevent rehanging a cleared image")
        XCTAssertEqual(f.line.clearableScreenshotCount, 1)
    }

    @MainActor func testDuplicateRepresentationsAndItemsHangOnlyOnce() async throws {
        let f = try Fixture(); defer { f.clean() }
        let item = f.item(.red)
        item.setData(try XCTUnwrap(NSImage(data: f.image(.red))?.tiffRepresentation), forType: .tiff)
        f.write([item, f.item(.red)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 1)
    }

    @MainActor func testImageWithSourceURLIsAcceptedButDocumentFragmentsAreIgnored() async throws {
        let f = try Fixture(); defer { f.clean() }
        let image = f.item(.red); image.setString("https://example.com/photo", forType: .string)
        f.write([image]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 1)
        let text = f.item(.blue); text.setString("A copied paragraph", forType: .string)
        f.write([text]); f.watcher.check(); try await f.finish()
        let rich = f.item(.green); rich.setData(Data("{\\rtf1 text}".utf8), forType: .rtf)
        f.write([rich]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 1)
    }

    @MainActor func testSensitiveAndSelfCopiedImagesDoNotReenterTheLine() async throws {
        let f = try Fixture(); defer { f.clean() }
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", NotesEditorPasteboard.copiedImageType.rawValue] {
            let marked = f.item(.red); marked.setString("1", forType: .init(type))
            f.write([f.item(.blue), marked]); f.watcher.check(); try await f.finish()
        }
        XCTAssertTrue(f.received.isEmpty)
        f.board.clearContents()
        XCTAssertTrue(NotesEditorPasteboard.writeImage(f.image(.red), to: f.board))
        f.watcher.check(); try await f.finish()
        XCTAssertTrue(f.received.isEmpty)
    }

    @MainActor func testEnablingSkipsOldCopyAndStoppingCancelsPendingDelivery() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.watcher.stop(); f.write([f.item(.red)]); f.watcher.start()
        f.watcher.check(); try await f.finish()
        XCTAssertTrue(f.received.isEmpty)
        f.write([f.item(.blue)]); f.watcher.check(); f.watcher.stop()
        try await f.finish()
        XCTAssertTrue(f.received.isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: f.output.path)) ?? [], [])
        f.watcher.start(); f.write([f.item(.green)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.received.count, 1)
    }

    @MainActor func testNonImageFilesAndCorruptBytesAreIgnored() async throws {
        let f = try Fixture(); defer { f.clean() }
        let file = f.root.appendingPathComponent("document.txt")
        try Data("plain text".utf8).write(to: file)
        let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL)
        let corrupt = NSPasteboardItem(); corrupt.setData(Data("invalid image".utf8), forType: .png)
        f.write([item, corrupt]); f.watcher.check(); try await f.finish()
        XCTAssertTrue(f.received.isEmpty)
    }

    @MainActor func testUndoOnlyRemovesTheLastCopiedBatchAndPreservesFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red)]); f.watcher.check(); try await f.finish()
        let first = try XCTUnwrap(f.line.items.first?.id)
        f.write([f.item(.blue), f.item(.green)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.line.copiedImagesUndoIDs.count, 2)
        f.line.undoCopiedImages()
        XCTAssertEqual(f.line.items.filter { !$0.falling }.map(\.id), [first])
        XCTAssertTrue(f.received.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(f.line.copiedImagesUndoIDs.isEmpty)
    }

    @MainActor func testCopiedBatchUndoExpiresAfterThreeSeconds() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.write([f.item(.red)]); f.watcher.check(); try await f.finish()
        XCTAssertEqual(f.line.copiedImagesUndoIDs.count, 1)
        try await Task.sleep(for: .milliseconds(3250))
        XCTAssertTrue(f.line.copiedImagesUndoIDs.isEmpty)
        f.line.undoCopiedImages()
        XCTAssertEqual(f.line.clearableScreenshotCount, 1)
    }
}

@MainActor private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardWatcher-" + UUID().uuidString)
    let board = NSPasteboard.withUniqueName()
    let defaults: UserDefaults
    let suite = "Shipian.clipboard-tests." + UUID().uuidString
    let line: Line
    var batches: [[URL]] = []
    var received: [URL] { batches.flatMap { $0 } }
    var output: URL { root.appendingPathComponent("Clipboard", isDirectory: true) }
    lazy var watcher = ClipboardWatcher(board: board, folder: output, isHanging: { [weak self] url in
        self?.line.items.contains { $0.url == url && !$0.falling } == true
    }, onImages: { [weak self] urls in
        guard let self else { return }
        batches.append(urls)
        line.recordCopiedImages(urls.compactMap { self.line.hang($0, quietly: true) })
    })
    init() throws {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suite)!
        line = Line(restoring: false, gusts: false, defaults: defaults, inboxFolder: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        watcher.start()
    }
    func image(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = color.usingColorSpace(.deviceRGB)!
        for y in 0..<12 {
            for x in 0..<12 {
                let pixel = rep.bitmapData!.advanced(by: y * rep.bytesPerRow + x * 4)
                pixel[0] = UInt8((color.redComponent * 255).rounded())
                pixel[1] = UInt8((color.greenComponent * 255).rounded())
                pixel[2] = UInt8((color.blueComponent * 255).rounded())
                pixel[3] = 255
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }
    func item(_ color: NSColor) -> NSPasteboardItem {
        let item = NSPasteboardItem(); item.setData(image(color), forType: .png); return item
    }
    func write(_ items: [NSPasteboardItem]) { board.clearContents(); board.writeObjects(items) }
    func finish() async throws {
        let deadline = Date().addingTimeInterval(3)
        while watcher.isProcessing, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(watcher.isProcessing)
        // Allow worker cleanup of rejected duplicate or cancelled files.
        try await Task.sleep(for: .milliseconds(20))
    }
    func clean() {
        watcher.stop()
        defaults.removePersistentDomain(forName: suite)
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
}
