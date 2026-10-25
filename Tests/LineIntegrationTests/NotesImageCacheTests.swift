import AppKit
import XCTest
@testable import Tendedero

final class NotesImageCacheTests: XCTestCase {
    @MainActor func testAwaitingThumbnailLoadsCoalesceAndVisibleResultsSurviveCachePressure() async throws {
        let calls = LockedReads()
        let cache = NotesImageCache { _ in
            calls.record(main: Thread.isMainThread)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1536, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap); return image
        }
        let firstURL = URL(fileURLWithPath: "/fixture/thumbnail-0.png")
        async let first = cache.loadedImage(at: firstURL)
        async let duplicate = cache.loadedImage(at: firstURL)
        let (a,b) = await (first,duplicate)
        XCTAssertTrue(a === b)
        var visible = [try XCTUnwrap(a)]
        for i in 1..<15 {
            let loaded = await cache.loadedImage(at: URL(fileURLWithPath: "/fixture/thumbnail-\(i).png"))
            visible.append(try XCTUnwrap(loaded))
        }
        let completedRevision = cache.revision
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(visible.count,15)
        XCTAssertTrue(visible.allSatisfy { $0.representations.first?.pixelsWide == 2048 })
        XCTAssertEqual(calls.values.count,15,"Visible thumbnails keep their result instead of re-requesting evicted images on every cache publication")
        XCTAssertEqual(cache.revision,completedRevision)
        XCTAssertTrue(calls.values.allSatisfy { !$0 })
    }
    @MainActor func testSlowAttachmentReadDoesNotBlockUIAndLoadsOnlyOnce() async throws {
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let calls = LockedReads()
        let cache = NotesImageCache { _ in
            calls.record(main: Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.2)
            return image
        }
        let url = URL(fileURLWithPath: "/fixture/slow-provider.png")
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(cache.image(at: url), "The UI should return a loading state immediately")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1, "A slow file provider must not hold the main actor")
        _ = cache.image(at: url)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(cache.image(at: url) === image)
        XCTAssertEqual(calls.values.count, 1, "Typing and color changes must reuse a decoded attachment")
        XCTAssertEqual(calls.values, [false], "Read and decode attachments outside the main thread")
    }
    @MainActor func testUnavailableImageStopsRetryingUntilUserRequestsRetry() async throws {
        let calls = LockedReads()
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let cache = NotesImageCache { _ in
            calls.record(main: Thread.isMainThread)
            return calls.values.count == 1 ? nil : image
        }
        let url = URL(fileURLWithPath: "/fixture/retry.png")
        XCTAssertNil(cache.image(at: url))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(cache.hasFailed(url))
        for _ in 0..<5 { XCTAssertNil(cache.image(at: url)) }
        XCTAssertEqual(calls.values.count, 1)
        cache.retry(url)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(cache.image(at: url) === image)
        XCTAssertFalse(cache.hasFailed(url))
        XCTAssertEqual(calls.values, [false, false])
    }

}
private final class LockedReads: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func record(main: Bool) { lock.lock(); recorded.append(main); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return recorded }
}
