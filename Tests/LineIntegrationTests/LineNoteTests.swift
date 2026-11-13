import XCTest
import AppKit
@testable import Tendedero

final class LineNoteTests: XCTestCase {
    @MainActor func testNoteUsesStableIdentityAndUpdatesWithoutRehanging() throws {
        let line = Line(restoring: false, gusts: false)
        let id = UUID()
        let first = image()
        line.hangNote(id, thumbnail: first, quietly: true)
        XCTAssertEqual(line.items.count, 1, "A note must become a hanging item")
        let next = image()
        line.updateNote(id, thumbnail: next)
        XCTAssertEqual(line.items.first?.noteID, id)
        XCTAssertEqual(line.items.first?.id, id, "Text updates must not generate a new arrival identity")
        XCTAssertTrue(line.items.first?.thumb === next)
    }

    @MainActor func testHangingImagesKeepsNotesAndImagesBeyondTheViewport() throws {
        let line = Line(restoring: false, gusts: false)
        line.visibleCount = 1
        let ids = [UUID(), UUID(), UUID()]
        ids.forEach { line.hangNote($0, thumbnail: image(), quietly: true) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<2 {
            let url = folder.appendingPathComponent("shot-\(index).png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            line.hang(url, quietly: true)
        }
        XCTAssertEqual(Set(line.items.filter { !$0.falling }.compactMap(\.noteID)), Set(ids))
        XCTAssertEqual(line.items.filter { $0.noteID == nil && !$0.falling }.count, 2)
    }

    @MainActor func testPruneDoesNotTreatNoteReferenceAsMissingScreenshot() {
        let line = Line(restoring: false, gusts: false)
        let id = UUID()
        line.hangNote(id, thumbnail: image(), quietly: true)
        line.prune()
        XCTAssertEqual(line.items.filter { !$0.falling }.compactMap(\.noteID), [id])
    }

    @MainActor func testDiscardNoteCallsTakeOffAndNeverTrashesBackingURL() {
        let line = Line(restoring: false, gusts: false)
        let id = UUID()
        var takenOff: UUID?
        line.onTakeOffNote = { takenOff = $0; return true }
        line.hangNote(id, thumbnail: image(), quietly: true)
        line.discard(id, quietly: true)
        XCTAssertEqual(takenOff, id)
        XCTAssertEqual(line.items.filter { !$0.falling }.count, 0)
    }

    @MainActor private func image() -> NSImage { NSImage(size: NSSize(width: 150, height: 104)) }

    @MainActor func testReorderPlacesItemBeforeDestinationInEitherDirection() {
        let line = Line(restoring: false, gusts: false)
        let a = UUID(), b = UUID(), c = UUID()
        [a, b, c].forEach { line.hangNote($0, thumbnail: image(), quietly: true) }
        line.move(a, before: c)
        XCTAssertEqual(line.items.map(\.id), [b, a, c])
        line.move(c, before: b)
        XCTAssertEqual(line.items.map(\.id), [c, b, a])
    }

    @MainActor func testInitialMixedOrderSurvivesNotesBeingRecreatedAfterScreenshots() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "mixedLineOrder")
        let oldImages = defaults.object(forKey: "pegged")
        defer {
            defaults.set(previous, forKey: "mixedLineOrder")
            defaults.set(oldImages, forKey: "pegged")
        }
        let a = UUID(), b = UUID()
        defaults.set(["note:\(b.uuidString)", "note:\(a.uuidString)"], forKey: "mixedLineOrder")
        defaults.set([], forKey: "pegged")
        let line = Line(restoring: true, gusts: false)
        [a, b].forEach { line.hangNote($0, thumbnail: image(), quietly: true) }
        line.restoreOrdering()
        XCTAssertEqual(line.items.map(\.noteID), [b, a])
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [])
    }

    @MainActor func testQuickRehangPersistsOriginalPosition() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "mixedLineOrder")
        let oldImages = defaults.object(forKey: "pegged")
        defer {
            defaults.set(previous, forKey: "mixedLineOrder")
            defaults.set(oldImages, forKey: "pegged")
        }
        let a = UUID(), b = UUID()
        let line = Line(restoring: false, gusts: false)
        [a, b].forEach { line.hangNote($0, thumbnail: image(), quietly: true) }
        line.discard(a, quietly: true)
        line.hangNote(a, thumbnail: image(), quietly: true)
        XCTAssertEqual(defaults.stringArray(forKey: "mixedLineOrder"), ["note:\(a.uuidString)", "note:\(b.uuidString)"])
        let relaunched = Line(restoring: true, gusts: false)
        [b, a].forEach { relaunched.hangNote($0, thumbnail: image(), quietly: true) }
        relaunched.restoreOrdering()
        XCTAssertEqual(relaunched.items.map(\.id), [a, b])
    }

    @MainActor func testAdjacentDropCanMoveToEitherSideAndFailedTakeOffStaysVisible() {
        let line = Line(restoring: false, gusts: false)
        let a = UUID(), b = UUID()
        [a, b].forEach { line.hangNote($0, thumbnail: image(), quietly: true) }
        line.move(a, after: b)
        XCTAssertEqual(line.items.map(\.id), [b, a])
        line.move(a, before: b)
        XCTAssertEqual(line.items.map(\.id), [a, b])
        line.onTakeOffNote = { _ in false }
        line.discard(a, quietly: true)
        XCTAssertFalse(line.items.first!.falling)
    }
}
