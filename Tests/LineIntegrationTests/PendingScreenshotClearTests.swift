import AppKit
import XCTest
@testable import Tendedero

final class PendingScreenshotClearTests: XCTestCase {
    @MainActor private final class Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite = "local.shipian.pending-clear." + UUID().uuidString
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
            root = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func image(_ name: String) throws -> URL {
            let file = root.appendingPathComponent(name + ".png")
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: file)
            return file
        }
        func line(_ photos: [URL], order: [String]) -> Line {
            defaults.set(photos.map(\.path), forKey: "pegged")
            defaults.set(order, forKey: "mixedLineOrder")
            return Line(restoring: false, gusts: false, defaults: defaults)
        }
    }

    @MainActor func testClearAlsoRemovesUnreadablePhotosWithoutRemovingRecordingsOrFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("unreadable"), b = try f.image("loaded")
        let video = f.root.appendingPathComponent("recording.mov")
        try Data([1, 2, 3]).write(to: video)
        let note = UUID()
        let order = ["image:" + a.path, "note:" + note.uuidString, "image:" + b.path, "image:" + video.path]
        let line = f.line([a, b, video], order: order)
        await line.restorePhotos { $0 == b ? NSImage(size: NSSize(width: 8, height: 8)) : nil }
        line.hangNote(note, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        line.restoreOrdering()
        XCTAssertEqual(line.clearableScreenshotCount, 2)
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [video.path])
        XCTAssertEqual(line.screenshotClearUndoCount, 2)
        XCTAssertEqual(line.items.compactMap(\.noteID), [note])
        for file in [a, b, video] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        let restarted = Line(restoring: false, gusts: false, defaults: f.defaults)
        await restarted.restorePhotos { _ in NSImage(size: NSSize(width: 8, height: 8)) }
        XCTAssertEqual(restarted.items.map(\.url), [video], "A recovered decoder must not resurrect explicitly cleared photos")
    }

    @MainActor func testUndoRestoresPendingOrderAndKeepsLaterCaptureAndRecording() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("unreadable"), b = try f.image("loaded"), later = try f.image("later")
        let video = f.root.appendingPathComponent("recording.mov")
        try Data([1]).write(to: video)
        let note = UUID()
        let order = ["image:" + a.path, "note:" + note.uuidString, "image:" + b.path, "image:" + video.path]
        let line = f.line([a, b, video], order: order)
        await line.restorePhotos { $0 == b ? NSImage(size: NSSize(width: 8, height: 8)) : nil }
        line.hangNote(note, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        line.restoreOrdering()
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        XCTAssertNotNil(line.hang(later, quietly: true))
        line.finishScreenshotClear(batch.id)
        XCTAssertEqual(line.undoScreenshotClear(), 2)
        XCTAssertEqual(f.defaults.stringArray(forKey: "mixedLineOrder"), order + ["image:" + later.path])
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [a.path, b.path, video.path, later.path])
    }

    @MainActor func testClearDuringLoadRejectsACompletionAfterTheBatchHasFinished() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("slow")
        let line = f.line([a], order: ["image:" + a.path])
        let load = Task { @MainActor in
            await line.restorePhotos { _ in Thread.sleep(forTimeInterval: 0.25); return NSImage(size: NSSize(width: 8, height: 8)) }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(line.clearableScreenshotCount, 1, "Pending-only screenshots must be clearable")
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        line.finishScreenshotClear(batch.id)
        await load.value
        line.restoreOrdering()
        XCTAssertTrue(line.items.isEmpty)
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    @MainActor func testUndoBeforeTheInFlightLoadCompletesRestoresItsMembership() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("slow")
        let line = f.line([a], order: ["image:" + a.path])
        let load = Task { @MainActor in
            await line.restorePhotos { _ in Thread.sleep(forTimeInterval: 0.25); return NSImage(size: NSSize(width: 8, height: 8)) }
        }
        try await Task.sleep(for: .milliseconds(50))
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        line.finishScreenshotClear(batch.id)
        XCTAssertEqual(line.undoScreenshotClear(), 1)
        await load.value
        line.restoreOrdering()
        XCTAssertEqual(line.items.map(\.url), [a])
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [a.path])
    }

    @MainActor func testExpiredUndoDoesNotReviveAStillLoadingPhoto() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("slow")
        let line = f.line([a], order: ["image:" + a.path])
        let load = Task { @MainActor in
            await line.restorePhotos { _ in Thread.sleep(forTimeInterval: 3.4); return NSImage(size: NSSize(width: 8, height: 8)) }
        }
        try await Task.sleep(for: .milliseconds(50))
        line.requestScreenshotClear()
        XCTAssertEqual(line.screenshotClearUndoCount, 1)
        await load.value
        XCTAssertEqual(line.screenshotClearUndoCount, 0)
        XCTAssertTrue(line.items.isEmpty)
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [])
    }

    @MainActor func testRehangingTheSamePendingFileKeepsTheNewCardWithoutDuplicateUndo() async throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.image("unreadable"), b = try f.image("loaded")
        let line = f.line([a, b], order: ["image:" + a.path, "image:" + b.path])
        await line.restorePhotos { $0 == b ? NSImage(size: NSSize(width: 8, height: 8)) : nil }
        line.restoreOrdering()
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        let newID = try XCTUnwrap(line.hang(a, quietly: true))
        line.finishScreenshotClear(batch.id)
        XCTAssertEqual(line.items.map(\.id), [newID], "The new membership is outside the clear snapshot")
        XCTAssertEqual(line.undoScreenshotClear(), 1, "Do not add a second reference for an already rehung pending file")
        XCTAssertEqual(line.items.filter { $0.url == a }.count, 1)
        XCTAssertEqual(Set(f.defaults.stringArray(forKey: "pegged") ?? []), [a.path, b.path])
    }
}
