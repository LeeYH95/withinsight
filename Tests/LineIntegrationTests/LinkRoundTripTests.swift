import AppKit
import Combine
import NotesCore
import XCTest
@testable import Tendedero

final class LinkRoundTripTests: XCTestCase {
    @MainActor func testOwnedCopyPreservesStyledLinkRunsAcrossNotesAndReopen() throws {
        let f = try RoundTripFixture(); defer { f.clean() }
        let value = NSMutableAttributedString(string: "前 第一标题 中 Second title 后", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let first = (value.string as NSString).range(of: "第一标题")
        let second = (value.string as NSString).range(of: "Second title")
        value.addAttributes([.link: URL(string: "https://example.com/one")!, .font: NSFont.boldSystemFont(ofSize: 24), .underlineStyle: 1], range: first)
        value.addAttributes([.link: "https://example.org/two", .font: try XCTUnwrap(NSFont(name: "Helvetica-Oblique", size: 18))], range: second)
        let (source, sourceSession) = try f.editor(value)
        source.textStorage?.addAttribute(.notesPendingLink, value: UUID().uuidString, range: first)
        source.selectAll(nil)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(source.writeSelection(to: board, types: source.writablePasteboardTypes))
        let external = try XCTUnwrap(board.data(forType: .rtfd).flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) })
        XCTAssertEqual(target(in: external, at: first.location), "https://example.com/one")
        XCTAssertNil(external.attribute(.notesPendingLink, at: first.location, effectiveRange: nil))

