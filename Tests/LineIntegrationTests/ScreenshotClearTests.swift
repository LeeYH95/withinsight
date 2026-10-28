import AppKit
import XCTest
@testable import Tendedero

final class ScreenshotClearTests: XCTestCase {
    @MainActor func testUndoBannerDoesNotExtendTheScrollableCardBand() throws {
        let f = try Fixture(); defer { f.clean() }
        f.line.visibleCount = 1
        let a = UUID(), b = UUID(), banner = UUID()
        f.line.hangNote(a, thumbnail: f.thumbnail(), quietly: true)
        f.line.hangNote(b, thumbnail: f.thumbnail(), quietly: true)
        f.line.hitRects = [a: CGRect(x: 100, y: 30, width: 80, height: 100),
                           b: CGRect(x: 300, y: 30, width: 80, height: 100),
                           banner: CGRect(x: 450, y: 210, width: 200, height: 30)]
        XCTAssertTrue(f.line.acceptsPointer(at: CGPoint(x: 240, y: 80)), "Gaps between overflowing cards still scroll")
        XCTAssertTrue(f.line.acceptsPointer(at: CGPoint(x: 500, y: 225)), "The undo banner itself stays clickable")
        XCTAssertFalse(f.line.acceptsPointer(at: CGPoint(x: 20, y: 225)), "Blank desktop beside undo must pass through")
    }

