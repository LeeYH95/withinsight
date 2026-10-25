import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Tendedero

final class AttachmentPanelTests: XCTestCase {
    @MainActor func testAttachmentChooserExplicitlyAllowsFilesAfterContentFilter() {
        _ = NSApplication.shared
        for imageOnly in [false, true] {
            let panel = NotesEditorSession.attachmentPanel(imagesOnly: imageOnly)
            XCTAssertTrue(panel.canChooseFiles)
            XCTAssertFalse(panel.canChooseDirectories)
            XCTAssertFalse(panel.treatsFilePackagesAsDirectories)
            XCTAssertTrue(panel.allowsMultipleSelection)
            if imageOnly { XCTAssertTrue(panel.allowedContentTypes.contains(.image)) }
        }
    }
    func testActualPNGDecodesForBackgroundDisplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LineNotes-decode-" + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let image = try XCTUnwrap(NotesImageDecoder.read(url))
        XCTAssertEqual(image.size.width / image.size.height, 3, accuracy: 0.01)
        XCTAssertLessThanOrEqual(image.representations[0].pixelsWide, 2048)
        let thumbnail = try XCTUnwrap(NotesImageDecoder.read(url, maximumPixelSize: 640))
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 3, accuracy: 0.01)
        XCTAssertLessThanOrEqual(thumbnail.representations[0].pixelsWide, 640)
    }
}
