import AppKit
import XCTest
@testable import Tendedero

final class CaptureFlightClearTests: XCTestCase {
    @MainActor func testSettlingOnlyTheClearSnapshotLandsOnceAndLeavesLaterFlightsRunning() throws {
        guard !HangingMotion.reduced else { throw XCTSkip("System reduced motion skips capture flights") }
        let screen = try XCTUnwrap(NSScreen.main)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let image = try XCTUnwrap(bitmap.cgImage)
        let target = UUID(), later = UUID()
        let base = CaptureFlight.flightsInProgress
        var landed: [UUID] = []
        for id in [target, later] {
            CaptureFlight.fly(image: image, from: CGRect(x: 20, y: 20, width: 20, height: 20),
                              to: CGRect(x: 50, y: 500, width: 20, height: 20), tilt: 0, on: screen,
                              id: id) { landed.append(id) }
        }
        defer { CaptureFlight.settle([target, later]) }
        CaptureFlight.settle([target])
        XCTAssertEqual(landed, [target])
        XCTAssertEqual(CaptureFlight.flightsInProgress, base + 1)
        CaptureFlight.settle([target])
        XCTAssertEqual(landed, [target], "A pending tick must not land a settled capture twice")
        CaptureFlight.settle([later])
        XCTAssertEqual(landed, [target, later])
        XCTAssertEqual(CaptureFlight.flightsInProgress, base)
    }
}
