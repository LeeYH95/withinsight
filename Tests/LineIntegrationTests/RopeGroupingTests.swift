import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class RopeGroupingTests: XCTestCase {
    @MainActor func testIndependentRulesFoldOnlyAboveThresholdAndPreserveMixedOrder() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let line = fixture.line

        for _ in 0..<4 { try fixture.hangImage(); fixture.hangNote() }
        let original = line.items.map(\.id)
        XCTAssertEqual(line.ropePresentation.slotIDs, original)
        try fixture.hangImage()
        XCTAssertEqual(line.ropePresentation.groups.map(\.kind), [.images])
        fixture.hangNote()
        XCTAssertEqual(line.ropePresentation.slotIDs, [RopeGroupKind.images.id, RopeGroupKind.notes.id])
        XCTAssertEqual(line.ropePresentation.groups.map { $0.cover.id }, Array(original.prefix(2)))

        line.setFolding(.init(enabled: false, threshold: 4), for: .images)
        XCTAssertEqual(line.ropePresentation.groups.map(\.kind), [.notes])
        line.setFolding(.init(), for: .images)
        line.setFolding(.init(enabled: false, threshold: 8), for: .notes)
        XCTAssertEqual(line.ropePresentation.groups.map(\.kind), [.images])

        line.setFolding(.init(enabled: false), for: .images)
        XCTAssertEqual(line.ropePresentation.slotIDs, line.items.map(\.id))
        let reopened = Line(restoring: false, gusts: false, defaults: fixture.defaults)
        XCTAssertEqual(reopened.foldingRules[.notes], .init(enabled: false, threshold: 8))
        XCTAssertEqual(reopened.foldingRules[.images], .init(enabled: false))
    }

    @MainActor func testExpandedGroupTakesRealSlotsAndResetsOnNextReveal() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let line = fixture.line
        line.visibleCount = 3
        line.revealed = true
        for _ in 0..<5 { try fixture.hangImage(); fixture.hangNote() }
        let imageIDs = line.items.filter { $0.ropeGroupKind == .images }.map(\.id)
        let first = try XCTUnwrap(imageIDs.first)
        let last = try XCTUnwrap(imageIDs.last)
        XCTAssertEqual(line.hangingX(for: first, width: 1200), line.hangingX(for: last, width: 1200))
        line.scroll(by: 500)
        XCTAssertEqual(line.scroll, 0)

        line.toggleRopeGroup(.images)
        XCTAssertEqual(line.expandedRopeGroup, .images)
        XCTAssertEqual(line.ropePresentation.slotIDs, imageIDs + [RopeGroupKind.notes.id])
        XCTAssertEqual(line.ropePresentation.index(for: RopeGroupKind.images.id), line.ropePresentation.index(for: first))
        XCTAssertLessThan(line.hangingX(for: first, width: 1200), line.hangingX(for: last, width: 1200))
        line.move(last, before: first)
        XCTAssertEqual(line.ropePresentation.groups.first?.cover.id, last)
        XCTAssertEqual(line.ropePresentation.slotIDs.first, last)
        line.scroll(by: -10_000)
        XCTAssertEqual(line.scroll, 0)

        try fixture.hangImage()
        XCTAssertEqual(line.ropePresentation.groups.first?.members.count, 6)
        XCTAssertEqual(line.expandedRopeGroup, .images)
        line.toggleRopeGroup(.notes)
        XCTAssertEqual(line.expandedRopeGroup, .notes)
        line.revealed = false
        line.revealed = true
        XCTAssertNil(line.expandedRopeGroup)

        line.toggleRopeGroup(.notes)
        let note = try XCTUnwrap(line.items.first(where: { $0.noteID != nil }))
        line.drop(note.id, quietly: true, animated: false)
        XCTAssertNil(line.expandedRopeGroup)
        XCTAssertFalse(line.ropePresentation.groups.contains { $0.kind == .notes })
    }

    @MainActor func testCollapsedImagesClearAsOneSlotAndUndoKeepsOriginalOrder() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let line = fixture.line
        for _ in 0..<5 { try fixture.hangImage(); fixture.hangNote() }
        let original = line.items.map(\.id)
        let batch = try XCTUnwrap(line.beginScreenshotClear())
        XCTAssertEqual(batch.targetSlots, [RopeGroupKind.images.id])
        line.releaseScreenshotSlot(RopeGroupKind.images.id, in: batch.id)
        XCTAssertEqual(line.screenshotCount, 0)
        XCTAssertEqual(line.liveCount, 5)
        line.finishScreenshotClear(batch.id)
        XCTAssertEqual(line.undoScreenshotClear(), 5)
        XCTAssertEqual(line.items.map(\.id), original)
        XCTAssertEqual(line.ropePresentation.groups.map(\.kind), [.images, .notes])
    }

    @MainActor func testNativeGroupCardAcceptsFirstClickAndDispatchesToLine() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.clean() }
        let line = fixture.line
        for _ in 0..<5 { fixture.hangNote() }
        let group = try XCTUnwrap(line.ropePresentation.groups.first)
        let host = NSHostingView(rootView: RopeGroupCard(group: group, revealed: false) { line.toggleRopeGroup(.notes) })
        host.frame = NSRect(x: 0, y: 0, width: Layout.cardWidth, height: Layout.panelHeight)
        host.layoutSubtreeIfNeeded()

        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let button = try XCTUnwrap(buttons(in: host).first)
        XCTAssertEqual(button.accessibilityIdentifier(), "rope.group.notes")
        XCTAssertEqual(button.frame.width, Layout.cardWidth - 24 + 2 * Frame.inset)
        let coverWidth = button.frame.width - 2 * Frame.inset
        let coverHeight = button.frame.height - 2 * Frame.inset
        let thumbnail = group.cover.thumb.size
        XCTAssertEqual(coverWidth / coverHeight, thumbnail.width / thumbnail.height, accuracy: 0.01)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertTrue(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
        button.performClick(nil)
        XCTAssertEqual(line.expandedRopeGroup, .notes)

        let expanded = try XCTUnwrap(line.ropePresentation.groups.first)
        let expandedHost = NSHostingView(rootView: PeggedView(item: expanded.cover, line: line, expandedGroup: expanded))
        expandedHost.frame = host.frame
        expandedHost.layoutSubtreeIfNeeded()
        let collapse = try XCTUnwrap(buttons(in: expandedHost).first)
        XCTAssertEqual(collapse.accessibilityIdentifier(), "rope.group.notes")
        XCTAssertLessThan(collapse.frame.width, button.frame.width)

        var openedNote: UUID?
        line.onOpenNote = { openedNote = $0 }
        func grabView(in view: NSView) -> GrabView? {
            if let grab = view as? GrabView { return grab }
            return view.subviews.compactMap { grabView(in: $0) }.first
        }
        XCTAssertTrue(try XCTUnwrap(grabView(in: expandedHost)).accessibilityPerformPress())
        XCTAssertEqual(openedNote, expanded.cover.noteID)
        collapse.performClick(nil)
        XCTAssertNil(line.expandedRopeGroup)
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "rope-folding-tests." + UUID().uuidString
        let defaults: UserDefaults
        let line: Line
        let thumbnail = NSImage(size: CGSize(width: 405, height: 280))
        let png: Data
        var images = 0

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            line = Line(restoring: false, gusts: false, defaults: defaults)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0))
            png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func hangImage() throws {
            let url = directory.appendingPathComponent("sample-\(images).png")
            images += 1
            try png.write(to: url)
            XCTAssertNotNil(line.hang(url, quietly: true))
        }

        func hangNote() { line.hangNote(UUID(), thumbnail: thumbnail, quietly: true) }

        func clean() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
