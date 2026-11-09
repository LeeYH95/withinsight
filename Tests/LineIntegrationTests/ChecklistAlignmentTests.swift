import AppKit
import SwiftUI
import XCTest
import NotesCore
@testable import Tendedero

/// Compare actual checkbox pixels with the first text line, rather than just
/// comparing view frames: SF Symbols, CJK fallback and attachments have different ink bounds.
final class ChecklistAlignmentTests: XCTestCase {
    @MainActor private func block(_ text: String, size: CGFloat, checked: Bool) throws -> NoteBlock {
        let rich = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        return NoteBlock(kind: .checklist, text: text,
                         richText: try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                         isChecked: checked)
    }
    private func inkBounds(_ bitmap: NSBitmapImageRep, in area: NSRect, points: NSSize, checkbox: Bool) throws -> NSRect {
        let sx = CGFloat(bitmap.pixelsWide) / points.width, sy = CGFloat(bitmap.pixelsHigh) / points.height
        var bounds = NSRect.null
        for y in max(0, Int(area.minY * sy))..<min(bitmap.pixelsHigh, Int(area.maxY * sy)) {
            for x in max(0, Int(area.minX * sx))..<min(bitmap.pixelsWide, Int(area.maxX * sx)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let matches = checkbox ? (r > 0.28 && r < 0.7 && g < 0.72 && b < 0.88 && b - r > 0.025) : max(r, g, b) < 0.62
                if matches { bounds = bounds.union(NSRect(x: CGFloat(x) / sx, y: CGFloat(y) / sy, width: 1 / sx, height: 1 / sy)) }
            }
        }
        XCTAssertFalse(bounds.isNull, "Missing \(checkbox ? "checkbox" : "text") pixels in \(area)")
        return bounds
    }
    private func evidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SHIPIAN_QA_EVIDENCE"] else { return }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
    }
    @MainActor func testEditorCheckboxInkCentersOnFirstTextLineAcrossFontsAndZoom() throws {
        _ = NSApplication.shared
        let old = NSApp.appearance; NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = old }
        for size: CGFloat in [12, 14, 15, 16, 18, 24] {
            for scale: CGFloat in [0.75, 1, 1.25, 1.5] {
                for checked in [false, true] {
                    let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 130), textContainer: nil)
                    view.appearance = NSAppearance(named: .aqua); view.drawsBackground = true; view.backgroundColor = .white
                    view.readingScale = scale
                    view.loadDocument(NoteDocument(blocks: [try block("留下这张参考图", size: size, checked: checked)]))
                    let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
                    manager.ensureLayout(for: container)
                    let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
                    let bodyGlyph = manager.glyphIndexForCharacter(at: 2)
                    let textX = manager.boundingRect(forGlyphRange: NSRange(location: bodyGlyph, length: 1), in: container).minX + view.textContainerOrigin.x
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 260, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    bitmap.size = view.bounds.size
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let box = try inkBounds(bitmap, in: NSRect(x: 0, y: line.minY, width: textX - 2, height: line.height), points: view.bounds.size, checkbox: true)
                    let text = try inkBounds(bitmap, in: NSRect(x: textX, y: line.minY, width: 480 - textX, height: line.height), points: view.bounds.size, checkbox: false)
                    print("CHECKLIST_EDITOR size=\(size) scale=\(scale) checked=\(checked) box=\(box) text=\(text) delta=\(box.midY - text.midY)")
                    let tolerance: CGFloat = size == 15 && scale == 1 ? 0.5 : max(1, size * scale * 0.06)
                    XCTAssertEqual(box.midY, text.midY, accuracy: tolerance, "size=\(size), zoom=\(scale), checked=\(checked)")
                    if size == 15 && scale == 1 && checked { try evidence(bitmap, name: "editor-checklist") }
                }
            }
        }
    }
    @MainActor func testContinuingNestedChecklistKeepsBlankAndTypedRowAligned() throws {
        _ = NSApplication.shared
        for (size, scale, reselect): (CGFloat, CGFloat, Bool) in [(15, 1.33, false), (19, 1, true)] {
            var previous = try block("确认价格", size: size, checked: true)
            previous.markdown = "  - [x] 确认价格"
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: nil)
            view.readingScale = scale
            view.loadDocument(NoteDocument(blocks: [NoteBlock(kind: .checklist, text: "品牌墙"), previous, NoteBlock(kind: .checklist, text: "VI手册")]))
            let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
            let storage = try XCTUnwrap(view.textStorage)
            func geometry(at character: Int) -> (x: CGFloat, line: NSRect) {
                manager.ensureLayout(for: container)
                let glyph = manager.glyphIndexForCharacter(at: character)
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return (line.minX + manager.location(forGlyphAt: glyph).x, line)
            }
            let body = (view.string as NSString).range(of: previous.text)
            let earlier = geometry(at: body.location - 2)
            view.setSelectedRange(NSRange(location: NSMaxRange(body), length: 0))
            view.insertNewline(nil)
            let caret = view.selectedRange().location
            let blank = geometry(at: caret - 2)
            let nextBeforeTyping = geometry(at: caret + 1).line.minY
            XCTAssertEqual(blank.x, earlier.x, accuracy: 0.5, "The empty checkbox should align with the preceding checkbox")
            if reselect {
                view.setSelectedRange(NSRange(location: caret + 3, length: 0))
                view.setSelectedRange(NSRange(location: caret, length: 0))
            }
            XCTAssertEqual((view.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, size * scale, accuracy: 0.05)
            view.insertText("新", replacementRange: view.selectedRange())
            let typed = geometry(at: caret - 2)
            XCTAssertEqual(typed.x, blank.x, accuracy: 0.5, "Typing the first character must not move the checkbox")
            XCTAssertEqual(typed.line.minY, blank.line.minY, accuracy: 0.5)
            // TextKit may round the CJK line metrics differently from the empty row.
            XCTAssertEqual(geometry(at: caret + 2).line.minY, nextBeforeTyping, accuracy: 1, "Typing one character must not reflow the following row")
            XCTAssertEqual(view.selectedRange(), NSRange(location: caret + 1, length: 0))
            XCTAssertEqual((storage.attribute(.font, at: caret, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, size * scale, accuracy: 0.05)
            let blocks = try NotesContinuousDocument.blocks(from: storage, scale: scale, trailingAttributes: view.trailingAttributes)
            XCTAssertEqual(blocks.map(\.markdown), ["品牌墙", "  - [x] 确认价格", "  - [ ] 新", "VI手册"])
        }
    }
    @MainActor func testNestedChecklistKeyboardAndCompositionInEditorWindow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NotesStore(directory: directory)
        var note = try store.create()
        var child = try block("确认价格", size: 19, checked: true)
        child.markdown = "  - [x] 确认价格"
        note.blocks = [NoteBlock(kind: .checklist, text: "品牌墙"), child, NoteBlock(kind: .checklist, text: "整理交付清单")]
            + (1...16).map { NoteBlock(text: "后续记录 \($0)") }
        try store.update(note)
        let session = NotesEditorSession(note: note, store: store)
        let host = NSHostingView(rootView: NoteEditorView(session: session, workspace: NotesWorkspace(store: store), expand: {}))
        let window = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let view = try XCTUnwrap(session.textView as? NotesContinuousTextView)
        let storage = try XCTUnwrap(view.textStorage)
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        XCTAssertTrue(window.makeFirstResponder(view))
        let original = (view.string as NSString).range(of: child.text)
        let expectedSize = try XCTUnwrap(storage.attribute(.font, at: original.location, effectiveRange: nil) as? NSFont).pointSize
        view.setSelectedRange(NSRange(location: NSMaxRange(original), length: 0))

        func key(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     characters: character, charactersIgnoringModifiers: character,
                                                     isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        func level(at caret: Int) -> Int? {
            storage.attribute(.notesListLevel, at: caret - 2, effectiveRange: nil) as? Int
        }

        try key("\r", code: 36)
        let caret = view.selectedRange().location
        XCTAssertGreaterThan(caret, NSMaxRange(original), "Return should create a new item and move the caret into it")
        XCTAssertEqual(level(at: caret), 1)
        try key("\u{19}", code: 48, modifiers: .shift)
        XCTAssertEqual(level(at: view.selectedRange().location), 0)
        try key("\t", code: 48)
        XCTAssertEqual(level(at: view.selectedRange().location), 1)
        XCTAssertEqual(view.selectedRange(), NSRange(location: caret, length: 0))
        try await Task.sleep(for: .milliseconds(120))
        let scrollBefore = scroll.contentView.bounds.origin

        view.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: view.selectedRange())
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(session.note.blocks[2].text, "")
        view.insertText("拼音", replacementRange: view.markedRange())
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), NSRange(location: caret + 2, length: 0))
        XCTAssertEqual((storage.attribute(.font, at: caret, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, expectedSize, accuracy: 0.05)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrollBefore.y, accuracy: 1)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(session.note.blocks[2].markdown, "  - [ ] 拼音")

        try key("\r", code: 36)
        let continued = view.selectedRange().location
        XCTAssertEqual(level(at: continued), 1)
        try key("\r", code: 36)
        XCTAssertEqual(level(at: view.selectedRange().location), 0)
        try key("\r", code: 36)
        try session.commit()
        let reopened = try XCTUnwrap(NotesStore(directory: directory).document(id: note.id))
        XCTAssertEqual(reopened.blocks.prefix(5).map(\.text), ["品牌墙", "确认价格", "拼音", "", "整理交付清单"])
        XCTAssertEqual(reopened.blocks[3].kind, .paragraph)
    }
    @MainActor func testCheckedTextDrawsARealStrikeWithoutPersistingFormatting() throws {
        _ = NSApplication.shared
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 100), textContainer: nil)
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = true
        view.backgroundColor = .white
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        var task = try block("OOOOOOOO", size: 24, checked: false)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        let windowBitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 840, pixelsHigh: 200, bitsPerSample: 8,
                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0))
        windowBitmap.size = view.bounds.size
        func strikeCoverage() throws -> Double {
            manager.ensureLayout(for: container)
            let body = (view.string as NSString).range(of: task.text)
            let glyphs = manager.glyphRange(forCharacterRange: body, actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            view.cacheDisplay(in: view.bounds, to: windowBitmap)
            let columns = Int(frame.minX * 2 + 4)..<Int(frame.maxX * 2 - 4)
            let rows = Int(frame.minY * 2)..<Int(frame.maxY * 2)
            return try XCTUnwrap(rows.map { y in
                Double(columns.filter { x in
                    guard let pixel = windowBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.72
                }.count) / Double(columns.count)
            }.max())
        }
        view.loadDocument(NoteDocument(blocks: [task]))
        let unchecked = try strikeCoverage()
        let selection = NSRange(location: 5, length: 2)
        view.setSelectedRange(selection)
        let glyph = manager.glyphIndexForCharacter(at: 0)
        let checkbox = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let point = view.convert(NSPoint(x: checkbox.midX, y: checkbox.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertGreaterThan(try strikeCoverage(), max(unchecked + 0.15, 0.8))
        let saved = try XCTUnwrap(NotesContinuousDocument.blocks(from: view.attributedString()).first)
        XCTAssertTrue(saved.isChecked)
        let rich = try XCTUnwrap(NSAttributedString(rtf: XCTUnwrap(saved.richText), documentAttributes: nil))
        XCTAssertEqual(rich.string, task.text)
        XCTAssertEqual(rich.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int ?? 0, 0)

        view.mouseDown(with: click)
        XCTAssertEqual(try strikeCoverage(), unchecked, accuracy: 0.05)
        task.isChecked = true
        let preview = NoteThumbnailText.content(for: NoteDocument(blocks: [task]))
        let previewBody = (preview.string as NSString).range(of: task.text)
        XCTAssertEqual(preview.attribute(.strikethroughStyle, at: previewBody.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(preview.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))

        let link = URL(string: "https://example.com")!
        let manual = NSAttributedString(string: task.text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 24), .strikethroughStyle: NSUnderlineStyle.single.rawValue, .link: link
        ])
        task.richText = try manual.data(from: NSRange(location: 0, length: manual.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        view.loadDocument(NoteDocument(blocks: [task]))
        view.mouseDown(with: click)
        let reopened = try XCTUnwrap(NotesContinuousDocument.blocks(from: view.attributedString()).first)
        XCTAssertFalse(reopened.isChecked)
        let restored = try XCTUnwrap(NSAttributedString(rtf: XCTUnwrap(reopened.richText), documentAttributes: nil))
        XCTAssertEqual(restored.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(NotesWebLink.destination(from: restored.attribute(.link, at: 0, effectiveRange: nil)), link)
        let font = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }
    @MainActor func testCrossRowSelectionKeepsSameHighlightThicknessThroughCheckbox() async throws {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        for scale: CGFloat in [1, 1.33] {
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 150), textContainer: nil)
            view.readingScale = scale
            view.appearance = NSAppearance(named: .aqua)
            view.drawsBackground = true
            view.backgroundColor = .white
            let window = NotesWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            let blocks = [
                NoteBlock(kind: .checklist, text: "品牌墙"),
                NoteBlock(kind: .checklist, text: "替换案例图与标识", markdown: "  - [ ] 替换案例图与标识"),
                NoteBlock(kind: .checklist, text: "确认新版报价", isChecked: true)
            ]
            view.loadDocument(NoteDocument(blocks: blocks))
            XCTAssertTrue(window.makeFirstResponder(view))
            let text = view.string as NSString
            let start = text.range(of: "墙").location
            let end = text.range(of: "确认").location + 2
            view.setSelectedRange(NSRange(location: start, length: end - start))
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 840, pixelsHigh: 300,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var bands: [Int] = []
            var height = 0
            for y in 0..<bitmap.pixelsHigh {
                let pixel = bitmap.colorAt(x: 600, y: y)?.usingColorSpace(.deviceRGB)
                if let pixel, pixel.redComponent > 0.58, pixel.redComponent < 0.96 {
                    height += 1
                } else if height > 0 {
                    bands.append(height)
                    height = 0
                }
            }
            print("CHECKLIST_HIGHLIGHT scale=\(scale) key=\(window.isKeyWindow) bands_px=\(bands)")
            XCTAssertEqual(bands.count, 2, "The selection must span both lines with room between the highlights")
            if bands.count == 2 {
                XCTAssertEqual(Double(bands[0]), Double(bands[1]), accuracy: 2, "Scale \(scale): highlight thickness in Retina pixels")
            }
            try evidence(bitmap, name: "checklist-selection-\(scale)")
        }
    }
    @MainActor func testFirstEditKeepsOriginalFormattingOnlyForUnchangedBlocks() throws {
        _ = NSApplication.shared
        func richBlock(_ text: String, destination: URL) throws -> NoteBlock {
            let rich = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 19), .link: destination])
            let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return NoteBlock(text: text, richText: rtf)
        }
        let unchanged = try richBlock("原有格式与链接", destination: URL(string: "https://example.com")!)
        let legacy = try richBlock("旧版文件链接", destination: URL(fileURLWithPath: "/tmp/private.txt"))
        let first = NoteBlock(text: "第一项", markdown: "1. 第一项")
        let second = NoteBlock(text: "第二项", markdown: "1. 第二项")
        let task = NoteBlock(kind: .checklist, text: "当前待办")
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: nil)
        view.loadDocument(NoteDocument(blocks: [unchanged, legacy, first, second, task]))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("字", replacementRange: view.selectedRange())
        let saved = try NotesContinuousDocument.blocks(from: view.attributedString(), trailingAttributes: view.trailingAttributes,
                                                       cache: view.bodyEncodingCache)
        XCTAssertEqual(saved[0], unchanged)
        let sanitized = try XCTUnwrap(NSAttributedString(rtf: XCTUnwrap(saved[1].richText), documentAttributes: nil))
        XCTAssertNil(sanitized.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(saved[3].markdown, "2. 第二项")
        XCTAssertEqual(saved[4].text, "当前待办字")
        XCTAssertNotNil(saved[4].richText)
    }
    @MainActor func testAdversarialChecklistTypingAndQuit() throws {
        guard ProcessInfo.processInfo.environment["SHIPIAN_INTERACTION_QA"] == "1" else {
            throw XCTSkip("Opt-in timings for a large editable note")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checklist-perf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        var note = try store.create()
        note.blocks = (0..<240).map { i in
            let text = "第\(i)项 · 核对这个待办在长文里的换行、选区和输入。"
            return NoteBlock(kind: .checklist, text: text, markdown: i % 3 == 0 ? text : "  - [ ] " + text, isChecked: i % 2 == 0)
        }
        try store.update(note)
        let workspace = NotesWorkspace(store: store)
        let opening = ProcessInfo.processInfo.systemUptime
        workspace.open(note.id)
        let controller = try XCTUnwrap(NSApp.windows.compactMap { $0.windowController as? NotesEditorController }
            .first { $0.session.note.id == note.id })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let session = controller.session
        defer { session.window?.orderOut(nil) }
        let view = try XCTUnwrap(session.textView as? NotesContinuousTextView)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let openMS = (ProcessInfo.processInfo.systemUptime - opening) * 1000
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        var durations: [Double] = []
        for _ in 0..<15 {
            let start = ProcessInfo.processInfo.systemUptime
            view.insertText("字", replacementRange: view.selectedRange())
            manager.ensureLayout(for: container)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let quitting = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(workspace.prepareToQuit())
        let quitMS = (ProcessInfo.processInfo.systemUptime - quitting) * 1000
        let reopened = try XCTUnwrap(NotesStore(directory: root).document(id: note.id))
        XCTAssertEqual(reopened.blocks.count, 240)
        XCTAssertEqual(Array(reopened.blocks.dropLast()), Array(note.blocks.dropLast()))
        XCTAssertTrue(reopened.blocks.last?.text.hasSuffix(String(repeating: "字", count: 15)) == true)
        let sorted = durations.sorted()
        let warm = durations.dropFirst().sorted()
        print("SHIPIAN_INTERACTION_QA rows=240 keystrokes=15 open_ms=\(openMS) first_ms=\(durations[0]) median_ms=\(sorted[7]) warm_max_ms=\(warm.last ?? 0) quit_save_ms=\(quitMS)")
    }
    @MainActor func testHangingThumbnailCheckboxInkCentersOnFirstTextLine() throws {
        _ = NSApplication.shared
        let old = NSApp.appearance; NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = old }
        for checked in [false, true] {
            let image = NoteThumbnail.image(for: NoteDocument(title: "对齐验收", blocks: [NoteBlock(kind: .checklist, text: "留下这张参考图", isChecked: checked)]))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let box = try inkBounds(bitmap, in: NSRect(x: 20, y: 60, width: 38, height: 85), points: image.size, checkbox: true)
            let text = try inkBounds(bitmap, in: NSRect(x: 62, y: 60, width: 320, height: 85), points: image.size, checkbox: false)
            print("CHECKLIST_THUMBNAIL checked=\(checked) box=\(box) text=\(text) delta=\(box.midY - text.midY)")
            XCTAssertEqual(box.midY, text.midY, accuracy: 1)
            if checked { try evidence(bitmap, name: "hanging-checklist") }
        }
    }
}
