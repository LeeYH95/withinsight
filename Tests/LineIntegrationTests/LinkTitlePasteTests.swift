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

    @MainActor func testNativeHoverShowsHandAndReturnsToEditingCursor() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "链接悬停测试")
        f.view.insertText(" 普通正文", replacementRange: NSRange(location: f.view.string.utf16.count, length: 0))
        let probe = try NativeLinkClick(view: f.view); defer { probe.close() }
        for type: NSEvent.EventType in [.mouseMoved, .cursorUpdate] {
            for (index, modifier, expected): (Int, NSEvent.ModifierFlags, NSCursor) in [
                (1, [], .pointingHand), (1, .option, .iBeam), (1, .shift, .iBeam),
                (1, .control, .iBeam), (1, .command, .pointingHand), (9, [], .iBeam)
            ] {
                let point = try probe.point(at: index)
                let location = f.view.convert(point, to: nil)
                let event = try XCTUnwrap(type == .mouseMoved
                    ? NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: modifier,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: probe.window.windowNumber,
                        context: nil, eventNumber: 2, clickCount: 0, pressure: 0)
                    : NSEvent.enterExitEvent(with: .cursorUpdate, location: location, modifierFlags: modifier,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: probe.window.windowNumber,
                        context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
                NSCursor.arrow.set()
                if type == .mouseMoved { f.view.mouseMoved(with: event) } else { f.view.cursorUpdate(with: event) }
                XCTAssertEqual(NSCursor.current, expected, "Native \(type) at \(index), modifiers \(modifier)")
            }
        }
    }

    @MainActor func testLinkContextActionsUseClickedTargetWithoutLosingSelectionAndAreUndoable() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original?q=1")); f.loader.complete(0, "上下文菜单")
        let probe = try NativeLinkClick(view: f.view); defer { probe.close() }
        let selection = NSRange(location: 1, length: 2); f.view.setSelectedRange(selection)
        let menu = NotesTextMenu.make(for: f.view, session: f.session, at: try probe.point(at: 2))
        XCTAssertEqual(f.view.selectedRange(), selection)
        var opened: [URL] = []; f.view.openLink = { opened.append($0) }
        NotesMenuPresenter.dispatch(try XCTUnwrap(menu.items.first { $0.title == "打开链接" }))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/original?q=1"])
        NotesMenuPresenter.dispatch(try XCTUnwrap(menu.items.first { $0.title == "编辑链接文字" }))
        XCTAssertEqual(f.view.selectedRange(), NSRange(location: 0, length: 5))
        NotesMenuPresenter.dispatch(try XCTUnwrap(menu.items.first { $0.title == "移除链接，保留文字" }))
        XCTAssertEqual(f.view.string, "上下文菜单"); XCTAssertNil(f.target(at: 0))
        f.session.undo(); f.view.loadDocument(f.session.note)
        XCTAssertEqual(f.target(at: 0), "https://example.com/original?q=1")
        try f.session.commit()
        let reopened = try NotesStore(directory: f.store.directory)
        XCTAssertEqual(NotesContinuousDocument.render(try XCTUnwrap(reopened.document(id: f.session.note.id))).string, "上下文菜单")
    }

    @MainActor func testLinkMenuTracksAnAsyncTitleReplacementAndRemovalClearsItsTooltip() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/long-original-address"))
        let probe = try NativeLinkClick(view: f.view); defer { probe.close() }
        let menu = NotesTextMenu.make(for: f.view, session: f.session, at: try probe.point(at: 2))
        f.loader.complete(0, "短标题")
        NotesMenuPresenter.dispatch(try XCTUnwrap(menu.items.first { $0.title == "编辑链接文字" }))
        XCTAssertEqual(f.view.selectedRange(), NSRange(location: 0, length: 3))
        NotesMenuPresenter.dispatch(try XCTUnwrap(menu.items.first { $0.title == "移除链接，保留文字" }))
        XCTAssertEqual(f.view.string, "短标题"); XCTAssertNil(f.target(at: 0))
        XCTAssertNil(f.view.attributedString().attribute(.toolTip, at: 0, effectiveRange: nil))
    }
    @MainActor func testRemovingPendingLinkCannotBeReactivatedByItsLateTitle() throws {
        let f = try LinkFixture(); defer { f.clean() }
        let address = "https://example.com/pending"; XCTAssertTrue(f.paste(address))
        f.view.removeLink(in: NSRange(location: 0, length: f.view.string.utf16.count))
        XCTAssertNil(f.view.attributedString().attribute(.notesPendingLink, at: 0, effectiveRange: nil))
        XCTAssertNil(f.view.attributedString().attribute(.toolTip, at: 0, effectiveRange: nil))
        f.loader.complete(0, "迟到标题")
        XCTAssertEqual(f.view.string, address); XCTAssertNil(f.target(at: 0))
    }

    @MainActor func testNormalAndCommandClickBothOpenOriginalURL() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "原始目标")
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        XCTAssertTrue(f.view.activateLink(at: 0, modifiers: []))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/original"])
        XCTAssertTrue(f.view.activateLink(at: 0, modifiers: .command))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/original", "https://example.com/original"])
        for modifier: NSEvent.ModifierFlags in [.option, .shift, .control] {
            XCTAssertFalse(f.view.activateLink(at: 0, modifiers: modifier))
        }
        XCTAssertEqual(opened.count, 2, "Editing and range-selection modifiers must not navigate")
    }

    @MainActor func testUnmodifiedMouseClickOnResolvedTitleOpensTheStoredURL() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "单击直接打开的标题")
        let probe = try NativeLinkClick(view: f.view)
        defer { probe.close() }
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        let point = try probe.point(at: 2)
        XCTAssertNotNil(f.view.linkContext(at: point), "The native fixture must hit a link before dispatch")
        try probe.click(from: point)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/original"], probe.lastTrace)
        XCTAssertEqual(f.view.string, "单击直接打开的标题")
    }

    @MainActor func testClickBesideOrBelowALinkDoesNotOpenTheNearestCharacter() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "短链接")
        let probe = try NativeLinkClick(view: f.view)
        defer { probe.close() }
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        try probe.click(from: NSPoint(x: 430, y: 12))
        try probe.click(from: NSPoint(x: 8, y: 160))
        XCTAssertTrue(opened.isEmpty, "Nearest-character hit testing must not make empty paper clickable")
    }

    @MainActor func testDraggingAcrossALinkSelectsTextWithoutOpeningIt() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "拖动链接仍然可以选择文字")
        let probe = try NativeLinkClick(view: f.view)
        defer { probe.close() }
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        try probe.click(from: probe.point(at: 0), draggingTo: probe.point(at: 8))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertGreaterThan(f.view.selectedRange().length, 0)
        XCTAssertEqual(f.view.string, "拖动链接仍然可以选择文字")
    }

    @MainActor func testOptionClickEditsATitleWithoutOpeningTheURL() throws {
        let f = try LinkFixture(); defer { f.clean() }
        XCTAssertTrue(f.paste("https://example.com/original"))
        f.loader.complete(0, "按住选项键编辑标题")
        let probe = try NativeLinkClick(view: f.view)
        defer { probe.close() }
        var opened: [URL] = []
        f.view.openLink = { opened.append($0) }
        try probe.click(from: probe.point(at: 3), modifiers: .option)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(f.view.selectedRange().length, 0)
        XCTAssertGreaterThan(f.view.selectedRange().location, 0)
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

    @MainActor func testRawURLInRichClipboardAlsoResolvesItsTitle() throws {
        let address = "https://mp.weixin.qq.com/s/QVu2luIrRTtNvsH-U65A8g"
        for flavor in [NSPasteboard.PasteboardType.rtf, .html] {
            let f = try LinkFixture(); defer { f.clean() }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.declareTypes([.string, flavor], owner: nil)
            board.setString(address, forType: .string)
            if flavor == .rtf {
                let rich = NSAttributedString(string: address, attributes: [.link: URL(string: address)!])
                board.setData(try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
            } else {
                board.setData(Data("<a href='\(address)'>\(address)</a>".utf8), forType: .html)
            }
            XCTAssertTrue(f.view.readSelection(from: board))
            XCTAssertEqual(f.loader.urls, [URL(string: address)!])
            f.loader.complete(0, "微信公众号文章标题")
            XCTAssertEqual(f.view.string, "微信公众号文章标题")
            XCTAssertEqual(f.target(at: 0), address)
        }
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

@MainActor private final class NativeLinkClick: NSObject, NSTextViewDelegate {
    let view: NotesContinuousTextView
    let window: NSWindow
    private(set) var lastTrace = ""
    init(view: NotesContinuousTextView) throws {
        self.view = view
        window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 480, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.delegate = self
        window.orderFront(nil)
        window.makeFirstResponder(view)
        view.layoutManager?.ensureLayout(for: try XCTUnwrap(view.textContainer))
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        true // Never open an external browser from a regression fixture.
    }
    func point(at character: Int) throws -> NSPoint {
        let layout = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
    }
    func click(from start: NSPoint, draggingTo end: NSPoint? = nil, modifiers: NSEvent.ModifierFlags = []) throws {
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime + time, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func post(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval) throws {
            let location = view.convert(point, to: nil)
            let mask = NSEvent.EventTypeMask(rawValue: 1 << type.rawValue)
            NSApp.postEvent(try event(type, location, time), atStart: true)
            let queued = try XCTUnwrap(NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: false))
            // Some AppKit versions translate synthetic events when queued.
            // Compensate that translation, then verify the real queued point.
            let offset = NSPoint(x: queued.locationInWindow.x - location.x, y: queued.locationInWindow.y - location.y)
            if hypot(offset.x, offset.y) > 0.01 {
                _ = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: true)
                let corrected = NSPoint(x: location.x - offset.x, y: location.y - offset.y)
                NSApp.postEvent(try event(type, corrected, time), atStart: true)
            }
            let actual = try XCTUnwrap(NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: false))
            XCTAssertEqual(actual.windowNumber, window.windowNumber)
            XCTAssertEqual(actual.locationInWindow.x, location.x, accuracy: 0.01)
            XCTAssertEqual(actual.locationInWindow.y, location.y, accuracy: 0.01)
        }
        let down = try event(.leftMouseDown, view.convert(start, to: nil), 0)
        try post(.leftMouseUp, end ?? start, 0.1)
        if let end { try post(.leftMouseDragged, end, 0.05) }
        let queued = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast,
                                     inMode: .eventTracking, dequeue: false)
        lastTrace = "downWindow=\(down.windowNumber) queuedWindow=\(queued?.windowNumber ?? -1) start=\(start) queuedPoint=\(queued.map { view.convert($0.locationInWindow, from: nil) } ?? .zero) bounds=\(view.bounds) hit=\(view.linkContext(at: start)?.url.absoluteString ?? "none")"
        view.mouseDown(with: down)
        lastTrace += " afterBounds=\(view.bounds) afterHit=\(view.linkContext(at: start)?.url.absoluteString ?? "none")"
    }
    func close() { view.delegate = nil; window.orderOut(nil) }
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
