import AppKit
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
                let matches = checkbox ? (r > 0.28 && r < 0.7 && g < 0.72 && b < 0.88 && b - r > 0.025) : max(r, g, b) < 0.30
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
                    XCTAssertEqual(box.midY, text.midY, accuracy: max(1, size * scale * 0.06), "size=\(size), zoom=\(scale), checked=\(checked)")
                    if size == 15 && scale == 1 && checked { try evidence(bitmap, name: "editor-checklist") }
                }
            }
        }
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
