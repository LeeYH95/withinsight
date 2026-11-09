import CoreServices
import Foundation
import XCTest
@testable import Tendedero

final class AirDropImageWatcherTests: XCTestCase {
    @MainActor func testAirDropIsOnByDefaultAndRespectsAnExplicitOptOut() throws {
        let suite = "shipian-airdrop-preference-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppDelegate.hangsAirDropImages(in: defaults))
        defaults.set(false, forKey: AppDelegate.hangAirDropImagesKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(AppDelegate.hangsAirDropImages(in: reopened))
    }

    @MainActor func testOnlyNewAirDropImagesReachTheLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipian-airdrop-" + UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        let staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pixels = try Data(contentsOf: project.appendingPathComponent("Sources/Tendedero/Resources/LineControls/ClearScreenshots.png"))
        let oldDate = Date().addingTimeInterval(-86_400)
        func stagedFile(_ name: String, type: String?, received: Date) throws -> URL {
            var url = staging.appendingPathComponent(name)
            try pixels.write(to: url)
            var values = URLResourceValues()
            values.creationDate = oldDate
            if let type {
                values.quarantineProperties = [kLSQuarantineTypeKey as String: type,
                                               kLSQuarantineTimeStampKey as String: received]
            }
            try url.setResourceValues(values)
            return url
        }
        func deliver(_ url: URL) throws {
            try FileManager.default.moveItem(at: url, to: downloads.appendingPathComponent(url.lastPathComponent))
        }
        let airDropType = "LSQuarantineTypeAirDrop"
        try deliver(stagedFile("received-yesterday.png", type: airDropType, received: oldDate))
        let suite = "shipian-airdrop-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let line = Line(restoring: false, gusts: false, defaults: defaults)
        var delivered: [String] = []
        let hung = expectation(description: "fresh AirDrop image hangs")
        let late = expectation(description: "AirDrop metadata arriving after the first scan is picked up")
        let next = expectation(description: "the next arrival is seen by the active watcher")
        let stopped = expectation(description: "an arrival after stopping is ignored")
        stopped.isInverted = true
        let watcher = ScreenshotWatcher(folder: downloads, imageSource: .airDrop, onNew: { url in
            delivered.append(url.lastPathComponent)
            guard line.hang(url, quietly: true) != nil else { return }
            if url.lastPathComponent == "received-now.png" { hung.fulfill() }
            if url.lastPathComponent == "metadata-late.png" { late.fulfill() }
            if url.lastPathComponent == "second-airdrop.png" { next.fulfill() }
            if url.lastPathComponent == "after-stop.png" { stopped.fulfill() }
        }, onChange: {})
        watcher.start()
        defer { watcher.stop() }

        try deliver(stagedFile("copied-old-transfer.png", type: airDropType, received: oldDate))
        try deliver(stagedFile("chrome.png", type: kLSQuarantineTypeWebDownload as String, received: Date()))
        try deliver(stagedFile("local.png", type: nil, received: Date()))
        try deliver(stagedFile("non-image.txt", type: airDropType, received: Date()))
        try deliver(stagedFile("metadata-late.png", type: nil, received: Date()))
        try deliver(stagedFile("received-now.png", type: airDropType, received: Date()))
        await fulfillment(of: [hung], timeout: 4)

        XCTAssertEqual(delivered, ["received-now.png"])
        // The tagged file acts as a barrier for the first scan of both arrivals.
        var lateImage = downloads.appendingPathComponent("metadata-late.png")
        var metadata = URLResourceValues()
        metadata.quarantineProperties = [kLSQuarantineTypeKey as String: airDropType,
                                         kLSQuarantineTimeStampKey as String: Date()]
        try lateImage.setResourceValues(metadata)
        await fulfillment(of: [late], timeout: 4)
        XCTAssertEqual(delivered, ["received-now.png", "metadata-late.png"])

        try deliver(stagedFile("browser-again.png", type: kLSQuarantineTypeWebDownload as String, received: Date()))
        try deliver(stagedFile("second-airdrop.png", type: airDropType, received: Date()))
        await fulfillment(of: [next], timeout: 4)

        XCTAssertEqual(delivered, ["received-now.png", "metadata-late.png", "second-airdrop.png"])
        XCTAssertEqual(line.items.map { $0.url.lastPathComponent }, delivered)
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("received-now.png")), pixels)

        watcher.stop()
        try deliver(stagedFile("after-stop.png", type: airDropType, received: Date()))
        await fulfillment(of: [stopped], timeout: 0.6)
        XCTAssertEqual(delivered, ["received-now.png", "metadata-late.png", "second-airdrop.png"])
    }
}
