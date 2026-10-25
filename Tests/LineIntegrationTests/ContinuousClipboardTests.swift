import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class ContinuousClipboardTests: XCTestCase {
    private let payloadType = NSPasteboard.PasteboardType("local.shipian.owned-selection.v1")

    @MainActor private func editor(_ note: NoteDocument, store: NotesStore) -> (NotesContinuousTextView, NotesEditorSession) {
        _ = NSApplication.shared
        let session = NotesEditorSession(note: note, store: store)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.session = session; session.textView = view
        view.imageProvider = { attachment in (try? session.localURL(for: attachment)).flatMap(NSImage.init(contentsOf:)) }
        view.loadDocument(note)
        view.publish = { [weak view] in
            guard let view else { return }
            session.updateBlocks((try? NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale, trailingAttributes: view.trailingAttributes)) ?? session.note.blocks)
        }
        return (view, session)
    }

    @MainActor private func fixture(_ root: URL) throws -> (NotesStore, NoteDocument, [Data]) {
        let store = try NotesStore(directory: root.appendingPathComponent("source"))
        var note = try store.create()
        let fileBytes = Data("文件附件必须保留\u{0}完整二进制".utf8)
        let file = root.appendingPathComponent("附件.txt"); try fileBytes.write(to: file)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.3, blue: 0.7, alpha: 1), atX: x, y: y) } }
        let imageBytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = root.appendingPathComponent("图片.png"); try imageBytes.write(to: image)
        let fileAttachment = try store.importAttachment(from: file, to: note.id)
        let imageAttachment = try store.importAttachment(from: image, to: note.id)
        note = try XCTUnwrap(store.document(id: note.id))
        let rich = NSAttributedString(string: "粗体开头", attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .underlineStyle: 1])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        note.blocks = [NoteBlock(text: rich.string, richText: rtf), NoteBlock(kind: .file, text: fileAttachment.name, attachmentID: fileAttachment.id), NoteBlock(kind: .image, text: imageAttachment.name, attachmentID: imageAttachment.id), NoteBlock(kind: .checklist, text: "最后待办", isChecked: true)]
        try store.update(note); try store.flush()
        return (store, note, [fileBytes, imageBytes])
    }

    @MainActor func testOwnedSelectionCopiesBothAttachmentBytesAcrossStoresAfterSourceIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, bytes) = try fixture(root)
        let (source, sourceSession) = editor(note, store: store)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        source.selectAll(nil)
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes), "Copy must not silently discard owned attachments")
        let payload = try XCTUnwrap(board.data(forType: payloadType))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(root.path), "Clipboard must carry bytes, never trusted source paths")
        try sourceSession.commit()
        try FileManager.default.removeItem(at: store.directory)
        let targetStore = try NotesStore(directory: root.appendingPathComponent("target"))
        let (target, session) = editor(try targetStore.create(), store: targetStore)
        target.preservePastedFormatting = true
        XCTAssertTrue(target.readSelection(from: board))
        try session.commit()
        let result = try XCTUnwrap(try NotesStore(directory: targetStore.directory).document(id: session.note.id))
        XCTAssertEqual(result.blocks.map(\.kind), [.paragraph, .file, .image, .checklist])
        XCTAssertEqual(result.blocks.map(\.text), note.blocks.map(\.text))
        XCTAssertEqual(result.blocks.last?.isChecked, true)
        XCTAssertEqual(result.attachments.count, 2)
        for (attachment, expected) in zip(result.attachments, bytes) { XCTAssertEqual(try Data(contentsOf: targetStore.url(for: attachment)), expected) }
        let rich = try XCTUnwrap(result.blocks.first?.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let font = try XCTUnwrap(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 24, accuracy: 0.02)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(rich.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 1)
    }

    @MainActor func testInvalidOwnedPayloadDoesNotFallBackToLossyTextOrReplaceSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-invalid-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let (view, session) = editor(NoteDocument(blocks: [NoteBlock(text: "不能覆盖的原文")]), store: store)
        view.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([payloadType, .string], owner: nil)
        board.setData(Data("invalid payload".utf8), forType: payloadType)
        board.setString("附件已丢失的降级文本", forType: .string)
        XCTAssertFalse(view.readSelection(from: board))
        XCTAssertEqual(view.string, "不能覆盖的原文")
        XCTAssertNotNil(session.attachmentFailure)
    }

    @MainActor func testCutThenSaveAndUndoRestoresOwnedBytesWhileClipboardRemainsIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-cut-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, bytes) = try fixture(root)
        let (view, session) = editor(note, store: store)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        view.selectAll(nil)
        session.undoManager.beginUndoGrouping()
        XCTAssertTrue(view.cut(to: board))
        session.undoManager.endUndoGrouping()
        try session.commit()
        XCTAssertEqual(session.note.attachments.count, 0)
        for attachment in note.attachments { XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path)) }
        session.undo(); try session.commit()
        XCTAssertEqual(session.note.blocks.map(\.text), note.blocks.map(\.text))
        XCTAssertEqual(session.note.attachments.count, 2)
        for (attachment, expected) in zip(session.note.attachments, bytes) { XCTAssertEqual(try Data(contentsOf: session.localURL(for: attachment)), expected) }
        let (target, targetSession) = editor(try store.create(), store: store)
        XCTAssertTrue(target.readSelection(from: board)); try targetSession.commit()
        for (attachment, expected) in zip(targetSession.note.attachments, bytes) { XCTAssertEqual(try Data(contentsOf: targetSession.localURL(for: attachment)), expected) }
    }

    @MainActor func testCopyFailureNeverCutsOrReplacesExistingClipboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-failed-cut-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, _) = try fixture(root)
        let (view, session) = editor(note, store: store)
        try FileManager.default.removeItem(at: store.url(for: note.attachments[0]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil); board.setString("已有剪贴板内容", forType: .string)
        let before = view.attributedString(); view.selectAll(nil)
        XCTAssertFalse(view.cut(to: board))
        XCTAssertEqual(view.attributedString(), before)
        XCTAssertEqual(session.note, note)
        XCTAssertEqual(board.string(forType: .string), "已有剪贴板内容")
        XCTAssertNotNil(session.attachmentFailure)
    }

    @MainActor func testPastingOneOwnedFileInsideTextCreatesBoundariesAndSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-inline-file-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, bytes) = try fixture(root)
        let (source, _) = editor(note, store: store)
        let range = (source.string as NSString).range(of: "\u{FFFC}")
        source.setSelectedRange(range)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        var targetNote = try store.create(); targetNote.blocks = [NoteBlock(text: "前后")]; try store.update(targetNote)
        let (target, session) = editor(targetNote, store: store)
        target.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(target.readSelection(from: board)); try session.commit()
        let reopened = try XCTUnwrap(try NotesStore(directory: store.directory).document(id: targetNote.id))
        XCTAssertEqual(reopened.blocks.map(\.kind), [.paragraph, .file, .paragraph])
        XCTAssertEqual(reopened.blocks.map(\.text), ["前", "附件.txt", "后"])
        let attachment = try XCTUnwrap(reopened.attachments.first)
        XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), bytes[0])
    }

    @MainActor func testReplacingOwnedSelectionCanUndoAfterSavingTheReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-replace-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, bytes) = try fixture(root)
        let (source, _) = editor(NoteDocument(blocks: [NoteBlock(text: "替换正文")]), store: store)
        source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let (target, session) = editor(note, store: store)
        target.selectAll(nil)
        XCTAssertTrue(target.readSelection(from: board)); try session.commit()
        XCTAssertEqual(session.note.blocks.map(\.text), ["替换正文"])
        for attachment in note.attachments {
            let owned = try store.url(for: attachment)
            // Emulate completed owned-file collection before the user chooses Undo.
            if FileManager.default.fileExists(atPath: owned.path) { try FileManager.default.removeItem(at: owned) }
        }
        session.undo(); try session.commit()
        XCTAssertEqual(session.note.attachments.count, 2)
        for (attachment, expected) in zip(session.note.attachments, bytes) { XCTAssertEqual(try Data(contentsOf: session.localURL(for: attachment)), expected) }
        XCTAssertEqual(session.note.blocks.map(\.text), note.blocks.map(\.text))
    }

    @MainActor func testTamperedBytesAndTraversalNamesAreRejectedBeforeChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-untrusted-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, _) = try fixture(root)
        let (source, _) = editor(note, store: store); source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let original = try XCTUnwrap(board.data(forType: payloadType))
        let (target, session) = editor(try store.create(), store: store)
        for field in ["digest", "name"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var assets = try XCTUnwrap(json["assets"] as? [[String: Any]])
            assets[0][field] = field == "name" ? "../../不允许读取.txt" : "invalid checksum"
            json["assets"] = assets
            board.setData(try JSONSerialization.data(withJSONObject: json), forType: payloadType)
            XCTAssertFalse(target.readSelection(from: board))
            XCTAssertEqual(target.string, "")
            XCTAssertEqual(session.note.attachments.count, 0)
        }
    }

    @MainActor func testConflictingStoreDuringOwnedPasteKeepsTargetSelectionAndMemoryNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-paste-conflict-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (sourceStore, sourceNote, _) = try fixture(root)
        let (source, _) = editor(sourceNote, store: sourceStore); source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let targetStore = try NotesStore(directory: root.appendingPathComponent("target"))
        var note = try targetStore.create(); note.blocks = [NoteBlock(text: "选中的原内容必须保留")]; try targetStore.update(note)
        let (target, session) = editor(note, store: targetStore); target.selectAll(nil)
        let before = target.attributedString(), selection = target.selectedRange()
        let external = try NotesStore(directory: targetStore.directory)
        var externalNote = try XCTUnwrap(external.document(id: note.id)); externalNote.title = "外部修改"; try external.update(externalNote)
        let diskBefore = try Data(contentsOf: targetStore.directory.appendingPathComponent("notes.json"))
        XCTAssertFalse(target.readSelection(from: board))
        XCTAssertEqual(target.attributedString(), before)
        XCTAssertEqual(target.selectedRange(), selection)
        XCTAssertEqual(session.note.blocks, note.blocks)
        XCTAssertEqual(session.note.attachments, note.attachments)
        XCTAssertEqual(try Data(contentsOf: targetStore.directory.appendingPathComponent("notes.json")), diskBefore)
        XCTAssertNotNil(session.attachmentFailure)
    }

    @MainActor func testUnrestorableFormattingCannotBeCutIntoAnInvalidPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-invalid-cut-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let rich = NSAttributedString(string: "过大的来源字号", attributes: [.font: NSFont.systemFont(ofSize: 2000)])
        let data = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        var note = try store.create(); note.blocks = [NoteBlock(text: rich.string, richText: data)]; try store.update(note)
        let (view, _) = editor(note, store: store); view.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let before = view.attributedString()
        XCTAssertFalse(view.cut(to: board))
        XCTAssertEqual(view.attributedString(), before)
        XCTAssertEqual(view.string, rich.string)
    }

    @MainActor private func externalRTFD(_ root: URL) throws -> (Data, [Data]) {
        let (store, original, bytes) = try fixture(root)
        var note = original
        note.blocks[note.blocks.count - 1] = NoteBlock(text: "尾文必须保留")
        try store.update(note)
        let (source, _) = editor(note, store: store); source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        return (try XCTUnwrap(board.data(forType: .rtfd)), bytes)
    }

    @MainActor func testExternalRTFDRoundTripRetainsTextFileImageAndTrailingText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-external-rtfd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (rtfd, bytes) = try externalRTFD(root)
        let store = try NotesStore(directory: root.appendingPathComponent("target"))
        let (target, session) = editor(try store.create(), store: store)
        target.preservePastedFormatting = true
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.rtfd], owner: nil); board.setData(rtfd, forType: .rtfd)
        XCTAssertFalse(board.types?.contains(payloadType) == true)
        XCTAssertTrue(target.readSelection(from: board)); try session.commit()
        let reopened = try XCTUnwrap(try NotesStore(directory: store.directory).document(id: session.note.id))
        XCTAssertEqual(reopened.blocks.map(\.kind), [.paragraph, .file, .image, .paragraph])
        XCTAssertEqual(reopened.blocks.first?.text, "粗体开头")
        XCTAssertEqual(reopened.blocks.last?.text, "尾文必须保留")
        XCTAssertEqual(reopened.attachments.map(\.name), ["附件.txt", "图片.png"])
        XCTAssertEqual(reopened.attachments.count, 2)
        for (attachment, expected) in zip(reopened.attachments, bytes) { XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), expected) }
        let rich = try XCTUnwrap(reopened.blocks.first?.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let font = try XCTUnwrap(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 24, accuracy: 0.02)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @MainActor func testExternalRTFDImportFailureCannotReplaceTheTargetSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-external-failed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (rtfd, _) = try externalRTFD(root)
        let store = try NotesStore(directory: root.appendingPathComponent("target"))
        var note = try store.create(); note.blocks = [NoteBlock(text: "不能被失败粘贴覆盖的原文")]; try store.update(note)
        let (target, session) = editor(note, store: store); target.selectAll(nil)
        let original = NSAttributedString(attributedString: target.attributedString()), selection = target.selectedRange()
        let folder = store.directory.appendingPathComponent("attachments")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try Data("不能作为目录写入".utf8).write(to: folder)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.rtfd], owner: nil); board.setData(rtfd, forType: .rtfd)
        XCTAssertFalse(target.readSelection(from: board))
        XCTAssertEqual(target.attributedString(), original)
        XCTAssertEqual(target.selectedRange(), selection)
        XCTAssertEqual(session.note.blocks, note.blocks)
        XCTAssertEqual(session.note.attachments, note.attachments)
        XCTAssertNotNil(session.attachmentFailure)
    }

    @MainActor func testOwnedClipboardRespectsMatchingAndPreservingPasteModesAtReadingScale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-clipboard-paste-mode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, note, _) = try fixture(root)
        let (source, _) = editor(note, store: store); source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        for preserve in [false, true] {
            let (target, session) = editor(try store.create(), store: store)
            target.readingScale = 1.33; target.preservePastedFormatting = preserve
            target.loadDocument(session.note)
            XCTAssertTrue(target.readSelection(from: board)); try session.commit()
            let rich = try XCTUnwrap(session.note.blocks.first?.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
            let font = try XCTUnwrap(rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, preserve ? 24 : NotesContinuousDocument.bodySize, accuracy: 0.02)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            XCTAssertEqual(rich.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 1)
            XCTAssertEqual(session.note.blocks.last?.kind, .checklist)
            XCTAssertEqual(session.note.blocks.last?.isChecked, true)
            XCTAssertEqual(session.note.attachments.count, 2)
        }
    }
}
