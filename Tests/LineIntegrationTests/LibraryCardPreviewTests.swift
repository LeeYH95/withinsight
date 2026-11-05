import AppKit
import SwiftUI
import NotesCore
import XCTest
@testable import Tendedero

final class LibraryCardPreviewTests: XCTestCase {
    @MainActor private func render(_ blocks: [NoteBlock], name: String, width: CGFloat = 320,
                                   title: String = "预览验收", image: Bool = false, dark: Bool = false) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previousAppearance }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Library-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NotesStore(directory: directory)
        let workspace = NotesWorkspace(store: store)
        var note = NoteDocument(title: title, blocks: blocks, paper: .plain)
        if image {
            note.attachments = [NoteAttachment(name: "演示图片.png", relativePath: "missing-demo.png", kind: .image, byteCount: 0)]
        }
        let renderer = ImageRenderer(content: NotesLibraryCard(note: note, workspace: workspace, store: store)
            .frame(width: width, height: 224).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
        if let directory = ProcessInfo.processInfo.environment["SHIPIAN_LIBRARY_PREVIEW_EVIDENCE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        XCTAssertEqual(bitmap.pixelsWide, Int(width * 2))
        XCTAssertEqual(bitmap.pixelsHigh, 448)
        return bitmap
    }

    private func ink(_ bitmap: NSBitmapImageRep, in rect: NSRect) -> Int {
        var count = 0
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.5 && max(c.redComponent, c.greenComponent, c.blueComponent) < 0.65 { count += 1 }
            }
        }
        return count
    }

    @MainActor func testLongParagraphFillsLowerBodyInsteadOfOneLine() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "正文应当按预览区的宽度换行，并继续显示到卡片放不下为止。", count: 12))], name: "long-paragraph")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 40, y: 119, width: 250, height: 34)), 40,
                             "The lower body must show wrapped text, not fixed-prefix whitespace")
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 40, y: 163, width: 240, height: 12)), 0,
                       "Text must stop before the footer without clipping a partial line")
    }

    @MainActor func testChecklistContinuesPastSecondItem() throws {
        let bitmap = try render((1...10).map { NoteBlock(kind: .checklist, text: "第\($0)条待办应继续显示", isChecked: true) }, name: "many-checks")
        var bands = 0, previous = false
        for y in 120..<318 {
            let present = (36..<73).contains { x in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.blueComponent-c.redComponent > 0.12 && c.redComponent < 0.55
            }
            if present && !previous { bands += 1 }
            previous = present
        }
        XCTAssertGreaterThan(bands, 2, "Later checklist items must use the available preview area")
    }

    @MainActor func testLongFirstBlockDoesNotDiscardFollowingParagraphs() throws {
        let bitmap = try render((1...8).map { NoteBlock(text: "这是第\($0)段，需要按顺序预览。") }, name: "many-paragraphs")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 40, y: 119, width: 250, height: 34)), 40,
                             "Text below the first two paragraphs must remain eligible for preview")
    }

    @MainActor func testShortContentKeepsNaturalWhitespace() throws {
        let bitmap = try render([NoteBlock(text: "只有一句短闪念")], name: "short")
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 40, y: 119, width: 250, height: 34)), 0,
                       "Do not stretch, repeat or enlarge short content to fill the card")
    }

    @MainActor func testImageCardUsesItsRemainingBodyHeight() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "图片下方也按剩余高度继续显示文字。", count: 6))], name: "image-text", image: true)
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 40, y: 151, width: 250, height: 10)), 15,
                             "An image must not force all following text into one capped line")
    }

    @MainActor func testNarrowCardAndTwoLineTitleRespectFooterPadding() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "窄卡片也按剩余高度显示正文。", count: 10))], name: "narrow-title", width: 270,
                                title: "这是一个会占据两行的很长闪念标题，需要给正文留下正确的空间")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 40, y: 123, width: 200, height: 30)), 30)
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 40, y: 163, width: 200, height: 12)), 0)
    }

    @MainActor func testLongURLUsesMoreThanOneLine() throws {
        let url = "https://example.com/resources/articles/" + String(repeating: "a-long-article-slug-with-many-details-", count: 7)
        let bitmap = try render([NoteBlock(text: url)], name: "long-url")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 40, y: 119, width: 250, height: 34)), 40)
    }

    @MainActor func testLegacyBulletIsNotDuplicatedByTheSharedPreview() {
        let note = NoteDocument(blocks: [NoteBlock(text: "• 历史条目")])
        let text = NoteThumbnailText.content(for: note, font: .systemFont(ofSize: 13), paragraphSpacing: 4)
        XCTAssertEqual(text.string, "•\t历史条目")
    }

    @MainActor func testDarkCardKeepsLowerPreviewTextLegible() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "深色卡片也继续显示正文。", count: 20))], name: "dark", dark: true)
        let background = try XCTUnwrap(bitmap.colorAt(x: 600, y: 80)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(background.redComponent, 0.5)
        var count = 0
        for y in 238..<306 {
            for x in 80..<580 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.65 { count += 1 }
            }
        }
        XCTAssertGreaterThan(count, 40)
    }
}
