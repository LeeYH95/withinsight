import AppKit
import SwiftUI
import XCTest
import NotesCore
@testable import Tendedero

final class EditorImageStabilityTests: XCTestCase {
    @MainActor func testImageReadinessWaitsForIMECommitAndThenReplacesThePlaceholder() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ime-image-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = NoteAttachment(name: "fixture.png", relativePath: "attachments/fixture.png", kind: .image, byteCount: 1)
        let store = try NotesStore(directory: root)
        var note = try store.create()
        note.blocks = [NoteBlock(kind: .image, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "正文")]
        note.attachments = [attachment]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("attachments/fixture.png")); try store.update(note)
        let session = NotesEditorSession(note: note, store: store)
        let parent = NotesContinuousBody(session: session, scale: 1, onHeight: { _ in }, onAttachment: { _ in })
        let coordinator = NotesContinuousBody.Coordinator(parent)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.session = session; session.textView = view; coordinator.view = view
        var ready = false
        view.imageProvider = { _ in ready ? NSImage(size: NSSize(width: 100, height: 200)) : nil }
        view.onLayout = { coordinator.measure() }
        view.publish = { coordinator.publish() }
        coordinator.load()
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = view.string
        ready = true; coordinator.imageRevision = -1; coordinator.measure()
        XCTAssertTrue(view.hasMarkedText()); XCTAssertEqual(view.string, composing)
        view.unmarkText()
        var image: NSImage?
        view.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell { image = cell.previewImage }
        }
        XCTAssertNotNil(image, "A decode completed during IME input must be applied once composition ends")
        XCTAssertTrue(view.string.contains("ni")); XCTAssertTrue(session.note.plainText.contains("ni"))
    }
    @MainActor func testTwoTallImagesReachAStableHeightInTheRealSwiftUIEditorHost() async throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["SHIPIAN_EDITOR_QA_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("image-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        var note = try store.create()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent("tall.png"); try bytes.write(to: url)
        for _ in 0..<2 { _ = try store.importAttachment(from: url, to: note.id) }
        note = try XCTUnwrap(store.document(id: note.id))
        let session = NotesEditorSession(note: note, store: store)
        let host = NSHostingView(rootView: NoteEditorView(session: session, workspace: NotesWorkspace(store: store), expand: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func body(in parent: NSView) -> NotesContinuousTextView? {
            (parent as? NotesContinuousTextView) ?? parent.subviews.lazy.compactMap { body(in: $0) }.first
        }
        func readyImages() -> Int {
            guard let view = body(in: host) else { return 0 }
            var ready = 0
            view.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { token, _, _ in
                if let cell = (token as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell,
                   cell.previewImage != nil { ready += 1 }
            }
            return ready
        }
        // Start measuring settled layouts only after the asynchronous image
        // tasks have produced pixels, rather than assuming a fixed load time.
        let deadline = Date().addingTimeInterval(3)
        while readyImages() < 2, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(readyImages(), 2, "Both native image cells must load before measuring stability")
        var heights: [CGFloat] = []
        for i in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            if i == 15 { window.setContentSize(NSSize(width: 720, height: 500)) }
            if i >= 20, let view = body(in: host) { heights.append(view.frame.height) }
        }
        let view = try XCTUnwrap(body(in: host)), manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        XCTAssertEqual(session.note.attachments.count, 2)
        XCTAssertEqual(heights.count, 10)
        XCTAssertLessThan((heights.max() ?? 0) - (heights.min() ?? 0), 0.5, "Repeated native layout must settle instead of flashing between heights")
        XCTAssertLessThanOrEqual(abs(view.frame.width - container.containerSize.width), 1)
        var ready = 0
        view.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { token, _, _ in
            if let cell = (token as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell, cell.previewImage != nil { ready += 1 }
        }
        XCTAssertEqual(ready, 2)
    }
    @MainActor func testTwoVisibleImagesKeepPixelsAndHeightWhenSharedCacheLosesEntries() throws {
        _ = NSApplication.shared
        let images = [NSImage(size: NSSize(width: 320, height: 900)), NSImage(size: NSSize(width: 320, height: 650))]
        let attachments = images.indices.map { NoteAttachment(id: UUID(), name: "\($0).png", relativePath: "\($0).png", kind: .image, byteCount: 1) }
        let note = NoteDocument(blocks: attachments.map { NoteBlock(kind: .image, text: $0.name, attachmentID: $0.id) } + [NoteBlock(text: "图片之后仍可编辑")], attachments: attachments)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        var available = Dictionary(uniqueKeysWithValues: zip(attachments.map(\.id), images))
        view.imageProvider = { available[$0.id] }
        func cells() -> [NotesDocumentAttachmentCell] {
            var result: [NotesDocumentAttachmentCell] = []
            view.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.attributedString().length)) { value, _, _ in
                if let cell = (value as? NSTextAttachment)?.attachmentCell as? NotesDocumentAttachmentCell { result.append(cell) }
            }
            return result
        }
        view.loadDocument(note)
        let initial = cells().map { $0.cellSize().height }
        available.removeAll() // Simulate eviction; the existing visible cells still own valid pixels.
        for _ in 0..<8 { view.loadDocument(note) }
        XCTAssertEqual(cells().count, 2)
        XCTAssertEqual(cells().map { $0.cellSize().height }, initial, "An unrelated cache refresh must not turn visible images into short placeholders")
        XCTAssertTrue(cells().allSatisfy { $0.previewImage != nil })
    }
}
