import AppKit
import Combine
import NotesCore
import XCTest
@testable import Tendedero

final class LinkTitlePasteTests: XCTestCase {
    @MainActor func testURLPastesImmediatelyThenBecomesTitleWithOriginalDestination() throws {
        let f = try LinkFixture(); defer { f.clean() }
        let address = "https://example.com/article?x=1&y=2#part"
        XCTAssertTrue(f.paste(address))
        XCTAssertEqual(f.view.string, address)
        XCTAssertEqual(f.target(at: 0), address)
        XCTAssertEqual(f.loader.urls.map(\.absoluteString), [address])
        f.loader.complete(0, " \n示例网页\t ")
        XCTAssertEqual(f.view.string, "示例网页")
        XCTAssertEqual(f.target(at: 0), address)
    }

    @MainActor func testFailedAndEmptyTitlesLeaveUsableURL() throws {
        for title in [nil, " \n\t "] as [String?] {
            let f = try LinkFixture(); defer { f.clean() }
            XCTAssertTrue(f.paste("https://example.com"))
            f.loader.complete(0, title)
            XCTAssertEqual(f.view.string, "https://example.com")
            XCTAssertEqual(f.target(at: 0), "https://example.com")
        }
    }

    @MainActor func testMixedTextAndNonWebSchemesAreNotFetched() throws {
        for value in ["参考 https://example.com", "https://a.example\nhttps://b.example", "javascript:alert(1)", "mailto:a@example.com"] {
            let f = try LinkFixture(); defer { f.clean() }
            XCTAssertTrue(f.paste(value))
            XCTAssertEqual(f.view.string, value)
            XCTAssertTrue(f.loader.urls.isEmpty)
        }
    }

