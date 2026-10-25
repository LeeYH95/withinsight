import AppKit
import XCTest
import NotesCore
@testable import Tendedero

final class ContinuousCaretVisibilityTests: XCTestCase {
    @MainActor private final class PaperDocument: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor func testScrollingToDocumentEndKeepsTheLastLineInsideTheWritingViewport() throws {
        _ = NSApplication.shared
        for scale: CGFloat in [1, 1.33] {
            for trailingEmptyParagraph in [false, true] {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
                scroll.borderType = .noBorder
                scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
                let paper = PaperDocument(frame: .zero)
                let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 72, width: 480, height: 100), textContainer: nil)
                view.readingScale = scale
                var blocks = (1...80).map { NoteBlock(text: "第\($0)段：长文末尾的光标和文字必须保持可见。") }
                if trailingEmptyParagraph { blocks.append(NoteBlock()) }
                view.loadDocument(NoteDocument(blocks: blocks))
                let container = try XCTUnwrap(view.textContainer)
                let layout = try XCTUnwrap(view.layoutManager)
                layout.ensureLayout(for: container)
                let bodyHeight = layout.usedRect(for: container).height + 16
                view.setFrameSize(NSSize(width: 480, height: bodyHeight))
                // The 64pt toolbar is outside this writing viewport; normal end padding is 24pt.
                paper.setFrameSize(NSSize(width: 480, height: 72 + bodyHeight + 24))
                paper.addSubview(view); scroll.documentView = paper
                scroll.contentView.scroll(to: .zero)
                let end = NSRange(location: view.string.utf16.count, length: 0)
                view.setSelectedRange(end)
                view.scrollRangeToVisible(end)
                layout.ensureLayout(for: container)
                let lastLine: NSRect
                if trailingEmptyParagraph { lastLine = layout.extraLineFragmentRect }
                else { lastLine = layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil) }
                XCTAssertGreaterThan(lastLine.height, 0)
                let inPaper = view.convert(lastLine.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), to: paper)
                let visible = scroll.contentView.bounds
                XCTAssertGreaterThan(visible.minY, 0, "The test must actually scroll the long document")
                XCTAssertGreaterThanOrEqual(inPaper.minY, visible.minY - 0.5)
                XCTAssertLessThanOrEqual(inPaper.maxY, visible.maxY - 12 + 0.5, "Scale \(scale), trailing empty \(trailingEmptyParagraph): the last caret must have normal end padding")
            }
        }
    }
}
