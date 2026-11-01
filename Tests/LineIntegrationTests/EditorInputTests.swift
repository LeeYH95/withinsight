import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class EditorInputTests: XCTestCase {
    @MainActor private func withEditor(_ run: (NotesContinuousTextView, NotesEditorSession, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["SHIPIAN_EDITOR_QA_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("editor-input-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        let session = NotesEditorSession(note: try store.create(), store: store)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.session = session; session.textView = view; view.loadDocument(session.note)
        view.publish = { [weak view, weak session] in
            guard let view, let session else { return }
            if let blocks = try? NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale, trailingAttributes: view.trailingAttributes) { session.updateBlocks(blocks) }
        }
        try run(view, session, root)
    }
    @MainActor private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSColor.blue.setFill()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor func testScreenshotPastePrefersImageOverItsTextRepresentation() throws {
        try withEditor { view, session, _ in
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let item = NSPasteboardItem(); item.setData(try png(), forType: .png); item.setString("Screenshot.png", forType: .string)
            board.writeObjects([item])
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertEqual(session.note.attachments.count, 1)
            XCTAssertFalse(session.note.blocks.contains { $0.text == "Screenshot.png" && $0.kind == .paragraph })
        }
    }
    @MainActor func testTwoClipboardImagesImportTogetherInOrderAndUndoAsOneAction() throws {
        try withEditor { view, session, _ in
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let bytes = try png()
            let items = (0..<2).map { _ in let item = NSPasteboardItem(); item.setData(bytes, forType: .png); return item }
            board.writeObjects(items)
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertEqual(session.note.attachments.count, 2)
            XCTAssertEqual(session.note.blocks.filter { $0.kind == .image }.count, 2)
            try session.commit()
            let attachments = session.note.attachments
            session.undo()
            XCTAssertEqual(session.note.attachments.count, 0)
            session.redo()
            try session.commit()
            XCTAssertEqual(session.note.attachments.map(\.id), attachments.map(\.id))
            for image in session.note.attachments { XCTAssertEqual(try Data(contentsOf: session.store.url(for: image)), bytes) }
        }
    }
    @MainActor func testMatchPasteUsesInsertionFontAndRemovesSourceBackground() throws {
        try withEditor { view, _, _ in
            view.typingAttributes = [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor(NotesTheme.text)]
            let source = NSAttributedString(string: "来源文字", attributes: [.font: NSFont.systemFont(ofSize: 9), .backgroundColor: NSColor.red, .foregroundColor: NSColor.green, .shadow: NSShadow()])
            XCTAssertTrue(view.insertPasted(source))
            let result = view.attributedString()
            XCTAssertEqual((result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
            XCTAssertNil(result.attribute(.backgroundColor, at: 0, effectiveRange: nil))
            XCTAssertNil(result.attribute(.shadow, at: 0, effectiveRange: nil))
            XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
        }
    }
    @MainActor func testSingleImageSelectionProvidesStandardImageAndControlShortcutsUseTheSameClipboard() throws {
        try withEditor { view, session, _ in
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            view.clipboard = board
            session.pasteImages([try png()]); view.loadDocument(session.note)
            view.setSelectedRange(NSRange(location: 0, length: 1))
            let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            XCTAssertTrue(view.performKeyEquivalent(with: copy))
            XCTAssertNotNil(board.data(forType: .png), "Other apps must receive a real image, not only Shipian's custom selection")
            XCTAssertNotNil(NSImage(pasteboard: board))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            let paste = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            XCTAssertTrue(view.performKeyEquivalent(with: paste))
            XCTAssertEqual(session.note.attachments.count, 2)
        }
    }
    @MainActor func testRopeFileDropCopiesOwnedBytesAtThePointerWithoutReplacingSelectedText() throws {
        try withEditor { view, session, root in
            view.insertText("保留正文", replacementRange: view.selectedRange()); try session.commit()
            let file = root.appendingPathComponent("rope.png"), bytes = try png(); try bytes.write(to: file)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.writeObjects([file as NSURL])
            view.selectAll(nil)
            XCTAssertTrue(view.importDroppedContent(from: board, at: NSPoint(x: 300, y: 10)))
            XCTAssertTrue(session.note.blocks.contains { $0.text == "保留正文" })
            XCTAssertEqual(session.note.attachments.count, 1)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            let attachment = try XCTUnwrap(session.note.attachments.first)
            XCTAssertEqual(try Data(contentsOf: session.store.url(for: attachment)), bytes)
            XCTAssertNotEqual(try session.store.url(for: attachment), file)
        }
    }
    @MainActor func testDropOnOuterPaperAppendsInsteadOfReusingAnEarlierCaret() throws {
        try withEditor { view, session, _ in
            view.insertText("开头\n正文末尾", replacementRange: view.selectedRange())
            try session.commit()
            session.undoManager.removeAllActions()
            view.setSelectedRange(NSRange(location: 0, length: 2))
            session.appendDroppedItems([.image(try png())])
            let imageIndex = try XCTUnwrap(session.note.blocks.firstIndex(where: { $0.kind == .image }))
            let beforeImage = session.note.blocks.prefix(imageIndex).map(\.text).joined(separator: "\n")
            XCTAssertTrue(beforeImage.contains("开头\n正文末尾"), "Paper outside the native text view must append after all text, without replacing the stale selection")
            session.undo()
            XCTAssertEqual(session.note.attachments.count, 0)
            XCTAssertEqual(session.note.blocks.map(\.text).joined(separator: "\n"), "开头\n正文末尾")
        }
    }
    @MainActor func testMixedFileAndRawImagePastePreservesBothItemsAndTheirOrder() throws {
        try withEditor { view, session, root in
            let bytes = try png(), source = root.appendingPathComponent("rope.png"); try bytes.write(to: source)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            let file = NSPasteboardItem(); file.setString(source.absoluteString, forType: .fileURL)
            let image = NSPasteboardItem(); image.setData(bytes, forType: .png)
            board.writeObjects([file, image])
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertEqual(session.note.attachments.count, 2)
            XCTAssertEqual(session.note.attachments.first?.name, "rope.png")
            XCTAssertEqual(session.note.blocks.filter { $0.kind == .image }.count, 2)
        }
    }
    @MainActor func testImageOnlyRichClipboardDoesNotCollapseTwoImagesToItsPNGPreview() throws {
        try withEditor { view, session, _ in
            let bytes = try png()
            session.pasteImages([bytes, bytes]); view.loadDocument(session.note); view.selectAll(nil)
            let source = NSPasteboard.withUniqueName(), board = NSPasteboard.withUniqueName()
            defer { source.releaseGlobally(); board.releaseGlobally() }
            XCTAssertTrue(view.writeSelection(to: source, types: view.writablePasteboardTypes))
            board.declareTypes([.rtfd, .png], owner: nil)
            board.setData(try XCTUnwrap(source.data(forType: .rtfd)), forType: .rtfd); board.setData(bytes, forType: .png)
            try withEditor { target, pasted, _ in
                XCTAssertTrue(target.readSelection(from: board))
                XCTAssertEqual(pasted.note.attachments.count, 2)
                XCTAssertEqual(pasted.note.blocks.filter { $0.kind == .image }.count, 2)
            }
        }
    }
    @MainActor func testOrderedListsKeepStructureThroughOnlyTheExternalClipboardFlavor() throws {
        try withEditor { view, session, _ in
            session.change("验收列表") { $0.blocks = [NoteBlock(text: "父项", markdown: "1. 父项"), NoteBlock(text: "子项", markdown: "  1. 子项")] }
            view.loadDocument(session.note); view.selectAll(nil)
            let source = NSPasteboard.withUniqueName(), board = NSPasteboard.withUniqueName()
            defer { source.releaseGlobally(); board.releaseGlobally() }
            XCTAssertTrue(view.writeSelection(to: source, types: view.writablePasteboardTypes))
            board.declareTypes([.rtfd], owner: nil); board.setData(try XCTUnwrap(source.data(forType: .rtfd)), forType: .rtfd)
            try withEditor { target, pasted, _ in
                XCTAssertTrue(target.readSelection(from: board))
                XCTAssertEqual(pasted.note.blocks.map(\.markdown), ["1. 父项", "  1. 子项"])
                target.setSelectedRange(NSRange(location: target.string.utf16.count, length: 0)); target.insertNewline(nil)
                XCTAssertTrue(target.string.hasSuffix("2.\t"))
            }
        }
    }
}
