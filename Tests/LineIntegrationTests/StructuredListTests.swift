import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class StructuredListTests: XCTestCase {
    @MainActor private func editor(_ blocks: [NoteBlock]) -> NotesContinuousTextView {
        _ = NSApplication.shared
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.loadDocument(NoteDocument(blocks: blocks))
        return view
    }
    @MainActor private func blocks(_ view: NotesContinuousTextView) throws -> [NoteBlock] {
        try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes)
    }
    @MainActor func testTypingShortcutsConvertOnlyTheParagraphPrefix() throws {
        for prefix in ["1.", "12.", "-", "*", "+"] {
            let view = editor([NoteBlock(text: prefix)])
            view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
            view.insertText(" ", replacementRange: view.selectedRange())
            XCTAssertEqual(try blocks(view).first?.text, prefix.contains(".") ? "" : "• ")
            view.insertText("正文", replacementRange: view.selectedRange())
            XCTAssertEqual(try blocks(view).first?.markdown, prefix.contains(".") ? "\(prefix) 正文" : "- 正文")
        }
        let literal = editor([NoteBlock(text: "正文1.")])
        literal.setSelectedRange(NSRange(location: literal.string.utf16.count, length: 0))
        literal.insertText(" ", replacementRange: literal.selectedRange())
        XCTAssertEqual(literal.string, "正文1. ")
    }
    @MainActor func testMiddleInsertionRenumbersAndSurvivesReload() throws {
        let view = editor((1...3).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") })
        let firstEnd = (view.string as NSString).range(of: "\n").location
        view.setSelectedRange(NSRange(location: firstEnd, length: 0)); view.insertNewline(nil)
        view.insertText("插入", replacementRange: view.selectedRange())
        let result = try blocks(view)
        XCTAssertEqual(result.map(\.markdown), ["1. 条目1", "2. 插入", "3. 条目2", "4. 条目3"])
        view.loadDocument(NoteDocument(blocks: result))
        XCTAssertEqual(view.string, "1.\t条目1\n2.\t插入\n3.\t条目2\n4.\t条目3")
    }
    @MainActor func testDeletingTheFirstItemRetainsTheSequenceStartIncludingCustomStarts() throws {
        for start in [1, 8, 12] {
            let view = editor((start...(start + 2)).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") })
            let first = (view.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            view.setSelectedRange(first); view.deleteBackward(nil)
            XCTAssertEqual(try blocks(view).map(\.markdown), ["\(start). 条目\(start + 1)", "\(start + 1). 条目\(start + 2)"])
            let saved = try blocks(view)
            view.loadDocument(NoteDocument(blocks: saved))
            XCTAssertEqual(try blocks(view).map(\.markdown), saved.map(\.markdown))
            let body = (view.string as NSString).range(of: "条目\(start + 2)")
            view.setSelectedRange(body); view.insertTab(nil)
            XCTAssertEqual(try blocks(view).last?.markdown, "  1. 条目\(start + 2)", "A new nested scope starts at one")
        }
    }
    @MainActor func testIndentHasTwoLevelsAndNumberingResumesInItsParentScope() throws {
        let view = editor((1...4).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") })
        let second = (view.string as NSString).range(of: "条目2")
        view.setSelectedRange(second); view.insertTab(nil); view.insertTab(nil)
        XCTAssertEqual(try blocks(view).map(\.markdown), ["1. 条目1", "  1. 条目2", "2. 条目3", "3. 条目4"])
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "条目2")
        view.insertBacktab(nil)
        XCTAssertEqual(try blocks(view).map(\.markdown), (1...4).map { "\($0). 条目\($0)" })
    }
    @MainActor func testEnterContinuesThenOutdentsThenExitsEmptyNestedLists() throws {
        for markdown in ["  1. 正文", "  - 正文"] {
            let view = editor([NoteBlock(text: markdown.contains("1.") ? "正文" : "• 正文", markdown: markdown)])
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); view.insertNewline(nil)
            XCTAssertEqual(try blocks(view).count, 2)
            XCTAssertTrue(try XCTUnwrap(blocks(view).last?.markdown).hasPrefix(markdown.contains("1.") ? "  2." : "  -"))
            view.insertNewline(nil)
            XCTAssertTrue(try XCTUnwrap(blocks(view).last?.markdown).hasPrefix(markdown.contains("1.") ? "1." : "-"))
            view.insertNewline(nil)
            XCTAssertEqual(try blocks(view).last?.text, "")
            XCTAssertEqual(try blocks(view).last?.markdown, "")
        }
    }
    @MainActor func testRemovingSeparatorMergesBodiesWithoutSyntheticMarkers() throws {
        let view = editor([NoteBlock(text: "甲", markdown: "1. 甲"), NoteBlock(text: "乙", markdown: "2. 乙")])
        let separator = (view.string as NSString).range(of: "\n")
        view.setSelectedRange(separator); view.deleteBackward(nil)
        XCTAssertEqual(try blocks(view).map(\.text), ["甲乙"])
        XCTAssertEqual(view.string, "1.\t甲乙")
    }
    @MainActor func testSplittingAnOrderedBodyKeepsTrailingTextAndItsLink() throws {
        let rich = NSAttributedString(string: "前半后半", attributes: [.font: NSFont.systemFont(ofSize: 18), .link: URL(string: "https://example.com")!])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let view = editor([NoteBlock(text: rich.string, richText: rtf, markdown: "1. [前半后半](https://example.com)")])
        let body = (view.string as NSString).range(of: "前半后半")
        view.setSelectedRange(NSRange(location: body.location + 2, length: 0)); view.insertNewline(nil)
        XCTAssertEqual(try blocks(view).map(\.text), ["前半", "后半"])
        XCTAssertEqual(try blocks(view).map(\.markdown), ["1. [前半](https://example.com)", "2. [后半](https://example.com)"])
    }
    @MainActor func testIndentingTheTenthItemKeepsItsBodySelectedWhenMarkerShrinks() throws {
        let view = editor((1...10).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") })
        view.setSelectedRange((view.string as NSString).range(of: "条目10")); view.insertTab(nil)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "条目10")
        XCTAssertEqual(try blocks(view).last?.markdown, "  1. 条目10")
        view.insertBacktab(nil)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "条目10")
        XCTAssertEqual(try blocks(view).last?.markdown, "10. 条目10")
    }
    @MainActor func testNestedListsRoundTripWithoutChangingBodyLinksOrLegacyNotes() throws {
        let rich = NSAttributedString(string: "链接", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .link: URL(string: "https://example.com")!])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let original = [NoteBlock(text: "旧段落"), NoteBlock(text: "• 旧列表", markdown: "- 旧列表"), NoteBlock(text: "链接", richText: rtf, markdown: "  1. [**链接**](https://example.com)"), NoteBlock(kind: .checklist, text: "待办", markdown: "  - [ ] 待办")]
        let view = editor(original), saved = try blocks(view)
        XCTAssertEqual(saved.map(\.text), original.map(\.text))
        XCTAssertEqual(saved[2].markdown, original[2].markdown)
        XCTAssertEqual(saved[3].markdown, original[3].markdown)
        view.loadDocument(NoteDocument(blocks: saved))
        let linkRange = (view.string as NSString).range(of: "链接")
        XCTAssertEqual(NotesWebLink.destination(from: view.attributedString().attribute(.link, at: linkRange.location, effectiveRange: nil))?.absoluteString, "https://example.com")
        XCTAssertEqual(view.attributedString().attribute(.notesListLevel, at: linkRange.location, effectiveRange: nil) as? Int, 1)
    }
    @MainActor func testHistoricalLiteralNumberedParagraphIsNotConvertedOnLoad() throws {
        let view = editor([NoteBlock(text: "1. 历史原文", markdown: "1. 历史原文")])
        XCTAssertEqual(view.string, "1. 历史原文")
        XCTAssertEqual(try blocks(view).first?.text, "1. 历史原文")
    }
    @MainActor func testNestedSequencesRestartForEachParentAndRootContinuesPastChildren() throws {
        let values = [("父甲", "1. 父甲"), ("子甲", "  1. 子甲"), ("子乙", "  2. 子乙"), ("父乙", "2. 父乙"), ("子丙", "  1. 子丙"), ("正文", "正文"), ("另起", "1. 另起")]
        let view = editor(values.map { NoteBlock(text: $0.0, markdown: $0.1) })
        XCTAssertEqual(try blocks(view).map(\.markdown), values.map { $0.1 })
    }
    @MainActor func testRenumberingAcrossTwoDigitsMapsTheSelectionToTheSameBody() throws {
        let note = NoteDocument(blocks: (8...10).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") })
        let value = NSMutableAttributedString(attributedString: NotesContinuousDocument.render(note))
        let prefix = NSMutableAttributedString(attributedString: NotesContinuousDocument.render(NoteDocument(blocks: [NoteBlock(text: "新增", markdown: "8. 新增")])))
        var separator = prefix.attributes(at: 0, effectiveRange: nil); separator.removeValue(forKey: .notesMarker)
        prefix.append(NSAttributedString(string: "\n", attributes: separator))
        value.insert(prefix, at: 0)
        let original = (value.string as NSString).range(of: "条目10")
        let mapped = NotesListEditing.normalize(value, selection: original)
        XCTAssertEqual((value.string as NSString).substring(with: mapped), "条目10")
        XCTAssertEqual(mapped.location, original.location + 1)
        XCTAssertEqual(try NotesContinuousDocument.blocks(from: value).map(\.markdown), ["8. 新增", "9. 条目8", "10. 条目9", "11. 条目10"])
    }
    @MainActor func testOrderedRTFPasteDoesNotBecomeBulletsOrDuplicateNumbers() throws {
        let view = editor([NoteBlock(text: "替换")])
        let value = NSMutableAttributedString(string: "1.\t甲\n2.\t乙")
        let style = NSMutableParagraphStyle(); style.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        value.addAttributes([.font: NSFont.systemFont(ofSize: 18), .paragraphStyle: style], range: NSRange(location: 0, length: value.length))
        view.selectAll(nil); XCTAssertTrue(view.insertPasted(value))
        XCTAssertEqual(try blocks(view).map(\.text), ["甲", "乙"])
        XCTAssertEqual(try blocks(view).map(\.markdown), ["1. 甲", "2. 乙"])
    }
    @MainActor func testOrderedRTFPastePreservesStartingNumberStoredOnlyInListMetadata() throws {
        let view = editor([NoteBlock()])
        let value = NSMutableAttributedString(string: "甲\n乙")
        let list = NSTextList(markerFormat: .decimal, options: 0); list.startingItemNumber = 12
        let style = NSMutableParagraphStyle(); style.textLists = [list]
        value.addAttributes([.font: NSFont.systemFont(ofSize: 18), .paragraphStyle: style], range: NSRange(location: 0, length: value.length))
        XCTAssertTrue(view.insertPasted(value))
        XCTAssertEqual(try blocks(view).map(\.markdown), ["12. 甲", "13. 乙"])
    }
    @MainActor func testMultilineListPasteIntoEmptyAndMiddleTextKeepsParagraphBoundaries() throws {
        let value = NSMutableAttributedString(string: "1.\t甲\n2.\t乙")
        let style = NSMutableParagraphStyle(); style.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        value.addAttributes([.font: NSFont.systemFont(ofSize: 18), .paragraphStyle: style], range: NSRange(location: 0, length: value.length))
        for existing in ["", "前后"] {
            let view = editor([NoteBlock(text: existing)])
            view.setSelectedRange(NSRange(location: existing.isEmpty ? 0 : 1, length: 0))
            XCTAssertTrue(view.insertPasted(value))
            XCTAssertEqual(try blocks(view).map(\.markdown), existing.isEmpty ? ["1. 甲", "2. 乙"] : ["前", "1. 甲", "2. 乙", "后"])
        }
    }
    @MainActor func testResizedOrderedMarkerMatchesItsBodyAndWrappedTextColumn() throws {
        let view = editor([NoteBlock(text: "有序正文", markdown: "10. 有序正文")])
        let body = (view.string as NSString).range(of: "有序正文")
        view.setSelectedRange(body); view.setTextSize(32)
        let value = view.attributedString()
        let markerFont = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(value.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(markerFont.pointSize, bodyFont.pointSize, accuracy: 0.02)
        XCTAssertEqual(markerFont.pointSize, 32, accuracy: 0.02)
        let style = try XCTUnwrap(value.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let markerWidth = ("10." as NSString).size(withAttributes: [.font: markerFont]).width
        XCTAssertGreaterThan(style.headIndent, markerWidth)
        XCTAssertEqual(style.tabStops.first?.location, style.headIndent)
        let saved = try blocks(view)
        view.readingScale = 1.33; view.loadDocument(NoteDocument(blocks: saved))
        XCTAssertEqual((view.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 32 * 1.33, accuracy: 0.02)
    }
    @MainActor func testOwnedClipboardKeepsNumbersAndNestingAndAcceptsOldV1Payloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structured-list-clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let note = try store.create(), session = NotesEditorSession(note: note, store: store)
        let source = editor([NoteBlock(text: "父", markdown: "1. 父"), NoteBlock(text: "• 子", markdown: "  - 子"), NoteBlock(text: "尾", markdown: "2. 尾")])
        source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let target = editor(note.blocks); target.session = session; session.textView = target
        XCTAssertTrue(target.readSelection(from: board))
        XCTAssertEqual(session.note.blocks.map(\.markdown), ["1. 父", "  - 子", "2. 尾"])
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(board.data(forType: NotesContinuousTextView.ownedSelectionType))) as? [String: Any])
        var oldBlocks = try XCTUnwrap(payload["blocks"] as? [[String: Any]])
        for index in oldBlocks.indices { for key in ["listKind", "listLevel", "listNumber"] { oldBlocks[index].removeValue(forKey: key) } }
        payload["blocks"] = oldBlocks
        board.setData(try JSONSerialization.data(withJSONObject: payload), forType: NotesContinuousTextView.ownedSelectionType)
        target.selectAll(nil); XCTAssertTrue(target.readSelection(from: board), "Existing version-one clipboard values have no list metadata")
        XCTAssertEqual(session.note.blocks.map(\.text), ["父", "• 子", "尾"])
    }
    @MainActor func testOwnedListClipboardInMiddleTextKeepsBothSurroundingParagraphs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structured-list-middle-paste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        var note = try store.create(); note.blocks = [NoteBlock(text: "前后")]; try store.update(note)
        let session = NotesEditorSession(note: note, store: store)
        let source = editor([NoteBlock(text: "甲", markdown: "1. 甲"), NoteBlock(text: "乙", markdown: "2. 乙")])
        source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let target = editor(note.blocks); target.session = session; session.textView = target
        target.setSelectedRange(NSRange(location: 1, length: 0)); XCTAssertTrue(target.readSelection(from: board))
        XCTAssertEqual(session.note.blocks.map(\.markdown), ["前", "1. 甲", "2. 乙", "后"])
    }
    @MainActor func testMiddleInsertionUndoRedoRestoresNumbersAndCaretAcrossTwoDigits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("structured-list-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        var note = try store.create(); note.blocks = (8...10).map { NoteBlock(text: "条目\($0)", markdown: "\($0). 条目\($0)") }; try store.update(note)
        let session = NotesEditorSession(note: note, store: store); session.undoManager.groupsByEvent = false
        let coordinator = NotesContinuousBody(session: session, scale: 1, onHeight: { _ in }, onAttachment: { _ in }).makeCoordinator()
        let view = editor(note.blocks); view.session = session; session.textView = view; view.delegate = coordinator; coordinator.view = view
        view.publish = { coordinator.publish() }; coordinator.load()
        let original = view.string, selection = NSRange(location: (view.string as NSString).range(of: "\n").location, length: 0)
        view.setSelectedRange(selection)
        session.undoManager.beginUndoGrouping(); view.insertNewline(nil); view.insertText("新增", replacementRange: view.selectedRange()); session.undoManager.endUndoGrouping()
        let result = view.string, caret = view.selectedRange()
        XCTAssertEqual(session.note.blocks.map(\.markdown), ["8. 条目8", "9. 新增", "10. 条目9", "11. 条目10"])
        session.undo(); coordinator.load(); XCTAssertEqual(view.string, original); XCTAssertEqual(view.selectedRange(), selection)
        session.redo(); coordinator.load(); XCTAssertEqual(view.string, result); XCTAssertEqual(view.selectedRange(), caret)
    }
}