    @MainActor func testTypingBeforeAndAfterPendingLinkSurvivesAndCaretStaysAtEnd() async throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/article"))
        f.view.insertText("前言\n", replacementRange: NSRange(location: 0, length: 0))
        f.view.setSelectedRange(NSRange(location: f.view.string.utf16.count, length: 0))
        f.view.insertText(" 后记", replacementRange: f.view.selectedRange())
        f.loader.complete(0, "网页标题")
        await f.waitForText("前言\n网页标题 后记")
        XCTAssertEqual(f.view.string, "前言\n网页标题 后记")
        XCTAssertEqual(f.view.selectedRange(), NSRange(location: f.view.string.utf16.count, length: 0))
        XCTAssertEqual(f.target(at: 3), "https://example.com/article")
        XCTAssertNil(f.target(at: f.view.string.utf16.count - 1))
    }

    @MainActor func testEditingPendingURLPreventsLateTitleFromOverwritingIt() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/article"))
        f.view.insertText("custom", replacementRange: NSRange(location: 8, length: 7))
        let edited = f.view.string
        f.loader.complete(0, "不应覆盖")
        XCTAssertEqual(f.view.string, edited)
    }

    @MainActor func testDeletedPendingURLCannotBeResurrected() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.view.setSelectedRange(NSRange(location: 0, length: f.view.string.utf16.count))
        f.view.deleteBackward(nil)
        f.loader.complete(0, "不应复活")
        XCTAssertEqual(f.view.string, "")
    }

    @MainActor func testIdenticalURLsHaveIndependentOutOfOrderResults() async throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.view.insertNewline(nil)
        XCTAssertTrue(f.paste("https://example.com"))
        f.loader.complete(1, "第二个标题")
        f.loader.complete(0, "第一个标题")
        await f.waitForText("第一个标题\n第二个标题")
        XCTAssertEqual(f.view.string, "第一个标题\n第二个标题")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
        XCTAssertEqual(f.target(at: 6), "https://example.com")
    }

    @MainActor func testUndoBeforeCompletionDoesNotResurrectPasteAndRedoKeepsURL() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.session.undo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "")
        f.loader.complete(0, "迟到的标题")
        XCTAssertEqual(f.view.string, "")
        f.session.redo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "https://example.com")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
    }

    @MainActor func testAutomaticTitleReplacementHasItsOwnUndoBoundary() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.loader.complete(0, "示例标题")
        f.session.undo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "https://example.com")
        f.session.redo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "示例标题")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
    }

    @MainActor func testSavingAndReopeningPreservesTargetWithoutPendingRequestToken() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/article"))
        f.loader.complete(0, "持久化标题")
        try f.session.commit()
        let reopened = try NotesStore(directory: f.store.directory)
        let note = try XCTUnwrap(reopened.document(id: f.session.note.id))
        let rendered = NotesContinuousDocument.render(note)
        XCTAssertEqual(rendered.string, "持久化标题")
        XCTAssertEqual(NotesWebLink.destination(from: rendered.attribute(.link, at: 0, effectiveRange: nil))?.absoluteString, "https://example.com/article")
        XCTAssertNil(rendered.attribute(.notesPendingLink, at: 0, effectiveRange: nil))
    }

    @MainActor func testCommandClickOpensOriginalURLAndNormalClickDoesNotActivate() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "原始目标")
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        XCTAssertFalse(f.view.activateLink(at: 0, modifiers: []))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(f.view.activateLink(at: 0, modifiers: .command))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/original"])
    }

    @MainActor func testNewTextAfterResolvedLinkDoesNotInheritItsTarget() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.loader.complete(0, "标题")
        f.view.insertText(" 后面的正文", replacementRange: f.view.selectedRange())
        XCTAssertEqual(f.view.string, "标题 后面的正文")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
        XCTAssertNil(f.target(at: 3))
    }

    @MainActor func testSynchronousCachedTitleIsNotLostOrAppliedTwice() throws {
        let f = try LinkFixture(); defer { f.clean() }
        f.view.linkPastes.loadTitle = { _, completion in
            completion("同步标题")
            completion("重复回调")
            return AnyCancellable {}
        }
        XCTAssertTrue(f.paste("https://example.com"))
        XCTAssertEqual(f.view.string, "同步标题")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
    }

    @MainActor func testTitleWaitsForMarkedTextWithoutChangingComposition() async throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.view.setMarkedText("正在输入", selectedRange: NSRange(location: 4, length: 0), replacementRange: f.view.selectedRange())
        XCTAssertTrue(f.view.hasMarkedText())
        let composing = f.view.string
        f.loader.complete(0, "网页标题")
        XCTAssertEqual(f.view.string, composing)
        XCTAssertTrue(f.view.hasMarkedText())
        f.view.unmarkText()
        await f.waitForText("网页标题正在输入")
        XCTAssertEqual(f.view.string, "网页标题正在输入")
        XCTAssertNil(f.target(at: f.view.string.utf16.count - 1))
    }

    @MainActor func testReloadInvalidatesOldRequestWithoutOverwritingNewContent() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.session.note.blocks = [NoteBlock(text: "新的正文")]
        f.view.loadDocument(f.session.note)
        f.loader.complete(0, "旧标题")
        XCTAssertEqual(f.view.string, "新的正文")
    }

    @MainActor func testUndoInvalidatesTitleBeforeTheViewHasReloaded() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.session.undo()
        f.loader.complete(0, "不能复活")
        XCTAssertEqual(f.session.note.plainText, "")
        f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "")
    }

    @MainActor func testURLShapedRichLinkLabelKeepsItsDifferentDestination() throws {
        let f = try LinkFixture(); defer { f.clean() }
        let label = "https://display.example"
        let rich = NSAttributedString(string: label, attributes: [.link: URL(string: "https://actual.example/article")!])
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(label, forType: .string)
        board.setData(try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        XCTAssertTrue(f.view.readSelection(from: board))
        XCTAssertTrue(f.loader.urls.isEmpty)
        XCTAssertEqual(f.view.string, label)
        XCTAssertEqual(f.target(at: 0), "https://actual.example/article")
    }

    @MainActor func testTitleUndoDoesNotUndoCommittedComposition() async throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.view.setMarkedText("确认文字", selectedRange: NSRange(location: 4, length: 0), replacementRange: f.view.selectedRange())
        f.loader.complete(0, "网页标题")
        f.view.unmarkText()
        await f.waitForText("网页标题确认文字")
        f.session.undo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.view.string, "https://example.com确认文字")
    }

    @MainActor func testCompositionConfirmationThroughInsertTextFinishesDeferredTitle() async throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.view.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: f.view.selectedRange())
        f.loader.complete(0, "网页标题")
        f.view.insertText("确认", replacementRange: f.view.markedRange())
        XCTAssertFalse(f.view.hasMarkedText())
        await f.waitForText("网页标题确认")
        XCTAssertEqual(f.view.string, "网页标题确认")
    }

    @MainActor func testNativeURLPasteboardFlavorAlsoFetchesTitle() throws {
        let f = try LinkFixture(); defer { f.clean() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("https://example.com", forType: .URL)
        XCTAssertTrue(f.view.readSelection(from: board))
        XCTAssertEqual(f.loader.urls.count, 1)
        if !f.loader.urls.isEmpty { f.loader.complete(0, "原生网址") }
        XCTAssertEqual(f.view.string, "原生网址")
    }

    @MainActor func testGenericRichPasteCannotImportPendingRequestMarkers() throws {
        let f = try LinkFixture(); defer { f.clean() }
        let rich = NSAttributedString(string: "普通内容", attributes: [.notesPendingLink: UUID().uuidString])
        XCTAssertTrue(f.view.insertPasted(rich))
        XCTAssertNil(f.view.attributedString().attribute(.notesPendingLink, at: 0, effectiveRange: nil))
    }

    @MainActor func testReplacingSelectedCharactersWithinTitleKeepsItsTarget() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "网页标题")
        f.view.setSelectedRange(NSRange(location: 2, length: 2))
        f.view.insertText("链接", replacementRange: f.view.selectedRange())
        XCTAssertEqual(f.view.string, "网页链接")
        for index in 0..<4 { XCTAssertEqual(f.target(at: index), "https://example.com/original") }
    }

    @MainActor func testReplacingMixedLinkedAndPlainSelectionDoesNotExtendTarget() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com"))
        f.loader.complete(0, "链接")
        f.view.insertText("正文", replacementRange: f.view.selectedRange())
        f.view.setSelectedRange(NSRange(location: 1, length: 2))
        f.view.insertText("改", replacementRange: f.view.selectedRange())
        XCTAssertEqual(f.view.string, "链改文")
        XCTAssertEqual(f.target(at: 0), "https://example.com")
        XCTAssertNil(f.target(at: 1))
    }
}

