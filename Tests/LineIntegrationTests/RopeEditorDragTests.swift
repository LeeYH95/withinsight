import AppKit
import XCTest
@testable import Tendedero

final class RopeEditorDragTests: XCTestCase {
    @MainActor func testSameApplicationScreenshotDragCanCopyIntoNotesAndStillReorderOnRope() {
        _ = NSApplication.shared
        let source = GrabView()
        source.itemID = UUID()
        let previous = GrabView.activeDragID
        GrabView.activeDragID = source.itemID
        defer { GrabView.activeDragID = previous }

        let session = NSDraggingSession()
        let local = source.draggingSession(session, sourceOperationMaskFor: .withinApplication)
        XCTAssertTrue(local.contains(.copy), "The note editor accepts a copy, so the source must offer copy inside this app too")
        XCTAssertTrue(local.contains(.move), "Dropping back onto the rope must still support reordering")
        XCTAssertEqual(source.draggingSession(session, sourceOperationMaskFor: .outsideApplication), source.outsideOperations)
    }

    @MainActor func testInactiveRopeDragDoesNotOfferAnInternalOperation() {
        _ = NSApplication.shared
        let source = GrabView()
        let previous = GrabView.activeDragID
        GrabView.activeDragID = nil
        defer { GrabView.activeDragID = previous }
        XCTAssertEqual(source.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .withinApplication), [])
    }
}
