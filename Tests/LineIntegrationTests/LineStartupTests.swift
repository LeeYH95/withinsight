import AppKit
import XCTest
@testable import Tendedero

final class LineStartupTests: XCTestCase {
    @MainActor func testUnavailableImageKeepsPositionAndRemovedImageStaysRemoved() async throws {
        let suite = "local.shipian.restart-order." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unavailable = folder.appendingPathComponent("unavailable.png")
        let available = folder.appendingPathComponent("available.png")
        try Data([0]).write(to: available)
        let first = UUID(), second = UUID()
        let order = ["note:" + first.uuidString, "note:" + second.uuidString,
                     "image:" + unavailable.path, "image:" + available.path]
        defaults.set([unavailable.path, available.path], forKey: "pegged")
        defaults.set(order, forKey: "mixedLineOrder")
        let line = Line(restoring: false, gusts: false, defaults: defaults)
        await line.restorePhotos { _ in NSImage(size: NSSize(width: 8, height: 8)) }
        line.hangNote(first, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        line.hangNote(second, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        line.restoreOrdering()
        XCTAssertEqual(defaults.stringArray(forKey: "mixedLineOrder"), order)
        let loaded = try XCTUnwrap(line.items.first { $0.url == available })
        line.drop(loaded.id, quietly: true, animated: false)
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [unavailable.path], "An explicitly removed image must stay removed")
        XCTAssertEqual(defaults.stringArray(forKey: "mixedLineOrder"), Array(order.dropLast()))
    }

    @MainActor func testSavedImagesSurviveWritesDuringSlowRestore() async throws {
        let suite = "local.shipian.restart-race." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("slow.png")
        try Data([0]).write(to: imageURL)
        defaults.set([imageURL.path], forKey: "pegged")
        defaults.set(["image:" + imageURL.path], forKey: "mixedLineOrder")
        let line = Line(restoring: false, gusts: false, defaults: defaults)
        let restoration = Task { @MainActor in
            await line.restorePhotos { _ in
                Thread.sleep(forTimeInterval: 0.25)
                return NSImage(size: NSSize(width: 8, height: 8))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        line.hangNote(UUID(), thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [imageURL.path], "A write while loading must not erase the saved image")
        await restoration.value
        line.restoreOrdering()
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [imageURL.path])
    }

    @MainActor func testTemporaryImageLoadFailureDoesNotEraseRopeStateOnRestart() async throws {
        let suite = "local.shipian.restart-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("image.png")
        try Data([0]).write(to: imageURL)
        let noteID = UUID()
        let order = ["image:" + imageURL.path, "note:" + noteID.uuidString]
        defaults.set([imageURL.path], forKey: "pegged")
        defaults.set(order, forKey: "mixedLineOrder")

        let firstLaunch = Line(restoring: false, gusts: false, defaults: defaults)
        await firstLaunch.restorePhotos { _ in nil }
        firstLaunch.hangNote(noteID, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        firstLaunch.restoreOrdering()
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [imageURL.path], "A temporary decode failure must not erase a saved image")
        XCTAssertEqual(defaults.stringArray(forKey: "mixedLineOrder"), order, "The original position must survive a failed load")

        let nextLaunch = Line(restoring: false, gusts: false, defaults: defaults)
        await nextLaunch.restorePhotos { _ in NSImage(size: NSSize(width: 8, height: 8)) }
        nextLaunch.hangNote(noteID, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        nextLaunch.restoreOrdering()
        XCTAssertEqual(nextLaunch.items.count, 2)
        XCTAssertEqual(nextLaunch.items.first?.url, imageURL, "The image must return to its original position after it becomes readable")
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [imageURL.path])
    }

    @MainActor func testSlowRestoredScreenshotsKeepMainActorResponsiveAndPreserveCapacity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["first.png", "second.png"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data([0]).write(to: url) }
        let line = Line(restoring: false, gusts: false)
        line.maxItems = 1
        let reads = StartupReads()
        var responsive = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            responsive = true
        }
        await line.restorePhotos(paths: [urls[0].path, urls[0].path, folder.appendingPathComponent("missing.png").path, urls[1].path]) { _ in
            reads.record()
            Thread.sleep(forTimeInterval: 0.15)
            return NSImage(size: NSSize(width: 40, height: 30))
        }
        XCTAssertTrue(responsive, "A slow restored screenshot must not prevent UI events during startup")
        XCTAssertEqual(reads.onMainThread, [false, false])
        XCTAssertEqual(line.items.map(\.url), urls, "Skip duplicate and missing paths while preserving saved order")
        XCTAssertEqual(line.liveCount, 2, "Restoring a wide screen must not evict old screenshots")
    }
}

private final class StartupReads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Bool] = []
    func record() { lock.lock(); reads.append(Thread.isMainThread); lock.unlock() }
    var onMainThread: [Bool] { lock.lock(); defer { lock.unlock() }; return reads }
}