@MainActor private final class DeferredLinkTitles {
    var urls: [URL] = []
    var callbacks: [@MainActor (String?) -> Void] = []
    func load(_ url: URL, completion: @escaping @MainActor (String?) -> Void) -> AnyCancellable {
        urls.append(url); callbacks.append(completion)
        return AnyCancellable {}
    }
    func complete(_ index: Int, _ title: String?) { callbacks[index](title) }
}

@MainActor private final class LinkFixture {
    let root: URL
    let store: NotesStore
    let session: NotesEditorSession
    let view: NotesContinuousTextView
    let loader = DeferredLinkTitles()
    init() throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("link-title-tests-" + UUID().uuidString)
        store = try NotesStore(directory: root)
        session = NotesEditorSession(note: try store.create(), store: store)
        view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.session = session; session.textView = view
        view.loadDocument(session.note)
        view.publish = { [weak view, weak session] in
            guard let view, let session,
                  let blocks = try? NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale, trailingAttributes: view.trailingAttributes) else { return }
            session.updateBlocks(blocks)
        }
        view.linkPastes.loadTitle = loader.load
    }
    func paste(_ text: String) -> Bool {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString(text, forType: .string)
        return view.readSelection(from: board)
    }
    func target(at index: Int) -> String? {
        guard index < view.attributedString().length else { return nil }
        return NotesWebLink.destination(from: view.attributedString().attribute(.link, at: index, effectiveRange: nil))?.absoluteString
    }
    func waitForText(_ expected: String) async {
        for _ in 0..<100 {
            if view.string == expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.string, expected)
    }
    func clean() {
        view.linkPastes.cancelAll()
        try? FileManager.default.removeItem(at: root)
    }
}