        let (targetView, targetSession) = try f.editor()
        targetView.preservePastedFormatting = true
        XCTAssertTrue(targetView.readSelection(from: board))
        try targetSession.commit()
        let reopened = try NotesStore(directory: f.store.directory)
        let note = try XCTUnwrap(reopened.document(id: targetSession.note.id))
        let rendered = NotesContinuousDocument.render(note)
        XCTAssertEqual(rendered.string, value.string)
        XCTAssertEqual(target(in: rendered, at: first.location), "https://example.com/one")
        XCTAssertEqual(target(in: rendered, at: second.location), "https://example.org/two")
        XCTAssertNil(target(in: rendered, at: 0))
        let font = try XCTUnwrap(rendered.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 24, accuracy: 0.02)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(rendered.attribute(.underlineStyle, at: first.location, effectiveRange: nil) as? Int, 1)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(rendered.attribute(.font, at: second.location, effectiveRange: nil) as? NSFont)).contains(.italicFontMask))
        withExtendedLifetime(sourceSession) {}
    }

    @MainActor func testOwnedVersionOneAcceptsLegacyStylesAndDropsUnsafeLinkTargets() throws {
        let f = try RoundTripFixture(); defer { f.clean() }
        let payload: [String: Any] = ["version": 1, "assets": [], "blocks": [[
            "kind": "paragraph", "text": "旧格式 安全 危险", "heading": 0, "bullet": false, "checked": false,
            "styles": [
                style(location: 0, length: 4),
                style(location: 4, length: 2, link: "https://example.com"),
                style(location: 7, length: 2, link: "javascript:alert(1)")
            ]
        ]]]
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([NotesContinuousTextView.ownedSelectionType], owner: nil)
        board.setData(try JSONSerialization.data(withJSONObject: payload), forType: NotesContinuousTextView.ownedSelectionType)
        let (view, session) = try f.editor()
        XCTAssertTrue(view.readSelection(from: board))
        XCTAssertEqual(view.string, "旧格式 安全 危险")
        XCTAssertNil(target(in: view.attributedString(), at: 0))
        XCTAssertEqual(target(in: view.attributedString(), at: 4), "https://example.com")
        XCTAssertNil(view.attributedString().attribute(.link, at: 7, effectiveRange: nil))
        XCTAssertNil(session.attachmentFailure)
    }

    @MainActor func testExternalRichAndHTMLPasteKeepTitlesWithoutFetchingAndStripUnsafeLinks() throws {
        let f = try RoundTripFixture(); defer { f.clean() }
        let rich = NSMutableAttributedString(string: "网页标题 危险文字", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        rich.addAttribute(.link, value: URL(string: "https://example.com/original")!, range: NSRange(location: 0, length: 4))
        rich.addAttribute(.link, value: "javascript:alert(1)", range: NSRange(location: 5, length: 4))
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let html = Data("<html><head><meta charset='utf-8'></head><body><a href='https://example.com/original'>网页标题</a> <a href='javascript:alert(1)'>危险文字</a></body></html>".utf8)
        for (type, data) in [(NSPasteboard.PasteboardType.rtf, rtf), (.html, html)] {
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.declareTypes([type, .string], owner: nil)
            board.setData(data, forType: type); board.setString("网页标题 危险文字", forType: .string)
            let (view, session) = try f.editor()
            var requests: [URL] = []
            view.linkPastes.loadTitle = { url, _ in requests.append(url); return AnyCancellable {} }
            XCTAssertTrue(view.readSelection(from: board))
            XCTAssertTrue(view.string.contains("网页标题 危险文字"))
            XCTAssertEqual(target(in: view.attributedString(), at: 0), "https://example.com/original")
            let unsafe = (view.string as NSString).range(of: "危险文字")
            XCTAssertNotEqual(unsafe.location, NSNotFound)
            if unsafe.location != NSNotFound { XCTAssertNil(view.attributedString().attribute(.link, at: unsafe.location, effectiveRange: nil)) }
            XCTAssertTrue(requests.isEmpty, "A titled rich link must not trigger a metadata request")
            withExtendedLifetime(session) {}
        }
    }

    @MainActor func testRenderingExistingRTFLeavesUnsafeLinksAsReadableText() throws {
        _ = NSApplication.shared
        let value = NSMutableAttributedString(string: "安全危险", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        value.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 2))
        value.addAttribute(.link, value: "file:///private/data", range: NSRange(location: 2, length: 2))
        let rtf = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rendered = NotesContinuousDocument.render(NoteDocument(blocks: [NoteBlock(text: value.string, richText: rtf)]))
        XCTAssertEqual(rendered.string, value.string)
        XCTAssertEqual(target(in: rendered, at: 0), "https://example.com")
        XCTAssertNil(rendered.attribute(.link, at: 2, effectiveRange: nil))
    }

    @MainActor func testMarkdownExportEscapesLinkLabelAndDestinationWhilePreservingEmphasis() throws {
        _ = NSApplication.shared
        let label = "[标题]*_`<>\\"
        let value = NSMutableAttributedString(string: "前 " + label + " 后 危险", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let linkRange = (value.string as NSString).range(of: label)
        let font = NSFontManager.shared.convert(NSFont.boldSystemFont(ofSize: 15), toHaveTrait: .italicFontMask)
        value.addAttributes([.link: URL(string: "https://example.com/a(b)?q=a b")!, .font: font, .underlineStyle: 1], range: linkRange)
        value.addAttribute(.link, value: "javascript:alert(1)", range: (value.string as NSString).range(of: "危险"))
        let expected = "前 [***<u>\\[标题\\]\\*\\_\\`\\<\\>\\\\</u>***](https://example.com/a%28b%29?q=a%20b) 后 危险"
        XCTAssertEqual(RichNoteTextView.Coordinator.markdown(value), expected)
        let block = try XCTUnwrap(NotesContinuousDocument.blocks(from: value).first)
        XCTAssertEqual(block.markdown, expected, "Saved blocks feed the Markdown exporter")
    }

    private func style(location: Int, length: Int, link: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["location": location, "length": length, "size": 15, "fontName": ".AppleSystemUIFont", "bold": false, "italic": false, "underline": 0, "strike": 0]
        if let link { result["link"] = link }
        return result
    }

    private func target(in value: NSAttributedString, at index: Int) -> String? {
        NotesWebLink.destination(from: value.attribute(.link, at: index, effectiveRange: nil))?.absoluteString
    }
}

@MainActor private final class RoundTripFixture {
    let root: URL
    let store: NotesStore
    init() throws {
        _ = NSApplication.shared
        let base = ProcessInfo.processInfo.environment["LINENOTES_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("link-round-trip-" + UUID().uuidString)
        store = try NotesStore(directory: root)
    }
    func editor(_ value: NSAttributedString? = nil) throws -> (NotesContinuousTextView, NotesEditorSession) {
        var note = try store.create()
        if let value {
            let rtf = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            note.blocks = [NoteBlock(text: value.string, richText: rtf)]
            try store.update(note)
        }
        let session = NotesEditorSession(note: note, store: store)
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), textContainer: nil)
        view.session = session; session.textView = view
        view.loadDocument(note)
        view.publish = { [weak view, weak session] in
            guard let view, let session, let blocks = try? NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale, trailingAttributes: view.trailingAttributes) else { return }
            session.updateBlocks(blocks)
        }
        return (view, session)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
