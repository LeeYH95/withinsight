import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class ContinuousEditingTests: XCTestCase {
    @MainActor private func editor(_ blocks: [NoteBlock]) -> NotesContinuousTextView {
        _ = NSApplication.shared
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.loadDocument(NoteDocument(blocks: blocks))
        XCTAssertFalse(view.string.isEmpty)
        return view
    }
    @MainActor func testTaskReturnContinuesAndEmptyReturnExitsWithoutLosingText() throws {
        let view = editor([NoteBlock(kind: .checklist, text: "第一项")])
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        let continued = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(continued.map(\.kind), [.checklist, .checklist])
        XCTAssertEqual(continued.map(\.text), ["第一项", ""])
        view.insertNewline(nil)
        let exited = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(exited.map(\.kind), [.checklist, .paragraph])
        XCTAssertEqual(exited.map(\.text), ["第一项", ""])
    }
    @MainActor func testSelectedParagraphHeadingAndMixedFontSizeAreIndependentOfReadingScale() throws {
        let view = editor([NoteBlock(text: "正文一"), NoteBlock(text: "正文二")])
        view.setSelectedRange(NSRange(location: 4, length: 3))
        view.setHeading(1)
        var blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2 else { return }
        XCTAssertEqual(blocks[0].markdown, "正文一")
        XCTAssertTrue(blocks[1].markdown?.hasPrefix("# ") == true)
        view.readingScale = 1.5
        view.loadDocument(NoteDocument(blocks: blocks))
        XCTAssertFalse(view.string.isEmpty)
        view.setSelectedRange(NSRange(location: 4, length: 1))
        view.setTextSize(32)
        blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), scale: 1.5)
        let rich = try XCTUnwrap(blocks[1].richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        XCTAssertEqual((rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 32, accuracy: 0.02)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 1))
    }
    @MainActor func testTaskMarkerDoesNotDeleteUserInputAndCrossParagraphDeletePreservesRemainingText() throws {
        let view = editor([NoteBlock(text: "一段"), NoteBlock(text: "二段")])
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.toggleList("checklist")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("新增", replacementRange: view.selectedRange())
        var blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertEqual(blocks.first?.text, "一段新增")
        XCTAssertEqual(blocks.first?.kind, .checklist)
        view.setSelectedRange(NSRange(location: 3, length: view.string.utf16.count - 4))
        view.deleteBackward(nil)
        blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
        XCTAssertTrue(blocks.map(\.text).joined().contains("一"))
        XCTAssertTrue(blocks.map(\.text).joined().contains("段"))
    }
    @MainActor func testCompositionStaysInNativeTextAndDoesNotPublishCandidates() throws {
        let view = editor([NoteBlock(text: "正文")])
        var publications = 0
        view.publish = { publications += 1 }
        view.setSelectedRange(NSRange(location:2,length:0))
        view.setMarkedText("nihao",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(publications,0)
        let candidate = view.string
        view.loadDocument(NoteDocument(blocks:[NoteBlock(text:"不允许覆盖候选")] ))
        XCTAssertEqual(view.string,candidate)
        view.insertText("你好",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string,"正文你好")
        XCTAssertGreaterThan(publications,0)
    }
    @MainActor func testAttachmentAtSelectionKeepsTextAndOwnedBytesThroughUndoRedoAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-insert-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try NotesStore(directory:root.appendingPathComponent("store"))
        var note = try store.create(); note.blocks = [NoteBlock(text:"前半后半")]; try store.update(note)
        let session = NotesEditorSession(note:note,store:store)
        session.undoManager.groupsByEvent = false
        let view = editor(note.blocks); view.session = session; session.textView = view
        view.blockID = note.blocks[0].id; session.focusedBlock = note.blocks[0].id
        view.setSelectedRange(NSRange(location:2,length:0))
        let file = root.appendingPathComponent("附件.txt"); try Data("完整附件".utf8).write(to:file)
        session.undoManager.beginUndoGrouping(); session.importURLs([file]); session.undoManager.endUndoGrouping()
        XCTAssertNil(session.attachmentFailure)
        XCTAssertEqual(session.note.blocks.map(\.text),["前半","附件.txt","后半"])
        let attachment = try XCTUnwrap(session.note.attachments.first)
        XCTAssertEqual(try Data(contentsOf:session.localURL(for:attachment)),Data("完整附件".utf8))
        session.undo(); try session.commit(); XCTAssertEqual(session.note.plainText,"前半后半")
        session.redo(); try session.commit()
        let reopened = try NotesStore(directory:store.directory)
        let restored = try XCTUnwrap(reopened.document(id:note.id))
        XCTAssertEqual(restored.blocks.map(\.text),["前半","附件.txt","后半"])
        XCTAssertEqual(try Data(contentsOf:reopened.url(for:restored.attachments[0])),Data("完整附件".utf8))
    }

    @MainActor func testMatchingPasteKeepsHeadingListAndEmphasisWhileNormalizingSourceFont() throws {
        let view = editor([NoteBlock(text:"原文")])
        let rich = NSMutableAttributedString(string:"标题\n列表项")
        let heading = NSMutableParagraphStyle(); heading.headerLevel = 1
        let list = NSMutableParagraphStyle(); list.textLists = [NSTextList(markerFormat:.disc,options:0)]
        rich.addAttributes([.paragraphStyle:heading,.font:NSFont.boldSystemFont(ofSize:40)],range:NSRange(location:0,length:3))
        rich.addAttributes([.paragraphStyle:list,.font:NSFont.systemFont(ofSize:26)],range:NSRange(location:3,length:3))
        view.selectAll(nil); view.insertPasted(rich)
        let blocks = try NotesContinuousDocument.blocks(from:view.attributedString())
        XCTAssertEqual(blocks.map(\.text),["标题","• 列表项"])
        XCTAssertTrue(blocks.first?.markdown?.hasPrefix("# ") == true)
        XCTAssertTrue(blocks.last?.markdown?.hasPrefix("- ") == true)
        let font = view.attributedString().attribute(.font,at:0,effectiveRange:nil) as? NSFont
        XCTAssertEqual(font?.pointSize ?? 0,NotesContinuousDocument.bodySize * 1.65,accuracy:0.02)
        XCTAssertTrue(font.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} == true)
    }

    @MainActor func testFormattingAcrossOwnedAttachmentsCannotTurnThemIntoTextOrDropReferences() throws {
        let attachment = NoteAttachment(name:"附件.txt",relativePath:"attachments/file.txt",kind:.file,byteCount:9)
        let blocks = [NoteBlock(text:"前文"),NoteBlock(kind:.file,text:attachment.name,attachmentID:attachment.id),NoteBlock(text:"后文")]
        let view = editor(blocks)
        view.selectAll(nil); view.toggleList("checklist"); view.setHeading(2)
        let result = try NotesContinuousDocument.blocks(from:view.attributedString())
        XCTAssertEqual(result.count,3)
        guard result.count == 3 else { return }
        XCTAssertEqual(result[1].kind,.file)
        XCTAssertEqual(result[1].attachmentID,attachment.id)
        XCTAssertEqual(result[1].text,attachment.name)
        XCTAssertEqual(result[0].text,"前文"); XCTAssertEqual(result[2].text,"后文")
    }
    @MainActor func testPreservePasteKeepsMixedSourceSizesAtDifferentReadingScale() throws {
        let view = editor([NoteBlock(text:"原文")]); view.readingScale = 1.33; view.preservePastedFormatting = true
        let value = NSMutableAttributedString(string:"小字大字")
        value.addAttribute(.font,value:NSFont.systemFont(ofSize:14),range:NSRange(location:0,length:2))
        value.addAttribute(.font,value:NSFont.boldSystemFont(ofSize:32),range:NSRange(location:2,length:2))
        view.selectAll(nil); view.insertPasted(value)
        let restored = try NotesContinuousDocument.blocks(from:view.attributedString(),scale:1.33)
        let rich = try XCTUnwrap(restored.first?.richText.flatMap { NSAttributedString(rtf:$0,documentAttributes:nil) })
        XCTAssertEqual((rich.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize ?? 0,14,accuracy:0.02)
        XCTAssertEqual((rich.attribute(.font,at:2,effectiveRange:nil) as? NSFont)?.pointSize ?? 0,32,accuracy:0.02)
    }

    @MainActor func testPastedMultilineTaskConversionKeepsOneCheckboxPerParagraphAfterReload() throws {
        let view = editor([NoteBlock(text:"第一行\n第二行\n第三行")])
        view.selectAll(nil); view.toggleList("checklist")
        let saved = try NotesContinuousDocument.blocks(from:view.attributedString(),trailingAttributes:view.trailingAttributes)
        XCTAssertEqual(saved.map(\.kind),[.checklist,.checklist,.checklist])
        XCTAssertEqual(saved.map(\.text),["第一行","第二行","第三行"])
        view.loadDocument(NoteDocument(blocks:saved))
        XCTAssertEqual(view.string.filter{$0 == "\u{FFFC}"}.count,3)
    }

    @MainActor func testResetFontSizeUsesTheParagraphDefaultWithoutRemovingHeading() throws {
        let view = editor([NoteBlock(text:"标题文字")])
        view.selectAll(nil); view.setHeading(1); view.setTextSize(32); view.setTextSize(nil)
        let font = view.attributedString().attribute(.font,at:0,effectiveRange:nil) as? NSFont
        XCTAssertEqual(font?.pointSize ?? 0,NotesContinuousDocument.bodySize * 1.65,accuracy:0.02)
        let blocks = try NotesContinuousDocument.blocks(from:view.attributedString())
        XCTAssertTrue(blocks.first?.markdown?.hasPrefix("# ") == true)
    }

    @MainActor func testSerializationFailureMustBlockCommitAndKeepLiveTextAvailableForCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continuous-encoding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try NotesStore(directory:root)
        let session = NotesEditorSession(note:try store.create(),store:store)
        let view = editor([NoteBlock(text:"尚未编码但仍在窗口中的最后输入")])
        session.textView = view; view.session = session
        session.pendingTextFailure = "模拟编码失败"; session.failure = "模拟编码失败"
        XCTAssertThrowsError(try session.commit())
        XCTAssertEqual(session.failure,"模拟编码失败")
        XCTAssertTrue(session.readableText.contains("最后输入"))
        view.publish = {
            session.pendingTextFailure = nil
            session.updateBlocks([NoteBlock(text:view.string)])
        }
        try session.commit()
        XCTAssertEqual(try NotesStore(directory:root).document(id:session.note.id)?.plainText,view.string)
    }

    @MainActor func testPlainClipboardAndEmptyRichAlternativeNeverDropNonemptyText() throws {
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType:type).map{(type,$0)} } } ?? []
        defer {
            board.clearContents()
            let items = previous.map { entries -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in entries { item.setData(data,forType:type) }; return item }
            board.writeObjects(items)
        }
        let view = editor([NoteBlock(text:"原文")])
        board.clearContents(); board.setString("第一行\n第二行",forType:.string)
        view.selectAll(nil); view.paste(nil)
        XCTAssertEqual(view.string,"第一行\n第二行")
        let empty = NSAttributedString(string:"")
        let data = try empty.data(from:NSRange(location:0,length:0),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        board.clearContents(); board.setString("文字不能被空富文本吞掉",forType:.string); board.setData(data,forType:.rtf)
        view.selectAll(nil); view.paste(nil)
        XCTAssertEqual(view.string,"文字不能被空富文本吞掉")
    }

}
