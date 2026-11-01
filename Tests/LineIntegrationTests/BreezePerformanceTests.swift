import XCTest
import AppKit
@testable import Tendedero

final class BreezePerformanceTests: XCTestCase {
    @MainActor func testBreezeOnlyRunsForVisibleNonemptyLineOutsideDrag() {
        let suite = "local.shipian.breeze-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let line = Line(restoring: false, gusts: false, defaults: defaults)

        line.revealed = true
        line.emitGustIfNeeded()
        XCTAssertEqual(line.gust, 0, "An empty line must not animate")

        let id = UUID()
        line.hangNote(id, thumbnail: NSImage(size: NSSize(width: 8, height: 8)), quietly: true)
        line.revealed = false
        line.emitGustIfNeeded()
        XCTAssertEqual(line.gust, 0, "A hidden line must not animate")

        line.revealed = true
        line.draggingID = id
        line.emitGustIfNeeded()
        XCTAssertEqual(line.gust, 0, "Dragging must not start a breeze")

        line.draggingID = nil
        line.emitGustIfNeeded()
        XCTAssertEqual(line.gust, 1, "Visible idle cards retain their breeze")
    }
}
