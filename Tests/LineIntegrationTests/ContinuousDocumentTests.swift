import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class ContinuousDocumentTests: XCTestCase {
    @MainActor func testTypingOverAttachmentFirstSelectionReplacesSelectedDocument() throws {
        _ = NSApplication.shared
        for kind in [NoteBlock.Kind.file, .image] {
            for explicitRange in [true, false] {
                let attachment = NoteAttachment(name: "资料", relativePath: "attachments/fixture", kind: kind == .image ? .image : .file, byteCount: 9)
                let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
                view.loadDocument(NoteDocument(blocks: [NoteBlock(kind: kind, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "原正文")], attachments: [attachment]))
                view.selectAll(nil)
                view.insertText("替换", replacementRange: explicitRange ? view.selectedRange() : NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual(view.string, "替换")
                let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
                XCTAssertEqual(saved.map(\.text), ["替换"])
                XCTAssertTrue(saved.compactMap(\.attachmentID).isEmpty)
            }
        }
    }

    @MainActor func testPlainTextPasteStartingAtAttachmentReplacesSelectionAndKeepsTail() throws {
        _ = NSApplication.shared
        for kind in [NoteBlock.Kind.file, .image] {
            let attachment = NoteAttachment(name: "资料", relativePath: "attachments/fixture", kind: kind == .image ? .image : .file, byteCount: 9)
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
            view.loadDocument(NoteDocument(blocks: [NoteBlock(kind: kind, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "保留后文")], attachments: [attachment]))
            view.setSelectedRange(NSRange(location: 0, length: 3))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.declareTypes([.string], owner: nil); board.setString("替换", forType: .string)
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertEqual(view.string, "替换留后文")
            let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
            XCTAssertEqual(saved.map(\.text), ["替换留后文"])
            XCTAssertTrue(saved.compactMap(\.attachmentID).isEmpty)
        }
    }

    @MainActor func testCaretBeforeAttachmentStillInsertsAnAdjacentParagraph() throws {
        _ = NSApplication.shared
        let attachment = NoteAttachment(name: "资料.txt", relativePath: "attachments/fixture.txt", kind: .file, byteCount: 9)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.loadDocument(NoteDocument(blocks: [NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "原正文")], attachments: [attachment]))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("前文", replacementRange: view.selectedRange())
        let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(saved.map(\.text), ["前文", "资料.txt", "原正文"])
        XCTAssertEqual(saved.compactMap(\.attachmentID), [attachment.id])
    }

    @MainActor func testLegacyMixedDocumentKeepsEveryBlockAndAttachmentInOrder() throws {
        _ = NSApplication.shared
        let attachment = NoteAttachment(name: "资料.txt", relativePath: "assets/test.txt", kind: .file, byteCount: 9)
        let original = [NoteBlock(text: "第一段\n还有一行"), NoteBlock(kind: .checklist, text: "中文待办", isChecked: true), NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "最后一段")]
        let note = NoteDocument(blocks: original, attachments: [attachment])
        let rendered = NotesContinuousDocument.render(note)
        let restored = try NotesContinuousDocument.blocks(from: rendered)
        XCTAssertEqual(restored.map(\.text), original.map(\.text))
        XCTAssertEqual(restored.map(\.kind), original.map(\.kind))
        XCTAssertEqual(restored.map(\.id), original.map(\.id))
        guard restored.count == original.count else { return }
        XCTAssertEqual(restored[1].isChecked, true)
        XCTAssertEqual(restored[2].attachmentID, attachment.id)
    }
    @MainActor func testReadingScaleDoesNotRewriteMixedOriginalFontSizesOrEmphasis() throws {
        _ = NSApplication.shared
        let value = NSMutableAttributedString(string: "小字大字")
        value.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: 2))
        value.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 32), range: NSRange(location: 2, length: 2))
        let data = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let note = NoteDocument(blocks: [NoteBlock(text: value.string, richText: data)])
        let displayed = NotesContinuousDocument.render(note, scale: 1.33)
        XCTAssertGreaterThan(displayed.length, 0)
        guard displayed.length > 0 else { return }
        XCTAssertEqual((displayed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 14 * 1.33, accuracy: 0.02)
        let restored = try XCTUnwrap(NotesContinuousDocument.blocks(from: displayed, scale: 1.33).first)
        let rich = try XCTUnwrap(restored.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        XCTAssertEqual((rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 14, accuracy: 0.02)
        let font = try XCTUnwrap(rich.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.02)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
    @MainActor func testHeadingAndBulletSemanticsSurviveSaveAndReopen() throws {
        _ = NSApplication.shared
        let original = [NoteBlock(text: "重要标题", markdown: "# 重要标题"), NoteBlock(text: "• 列表项目", markdown: "- 列表项目"), NoteBlock(kind: .checklist, text: "", isChecked: false)]
        let rendered = NotesContinuousDocument.render(NoteDocument(blocks: original))
        let restored = try NotesContinuousDocument.blocks(from: rendered)
        XCTAssertEqual(restored.count, 3)
        guard restored.count == original.count else { return }
        XCTAssertTrue(restored[0].markdown?.hasPrefix("# ") == true)
        XCTAssertTrue(restored[1].markdown?.hasPrefix("- ") == true)
        XCTAssertEqual(restored[2].kind, .checklist)
        XCTAssertEqual(restored[2].text, "")
    }
    @MainActor func testParagraphGeometryScalesWithReadingSize() throws {
        _ = NSApplication.shared
        let note = NoteDocument(blocks: [NoteBlock(kind: .checklist, text: "很长的一条待办，需要保持所有换行对齐。")])
        let normal = NotesContinuousDocument.render(note)
        let large = NotesContinuousDocument.render(note, scale: 1.5)
        XCTAssertGreaterThan(normal.length, 0)
        guard normal.length > 0, large.length > 0 else { return }
        let a = try XCTUnwrap(normal.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let b = try XCTUnwrap(large.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(a.headIndent, 0)
        XCTAssertEqual(b.headIndent, a.headIndent * 1.5, accuracy: 0.02)
        XCTAssertEqual(b.paragraphSpacing, a.paragraphSpacing * 1.5, accuracy: 0.02)
    }

    @MainActor func testDeletingEitherAttachmentBoundaryKeepsTheAttachmentAndBothTextSides() throws {
        _ = NSApplication.shared
        let attachment = NoteAttachment(name: "资料.txt", relativePath: "attachments/fixture.txt", kind: .file, byteCount: 9)
        let original = [NoteBlock(text: "A"), NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "B")]
        for boundary in [1, 3] {
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
            view.loadDocument(NoteDocument(blocks: original, attachments: [attachment]))
            XCTAssertEqual(view.string, "A\n\u{FFFC}\nB")
            view.setSelectedRange(NSRange(location: boundary, length: 1))
            view.deleteBackward(nil)
            let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
            XCTAssertEqual(saved.map(\.kind), [.paragraph, .file, .paragraph], "Boundary \(boundary)")
            XCTAssertEqual(saved.map(\.text), ["A", attachment.name, "B"], "Boundary \(boundary)")
            XCTAssertEqual(saved.compactMap(\.attachmentID), [attachment.id], "Boundary \(boundary)")
            XCTAssertEqual(Set(saved.map(\.id)).count, saved.count)
        }
    }

    @MainActor func testCrossParagraphReplacementBesideAttachmentKeepsUnselectedContents() throws {
        _ = NSApplication.shared
        let attachment = NoteAttachment(name: "资料.txt", relativePath: "attachments/fixture.txt", kind: .file, byteCount: 9)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.loadDocument(NoteDocument(blocks: [NoteBlock(text: "A"), NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id), NoteBlock(text: "B")], attachments: [attachment]))
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.insertText("替换", replacementRange: view.selectedRange())
        let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(saved.map(\.kind), [.paragraph, .file, .paragraph])
        XCTAssertEqual(saved.map(\.text), ["替换", attachment.name, "B"])
        XCTAssertEqual(saved.compactMap(\.attachmentID), [attachment.id])
    }

    @MainActor func testJoinedTextAndMultipleAttachmentsKeepOwnedBytesAfterSaveAndReopen() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-joined-assets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        var note = try store.create()
        let fixtures = [("资料.txt", Data("完整的文件内容".utf8)), ("图片.png", Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVvQAAAAASUVORK5CYII=")!)]
        var attachments: [NoteAttachment] = []
        for (name, data) in fixtures {
            let source = root.appendingPathComponent(name)
            try data.write(to: source)
            attachments.append(try store.importAttachment(from: source, to: note.id))
        }
        note = try XCTUnwrap(store.document(id: note.id))
        note.blocks = [NoteBlock(text: "前"), NoteBlock(kind: .file, text: attachments[0].name, attachmentID: attachments[0].id), NoteBlock(text: "中"), NoteBlock(kind: .image, text: attachments[1].name, attachmentID: attachments[1].id), NoteBlock(text: "尾")]
        try store.update(note)
        let joined = NSMutableAttributedString(attributedString: NotesContinuousDocument.render(note, scale: 1.33))
        for index in (0..<joined.length).reversed() where (joined.string as NSString).substring(with: NSRange(location: index, length: 1)) == "\n" {
            joined.deleteCharacters(in: NSRange(location: index, length: 1))
        }
        // Native edits can leave one block identity on several sides of an attachment.
        joined.addAttribute(.notesBlock, value: note.blocks[0].id.uuidString, range: NSRange(location: 0, length: joined.length))
        joined.addAttribute(.font, value: NSFont.systemFont(ofSize: 14 * 1.33), range: NSRange(location: 0, length: 1))
        joined.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 32 * 1.33), range: NSRange(location: joined.length - 1, length: 1))
        let saved = try NotesContinuousDocument.blocks(from: joined, scale: 1.33)
        XCTAssertEqual(saved.map(\.kind), [.paragraph, .file, .paragraph, .image, .paragraph])
        XCTAssertEqual(saved.map(\.text), ["前", attachments[0].name, "中", attachments[1].name, "尾"])
        XCTAssertEqual(saved.compactMap(\.attachmentID), attachments.map(\.id))
        XCTAssertEqual(Set(saved.map(\.id)).count, saved.count)
        let session = NotesEditorSession(note: note, store: store)
        session.updateBlocks(saved)
        try session.commit()
        let reopened = try NotesStore(directory: store.directory)
        let restored = try XCTUnwrap(reopened.document(id: note.id))
        XCTAssertEqual(restored.blocks.map(\.text), saved.map(\.text))
        XCTAssertEqual(restored.blocks.compactMap(\.attachmentID), attachments.map(\.id))
        for (index, attachment) in restored.attachments.enumerated() {
            XCTAssertEqual(try Data(contentsOf: reopened.url(for: attachment)), fixtures[index].1)
        }
        let roundTrip = try NotesContinuousDocument.blocks(from: NotesContinuousDocument.render(restored))
        XCTAssertEqual(roundTrip.map(\.kind), saved.map(\.kind))
        XCTAssertEqual(roundTrip.map(\.text), saved.map(\.text))
        XCTAssertEqual(Set(roundTrip.map(\.id)).count, roundTrip.count)
        let first = try XCTUnwrap(saved.first?.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let last = try XCTUnwrap(saved.last?.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        XCTAssertEqual((first.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 14, accuracy: 0.02)
        XCTAssertEqual((last.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 32, accuracy: 0.02)
    }
}
