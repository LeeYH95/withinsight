import AppKit
import XCTest
import NotesCore
@testable import Tendedero

/// Offscreen TextKit acceptance checks. These do not stand in for real-window UI acceptance.
final class ContinuousLayoutAcceptanceTests: XCTestCase {
    private struct LineGeometry {
        let glyphRange: NSRange
        let fragment: NSRect
        let used: NSRect
        let ink: NSRect
    }

    @MainActor private func richBlock(_ text: String, kind: NoteBlock.Kind = .paragraph, size: CGFloat = 32, checked: Bool = false) throws -> NoteBlock {
        let value = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let data = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return NoteBlock(kind: kind, text: text, richText: data, isChecked: checked)
    }

    @MainActor private func editor(_ note: NoteDocument, width: CGFloat = 582, scale: CGFloat = 1.33) -> NotesContinuousTextView {
        _ = NSApplication.shared
        // Formal window minimum is 650 x 390; horizontal body padding is 34 per side.
        let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: width, height: 138), textContainer: nil)
        view.readingScale = scale
        view.loadDocument(note)
        return view
    }

    @MainActor private func geometry(_ view: NotesContinuousTextView) throws -> [LineGeometry] {
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        var lines: [LineGeometry] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, used, _, range, _ in
            lines.append(LineGeometry(glyphRange: range, fragment: rect, used: used, ink: manager.boundingRect(forGlyphRange: range, in: container)))
        }
        return lines
    }

    @MainActor private func assertReadable(_ lines: [LineGeometry], width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(lines.isEmpty, file: file, line: line)
        for (index, item) in lines.enumerated() {
            for rect in [item.fragment, item.used, item.ink] {
                XCTAssertTrue(rect.minX.isFinite && rect.maxX.isFinite && rect.minY.isFinite && rect.maxY.isFinite, "Non-finite line \(index)", file: file, line: line)
            }
            // Half a point permits glyph rounding, but not clipped columns or overflowing text.
            XCTAssertGreaterThanOrEqual(item.ink.minX, -0.5, "Left overflow on line \(index)", file: file, line: line)
            XCTAssertLessThanOrEqual(item.ink.maxX, width + 0.5, "Right overflow on line \(index)", file: file, line: line)
            if index > 0 {
                let previous = lines[index - 1]
                // Compare actual glyph bounds, not paragraph-style values. Empty line boxes are excluded.
                if !previous.ink.isEmpty && !item.ink.isEmpty {
                    XCTAssertLessThanOrEqual(previous.ink.maxY, item.ink.minY + 0.5, "Glyph rows overlap at line \(index)", file: file, line: line)
                }
            }
        }
    }

    @MainActor func testMaximumBodyFontAtMinimumWindowWidthWrapsAllGlyphsWithoutOverlap() throws {
        let paragraph = String(repeating: "大字号中文编辑必须看清每一行，English 123 与 emoji 👨‍👩‍👧‍👦 共存。", count: 20)
        let unbroken = String(repeating: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", count: 10)
        let note = NoteDocument(blocks: [try richBlock(paragraph), try richBlock(unbroken), try richBlock(paragraph)])
        let view = editor(note)
        let lines = try geometry(view)
        XCTAssertGreaterThan(lines.count, 70)
        assertReadable(lines, width: 582)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        XCTAssertGreaterThan(manager.usedRect(for: container).height, view.bounds.height)
        XCTAssertEqual(manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length, view.string.utf16.count)
    }

    @MainActor func testLongLargeChecklistContinuationAlignsWithFirstBodyGlyph() throws {
        let text = String(repeating: "长待办换行仍然需要保持正文齐整，避免文字钻到复选框下方。", count: 18)
        let view = editor(NoteDocument(blocks: [try richBlock(text, kind: .checklist), try richBlock(text, kind: .checklist, checked: true)]))
        let lines = try geometry(view)
        assertReadable(lines, width: 582)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let ns = view.string as NSString
        for location in [0, ns.paragraphRange(for: NSRange(location: 0, length: 0)).length] {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraphGlyphs = manager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            let bodyGlyph = manager.glyphRange(forCharacterRange: NSRange(location: location + 2, length: 1), actualCharacterRange: nil)
            let firstBodyX = manager.boundingRect(forGlyphRange: bodyGlyph, in: container).minX
            let continued = lines.filter { $0.glyphRange.location > paragraphGlyphs.location && $0.glyphRange.location < NSMaxRange(paragraphGlyphs) }
            XCTAssertGreaterThan(continued.count, 10)
            XCTAssertGreaterThan(firstBodyX, 30)
            for item in continued {
                XCTAssertEqual(item.ink.minX, firstBodyX, accuracy: 0.5, "Wrapped task body must align with its first text glyph")
            }
        }
    }

    @MainActor func testRepeatedReadingScaleAndResizeKeepTextAttachmentIdentityAndStoredFontSizes() throws {
        let file = NoteAttachment(name: "验收附件.txt", relativePath: "attachments/layout-fixture.txt", kind: .file, byteCount: 12)
        let image = NoteAttachment(name: "验收图片.png", relativePath: "attachments/layout-fixture.png", kind: .image, byteCount: 24)
        let mixed = NSMutableAttributedString(string: "小字与大字保留各自字号")
        mixed.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: mixed.length))
        mixed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 32), range: NSRange(location: 3, length: 2))
        let data = try mixed.data(from: NSRange(location: 0, length: mixed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let original = [NoteBlock(text: mixed.string, richText: data), NoteBlock(text: "标题", markdown: "# 标题"), try richBlock(String(repeating: "待办正文换行。", count: 20), kind: .checklist, checked: true), NoteBlock(kind: .file, text: file.name, attachmentID: file.id), NoteBlock(kind: .image, text: image.name, attachmentID: image.id), NoteBlock(text: "尾段")]
        var note = NoteDocument(blocks: original, attachments: [file, image])
        let view = editor(note, width: 852, scale: 1)
        for (scale, width) in [(1.0, 852.0), (1.28, 582.0), (1.33, 852.0), (1.0, 582.0), (1.33, 582.0), (1.28, 852.0), (1.0, 582.0)] {
            view.setFrameSize(NSSize(width: width, height: 138))
            view.readingScale = scale
            view.loadDocument(note)
            assertReadable(try geometry(view), width: width)
            let blocks = try NotesContinuousDocument.blocks(from: view.attributedString(), scale: scale, trailingAttributes: view.trailingAttributes)
            XCTAssertEqual(blocks.map(\.text), original.map(\.text))
            XCTAssertEqual(blocks.map(\.kind), original.map(\.kind))
            XCTAssertEqual(blocks.map(\.id), original.map(\.id))
            XCTAssertEqual(blocks.compactMap(\.attachmentID), [file.id, image.id])
            XCTAssertTrue(blocks[2].isChecked)
            XCTAssertTrue(blocks[1].markdown?.hasPrefix("# ") == true)
            let storedMixed = try XCTUnwrap(blocks[0].richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
            for index in 0..<mixed.length {
                let expected = try XCTUnwrap(mixed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                let actual = try XCTUnwrap(storedMixed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(actual.pointSize, expected.pointSize, accuracy: 0.03)
                XCTAssertEqual(NSFontManager.shared.traits(of: actual).contains(.boldFontMask), NSFontManager.shared.traits(of: expected).contains(.boldFontMask))
            }
            note.blocks = blocks
        }
        XCTAssertEqual(note.attachments.map(\.id), [file.id, image.id])
    }

    @MainActor func testLongDocumentLayoutRecordsNativeMeasurementWithoutTimeThreshold() throws {
        let paragraphs = try (0..<240).map { index in
            try richBlock("第 \(index + 1) 段。" + String(repeating: "长文阅读与编辑在大字号下也需要完整保留每个字。", count: 7), size: index.isMultiple(of: 3) ? 32 : 18)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let view = editor(NoteDocument(blocks: paragraphs))
        let lines = try geometry(view)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        assertReadable(lines, width: 582)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        XCTAssertEqual(manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length, view.string.utf16.count)
        print(String(format: "LAYOUT_MEASUREMENT paragraphs=%d utf16=%d lines=%d width=582 scale=1.33 elapsed_seconds=%.4f height=%.1f", paragraphs.count, view.string.utf16.count, lines.count, elapsed, manager.usedRect(for: container).height))
    }
}
