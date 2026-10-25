import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class ApprovedEditorTests: XCTestCase {
    func testBottomAndCornerResizeKeepTopLeftAndRespectMinimum() {
        let start = NSRect(x:100,y:100,width:880,height:650),screen = NSRect(x:0,y:0,width:1440,height:900)
        for axis:NotesResizeAxis in [.vertical,.both] {
            let result = NotesResizeGeometry.frame(start,delta:NSSize(width:-1000,height:1000),axis:axis,minimum:NSSize(width:420,height:360),visible:screen)
            XCTAssertEqual(result.maxY,start.maxY); XCTAssertEqual(result.minX,start.minX)
            XCTAssertEqual(result.height,360)
            XCTAssertEqual(result.width,axis == .vertical ? 880 : 420)
        }
    }
    @MainActor func testCommonSizeMenuDoesNotGrowWithExistingUnusualFont() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let session = NotesEditorSession(note: NoteDocument(blocks: [NoteBlock(text: "字号")]), store: store)
        let body = NotesContinuousTextView(frame: NSRect(x: 0,y: 0,width: 400,height: 200), textContainer: nil)
        body.loadDocument(session.note); session.textView = body
        body.setSelectedRange(NSRange(location: 0,length: body.string.utf16.count)); body.setTextSize(17)
        let menu = try XCTUnwrap(NotesEditorFormatMenu.make(session).items.first { $0.title == "文字字号" }?.submenu)
        XCTAssertEqual(menu.items.map(\.title), ["默认 · 15","12","14","16","18","24"])
        XCTAssertFalse(menu.items.contains { $0.state == .on }, "17pt content remains intact without inventing a menu entry")
    }

    @MainActor func testBlankBodyDefaultIsFifteenPoints() {
        _ = NSApplication.shared
        let body = NotesContinuousTextView(frame: .zero,textContainer: nil)
        XCTAssertEqual((body.defaultAttributes()[.font] as? NSFont)?.pointSize, 15)
    }

    @MainActor func testShrinkingRealEditorPreservesTopAndMiddleReadingPositions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root), workspace = NotesWorkspace(store: store)
        let note = NoteDocument(title: "保留开头",blocks: (1...40).map { NoteBlock(text: "第\($0)段：缩小窗口时，当前阅读的位置保持不变。") })
        let controller = NotesEditorController(note: note,workspace: workspace)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); window.close() }
        XCTAssertEqual(window.minSize,NSSize(width:420,height:360))
        window.setFrame(NSRect(x:100,y:100,width:880,height:650),display:true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        let body = try XCTUnwrap(controller.session.textView)
        let scroll = try XCTUnwrap(body.enclosingScrollView)
        window.makeFirstResponder(body)
        body.setSelectedRange(NSRange(location:body.string.utf16.count,length:0))
        for offset:CGFloat in [0,180] {
            window.setFrame(NSRect(x:100,y:100,width:880,height:650),display:true)
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            scroll.contentView.scroll(to:NSPoint(x:0,y:offset)); scroll.reflectScrolledClipView(scroll.contentView)
            let before = scroll.contentView.bounds.origin.y
            window.setFrame(NSRect(x:100,y:390,width:880,height:360),display:true)
            RunLoop.current.run(until:Date().addingTimeInterval(0.15))
            XCTAssertEqual(scroll.contentView.bounds.origin.y,before,accuracy:1,"Resizing must not follow the old caret")
        }
    }
}