    @MainActor func testClearPreservesNotesAndOwnedAndExternalOriginalBytes() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.shot("owned", owned: true), b = try f.shot("external")
        let originals = try [a, b].map { try Data(contentsOf: $0) }
        f.line.hang(a, quietly: true)
        let note = UUID(); f.line.hangNote(note, thumbnail: f.thumbnail(), quietly: true)
        f.line.hang(b, quietly: true)
        XCTAssertTrue(f.line.isInInbox(try XCTUnwrap(f.line.items.first?.id)))
        var notesTakenOff = 0
        f.line.onTakeOffNote = { _ in notesTakenOff += 1; return true }
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.line.items.compactMap(\.noteID), [note])
        XCTAssertEqual(notesTakenOff, 0)
        XCTAssertEqual(try [a, b].map { try Data(contentsOf: $0) }, originals)
        XCTAssertEqual(f.line.screenshotClearUndoCount, 2)
    }

    @MainActor func testClearCommitsEntireSnapshotToSavedMembershipBeforeAnimation() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.shot("a"), b = try f.shot("b")
        f.line.hang(a, quietly: true)
        let note = UUID(); f.line.hangNote(note, thumbnail: f.thumbnail(), quietly: true)
        f.line.hang(b, quietly: true)
        _ = try XCTUnwrap(f.line.beginScreenshotClear())
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [])
        XCTAssertEqual(f.defaults.stringArray(forKey: "mixedLineOrder"), ["note:\(note.uuidString)"])
        XCTAssertEqual(f.line.items.count, 3, "The visible slots remain while saved membership is already committed")
        let relaunched = Line(restoring: true, gusts: false, defaults: f.defaults)
        XCTAssertTrue(relaunched.items.isEmpty, "An interrupted sweep must not bring its screenshots back on launch")
    }

    @MainActor func testLaterCapturesStayOutsideTheClearSnapshotAndUndoKeepsThem() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.shot("a"), b = try f.shot("b"), later = try f.shot("later")
        f.line.hang(a, quietly: true)
        let firstNote = UUID(); f.line.hangNote(firstNote, thumbnail: f.thumbnail(), quietly: true)
        f.line.hang(b, quietly: true)
        let lastNote = UUID(); f.line.hangNote(lastNote, thumbnail: f.thumbnail(), quietly: true)
        let originalOrder = f.line.items.map(\.id)
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        let newID = try XCTUnwrap(f.line.hang(later, quietly: true))
        f.line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.line.items.filter { $0.noteID == nil }.map(\.url), [later])
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [later.path])
        XCTAssertEqual(f.line.undoScreenshotClear(), 2)
        XCTAssertEqual(f.line.items.map(\.id), originalOrder + [newID])
        XCTAssertEqual(f.defaults.stringArray(forKey: "pegged"), [a.path, b.path, later.path])
    }

    @MainActor func testReleasedSlotsAreNotCompactedUntilSweepFinishes() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.line.hang(try f.shot("a"), quietly: true)
        let note = UUID(); f.line.hangNote(note, thumbnail: f.thumbnail(), quietly: true)
        f.line.hang(try f.shot("b"), quietly: true)
        let original = f.line.items.map(\.id)
        let before = f.line.hangingX(for: note, width: 1200)
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.releaseScreenshot(original[0], in: batch.id, animated: false)
        try await Task.sleep(for: .milliseconds(680))
        XCTAssertEqual(f.line.items.map(\.id), original)
        XCTAssertEqual(f.line.hangingX(for: note, width: 1200), before)
        f.line.hang(try f.shot("new"), quietly: true)
        XCTAssertEqual(f.line.hangingX(for: note, width: 1200), before)
        f.line.finishScreenshotClear(batch.id)
        XCTAssertFalse(f.line.items.contains { $0.id == original[0] })
    }

    @MainActor func testEmptyOrNotesOnlyClearDoesNotStartAndRepeatedRequestsCoalesce() throws {
        let f = try Fixture(); defer { f.clean() }
        XCTAssertNil(f.line.beginScreenshotClear())
        f.line.hangNote(UUID(), thumbnail: f.thumbnail(), quietly: true)
        XCTAssertNil(f.line.beginScreenshotClear())
        f.line.hang(try f.shot("a"), quietly: true)
        var requests = 0
        f.line.onClearScreenshots = { _ in requests += 1 }
        f.line.requestScreenshotClear()
        f.line.requestScreenshotClear()
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(f.line.screenshotClear)
    }

    @MainActor func testRecordingsAreNotIncludedInImageClear() async throws {
        let f = try Fixture(); defer { f.clean() }
        let video = f.root.appendingPathComponent("recording.mov")
        try Data([1, 2, 3]).write(to: video)
        await f.line.restorePhotos(paths: [video.path]) { _ in NSImage(size: NSSize(width: 40, height: 30)) }
        f.line.hang(try f.shot("a"), quietly: true)
        XCTAssertEqual(f.line.clearableScreenshotCount, 1)
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.line.items.map(\.url), [video])
        XCTAssertEqual(try Data(contentsOf: video), Data([1, 2, 3]))
    }

    @MainActor func testUndoSkipsMissingFilesAndDoesNotReviveAnIndependentlyRemovedNote() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.shot("a"), b = try f.shot("b")
        f.line.hang(a, quietly: true)
        let note = UUID(); f.line.hangNote(note, thumbnail: f.thumbnail(), quietly: true)
        f.line.hang(b, quietly: true)
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.finishScreenshotClear(batch.id)
        f.line.removeNote(note)
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(f.line.undoScreenshotClear(), 1)
        XCTAssertEqual(f.line.items.filter { !$0.falling }.map(\.url), [b])
        XCTAssertEqual(f.line.screenshotClearUndoCount, 0)
    }

    @MainActor func testUndoDoesNotDuplicateAnImageRehungDuringTheSweep() throws {
        let f = try Fixture(); defer { f.clean() }
        let a = try f.shot("a")
        let old = try XCTUnwrap(f.line.hang(a, quietly: true))
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.releaseScreenshot(old, in: batch.id, animated: false)
        let new = try XCTUnwrap(f.line.hang(a, quietly: true))
        f.line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.line.undoScreenshotClear(), 0)
        XCTAssertEqual(f.line.items.map(\.id), [new])
    }

    @MainActor func testStaleBatchCannotReleaseItemsInTheNextClear() throws {
        let f = try Fixture(); defer { f.clean() }
        f.line.hang(try f.shot("a"), quietly: true)
        let first = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.finishScreenshotClear(first.id)
        let id = try XCTUnwrap(f.line.hang(try f.shot("b"), quietly: true))
        let second = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.releaseScreenshot(id, in: first.id, animated: false)
        f.line.finishScreenshotClear(first.id)
        XCTAssertEqual(f.line.screenshotClear?.id, second.id)
        XCTAssertFalse(try XCTUnwrap(f.line.items.first).falling)
        f.line.finishScreenshotClear(second.id)
        XCTAssertTrue(f.line.items.isEmpty)
    }

    @MainActor func testUndoNeverTrimsOrTrashesRestoredImagesAtTheCapacityLimit() throws {
        let f = try Fixture(); defer { f.clean() }
        let urls = try ["a", "b", "new"].map { try f.shot($0, owned: true) }
        f.line.hang(urls[0], quietly: true); f.line.hang(urls[1], quietly: true)
        f.line.maxItems = 1
        let batch = try XCTUnwrap(f.line.beginScreenshotClear())
        f.line.hang(urls[2], quietly: true)
        f.line.finishScreenshotClear(batch.id)
        XCTAssertEqual(f.line.undoScreenshotClear(), 2)
        XCTAssertEqual(f.line.items.count, 3)
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}

@MainActor private final class Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let line: Line
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shipian-clear-" + UUID().uuidString)
        suite = "shipian-clear-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let owned = root.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        line = Line(restoring: false, gusts: false, defaults: defaults, inboxFolder: owned)
        line.maxItems = 50
    }
    func thumbnail() -> NSImage { NSImage(size: NSSize(width: 40, height: 30)) }
    func shot(_ name: String, owned: Bool = false) throws -> URL {
        let url = (owned ? root.appendingPathComponent("owned") : root).appendingPathComponent(name + ".png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    func clean() {
        if let batch = line.screenshotClear { line.finishScreenshotClear(batch.id) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
