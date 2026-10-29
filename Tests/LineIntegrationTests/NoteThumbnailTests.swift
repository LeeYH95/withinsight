import AppKit
import NotesCore
import XCTest
@testable import Tendedero

final class NoteThumbnailTests: XCTestCase {
    @MainActor private func render(_ blocks: [NoteBlock], name: String, appearance: NSAppearance.Name = .aqua) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let old = NSApp.appearance
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments; arguments["notesTheme"] = "system"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSApp.appearance = NSAppearance(named: appearance)
        defer {
            NSApp.appearance = old
            defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain)
        }
        let image = NoteThumbnail.image(for: NoteDocument(title: "预览验收", blocks: blocks))
        XCTAssertEqual(image.size, NSSize(width: 405, height: 280))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        if let path = ProcessInfo.processInfo.environment["SHIPIAN_THUMBNAIL_EVIDENCE"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func ink(_ bitmap: NSBitmapImageRep, in rect: NSRect, pointsWidth: CGFloat = 405) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / pointsWidth
        var count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.5 && max(c.redComponent, c.greenComponent, c.blueComponent) < 0.3 { count += 1 }
            }
        }
        return count
    }

    @MainActor func testLongParagraphUsesAvailableLowerLines() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "预览应该继续显示正文，直到可用空间放不下完整的一行。", count: 20))], name: "long-paragraph")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 65, y: 225, width: 300, height: 27)), 30,
                             "Long text must use the lower body area instead of stopping after five lines")
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 65, y: 254, width: 300, height: 12)), 0,
                       "Do not draw a partial line into the bottom padding")
    }

    @MainActor func testLongChecklistItemUsesMoreThanTwoLines() throws {
        let bitmap = try render([NoteBlock(kind: .checklist, text: String(repeating: "这是一条需要完整利用预览空间的长待办，继续显示后面的说明。", count: 12), isChecked: true)], name: "long-checklist")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 70, y: 225, width: 290, height: 27)), 30)
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 28, y: 125, width: 25, height: 120)), 0,
                       "Wrapped checklist text must retain its text-column indent")
    }

    @MainActor func testMoreThanTwoChecklistItemsAreVisible() throws {
        let bitmap = try render((1...8).map { NoteBlock(kind: .checklist, text: "第\($0)条待办", isChecked: true) }, name: "many-checks")
        let scale = CGFloat(bitmap.pixelsWide) / 405
        var bands = 0, previous = false
        for y in Int(65 * scale)..<Int(250 * scale) {
            let present = (Int(28 * scale)..<Int(58 * scale)).contains { x in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.blueComponent - c.redComponent > 0.1 && c.redComponent < 0.5
            }
            if present && !previous { bands += 1 }
            previous = present
        }
        XCTAssertGreaterThan(bands, 2, "Use room for later checklist items instead of taking a fixed prefix of two")
    }

    @MainActor func testParagraphBeforeChecklistRemainsFirstInPreview() throws {
        let paragraph = NoteBlock(text: "先显示这段正文")
        let plain = try render([paragraph], name: "paragraph-only")
        let mixed = try render([paragraph, NoteBlock(kind: .checklist, text: "然后是待办")], name: "mixed")
        let scale = CGFloat(plain.pixelsWide) / 405
        var changed = 0
        for y in Int(77 * scale)..<Int(98 * scale) {
            for x in Int(65 * scale)..<Int(330 * scale) {
                if plain.colorAt(x: x, y: y) != mixed.colorAt(x: x, y: y) { changed += 1 }
            }
        }
        XCTAssertEqual(changed, 0, "A later checklist must not hide the first paragraph")
    }

    @MainActor func testShortContentLeavesNaturalEmptySpace() throws {
        let bitmap = try render([NoteBlock(text: "短闪念")], name: "short")
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 65, y: 150, width: 300, height: 100)), 0)
    }

    @MainActor func testHardNewlineInsideChecklistKeepsContinuationInTextColumn() throws {
        let bitmap = try render([NoteBlock(kind: .checklist, text: "第一行\n第二行", isChecked: true)], name: "hard-newline")
        XCTAssertEqual(ink(bitmap, in: NSRect(x: 28, y: 105, width: 30, height: 38)), 0,
                       "Hard-newline continuation belongs beside the checkbox, just like soft wrapping")
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 65, y: 105, width: 170, height: 38)), 30)
    }

    @MainActor func testHeightConstraintAddsEllipsisOnlyWhenThereIsHiddenContent() throws {
        let size = NSSize(width: 349, height: 32)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        func body(_ text: String) throws -> NSBitmapImageRep {
            let image = NoteThumbnailText.image(for: NoteDocument(blocks: [NoteBlock(text: text)]), size: size, appearance: appearance)
            return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        }
        let fitting = try body("第一行"), overflowing = try body("第一行\n第二行")
        let tail = NSRect(x: 75, y: 0, width: 90, height: 32)
        XCTAssertEqual(ink(fitting, in: tail, pointsWidth: 349), 0)
        XCTAssertGreaterThan(ink(overflowing, in: tail, pointsWidth: 349), 5,
                             "A hidden later paragraph must add an ellipsis to the otherwise short visible line")
    }

    @MainActor func testDarkPreviewKeepsTextLegible() throws {
        let bitmap = try render([NoteBlock(text: String(repeating: "深色预览也应完整利用可见空间。", count: 10))], name: "dark", appearance: .darkAqua)
        let scale = CGFloat(bitmap.pixelsWide) / 405
        let background = try XCTUnwrap(bitmap.colorAt(x: Int(20 * scale), y: Int(130 * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(background.redComponent, 0.4)
        var lightInk = 0
        for y in Int(75 * scale)..<Int(250 * scale) {
            for x in Int(30 * scale)..<Int(375 * scale) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.7 { lightInk += 1 }
            }
        }
        XCTAssertGreaterThan(lightInk, 100)
    }

    @MainActor func testTallerBodyCanRenderBeyondTheNormalCardLineCount() throws {
        let size = NSSize(width: 349, height: 250)
        let image = NoteThumbnailText.image(for: NoteDocument(blocks: [NoteBlock(text: String(repeating: "可用高度增加时应当继续显示更多文字。", count: 25))]),
                                            size: size, appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        XCTAssertGreaterThan(ink(bitmap, in: NSRect(x: 0, y: 210, width: 330, height: 35), pointsWidth: 349), 30,
                             "Text layout must follow the supplied height rather than another fixed line count")
    }
}
