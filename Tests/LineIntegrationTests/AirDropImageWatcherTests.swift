import CoreServices
import Foundation
import XCTest
@testable import Tendedero

final class AirDropImageWatcherTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectory: URL {
        ProcessInfo.processInfo.environment["SHIPIAN_TEST_TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory
    }
    private let airDropType = "LSQuarantineTypeAirDrop"

    private func markAirDrop(_ file: URL) throws {
        var url = file
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: airDropType,
                                       kLSQuarantineTimeStampKey as String: Date()]
        try url.setResourceValues(values)
    }

    private func fixturePixels() throws -> Data {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: project.appendingPathComponent("Sources/Tendedero/Resources/LineControls/ClearScreenshots.png"))
    }

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
        let root = temporaryDirectory.appendingPathComponent("shipian-airdrop-" + UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        let staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pixels = try fixturePixels()
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
        try deliver(stagedFile("metadata-late.png", type: kLSQuarantineTypeWebDownload as String, received: Date()))
        try deliver(stagedFile("received-now.png", type: airDropType, received: Date()))
        await fulfillment(of: [hung], timeout: 4)

        XCTAssertEqual(delivered, ["received-now.png"])
        // The tagged file acts as a barrier for the first scan of both arrivals.
        try await Task.sleep(for: .seconds(5.3))
        try markAirDrop(downloads.appendingPathComponent("metadata-late.png"))
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

    @MainActor func testWatcherRecoversWhenDownloadsBecomesAvailable() async throws {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let hung = expectation(description: "arrival after directory access returns")
        let unavailable = expectation(description: "unavailable folder is reported")
        let listening = expectation(description: "watcher reports listening once it can list the folder")
        let watcher = ScreenshotWatcher(folder: downloads, imageSource: .airDrop,
                                        onAvailability: { state in
                                            if state == .unavailable { unavailable.fulfill() }
                                            if state == .listening { listening.fulfill() }
                                        },
                                        onNew: { _ in hung.fulfill() }, onChange: {})
        watcher.start()
        defer { watcher.stop() }

        await fulfillment(of: [unavailable], timeout: 3)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: false)
        let image = downloads.appendingPathComponent("arrived.png")
        try Data().write(to: image)
        try markAirDrop(image)
        await fulfillment(of: [hung, listening], timeout: 8)
    }

    @MainActor func testUndecodableArrivalRetriesAndSameNameReplacementKeepsOneCard() async throws {
        let root = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = root.appendingPathComponent("Downloads")
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let suite = "shipian-airdrop-replacement-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let line = Line(restoring: false, gusts: false, defaults: defaults)
        let pixels = try fixturePixels()
        let image = downloads.appendingPathComponent("photo.png")
        let unreadable = expectation(description: "image reaches the line before decoding is possible")
        let hung = expectation(description: "readable image hangs without another directory event")
        let replaced = expectation(description: "same-name replacement refreshes the card")
        var reportedUnreadable = false
        var accepted = [UUID]()
        let watcher = ScreenshotWatcher(folder: downloads, imageSource: .airDrop, onAirDropImage: { url in
            guard let id = line.hang(url, quietly: true, replacingExisting: true) else {
                if !reportedUnreadable {
                    reportedUnreadable = true
                    unreadable.fulfill()
                }
                return false
            }
            accepted.append(id)
            if accepted.count == 1 { hung.fulfill() }
            if accepted.count == 2 { replaced.fulfill() }
            return true
        }, onChange: {})
        watcher.start()
        defer { watcher.stop() }

        try Data().write(to: image)
        try markAirDrop(image)
        await fulfillment(of: [unreadable], timeout: 4)
        let handle = try FileHandle(forWritingTo: image)
        try handle.write(contentsOf: pixels)
        try handle.close()
        await fulfillment(of: [hung], timeout: 4)

        let staging = root.appendingPathComponent("incoming.png")
        try pixels.write(to: staging)
        try markAirDrop(staging)
        XCTAssertEqual(rename(staging.path, image.path), 0)
        await fulfillment(of: [replaced], timeout: 4)
        XCTAssertEqual(line.items.map(\.id), [try XCTUnwrap(accepted.first)])
        XCTAssertEqual(accepted.first, accepted.last)
    }
}
