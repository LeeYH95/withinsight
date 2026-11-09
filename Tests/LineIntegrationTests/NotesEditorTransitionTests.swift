import AppKit
import XCTest
@testable import Tendedero

final class NotesEditorTransitionTests: XCTestCase {
    func testMorphUsesActualScreenSpaceAnchorAcrossNegativeDisplayCoordinates() {
        let card = NSRect(x: -1500, y: 840, width: 150, height: 104)
        let editor = NSRect(x: -1320, y: 140, width: 920, height: 650)
        XCTAssertEqual(NotesEditorTransitionGeometry.frame(anchor: card, editor: editor, progress: 0), card)
        XCTAssertEqual(NotesEditorTransitionGeometry.frame(anchor: card, editor: editor, progress: 1), editor)
        let halfway = NotesEditorTransitionGeometry.frame(anchor: card, editor: editor, progress: 0.5)
        XCTAssertEqual(halfway.midX, (card.midX + editor.midX) / 2, accuracy: 0.001)
        XCTAssertEqual(halfway.midY, (card.midY + editor.midY) / 2, accuracy: 0.001)
        XCTAssertEqual(halfway.height, (card.height + editor.height) / 2, accuracy: 0.001)
    }

    func testHiddenOrInvalidAnchorFallsBackInsideCurrentVisibleDisplay() {
        XCTAssertNil(NotesEditorTransitionGeometry.validAnchor(.zero))
        XCTAssertNil(NotesEditorTransitionGeometry.validAnchor(NSRect(x: CGFloat.nan, y: 0, width: 50, height: 30)))
        let display = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = NotesEditorTransitionGeometry.fallbackAnchor(editor: NSRect(x: 200, y: 20, width: 920, height: 650), visible: display)
        XCTAssertTrue(display.contains(frame))
        XCTAssertEqual(frame.maxY, display.maxY)
    }

    func testRapidReversalRetainsPresentationAndVelocityThenSettles() {
        var motion = NotesEditorTransitionProgress(open: false)
        motion.retarget(open: true)
        motion.advance(by: 0.08)
        let before = motion.value
        let velocity = motion.velocity
        motion.retarget(open: false)
        XCTAssertEqual(motion.value, before, "Reversal must not restart at either endpoint")
        XCTAssertEqual(motion.velocity, velocity, "Reversal must not create a velocity discontinuity")
        motion.advance(by: 1 / 120)
        XCTAssertLessThan(abs(motion.value - before), 0.06)
        for _ in 0..<120 { motion.advance(by: 1 / 120) }
        XCTAssertEqual(motion.value, 0)
        XCTAssertEqual(motion.velocity, 0)
        motion.retarget(open: true)
        for _ in 0..<120 { motion.advance(by: 1 / 120) }
        XCTAssertEqual(motion.value, 1)
    }

    func testTextIsAbsentInTheSmallShellAndFullyVisibleAtEditorDestination() {
        XCTAssertEqual(NotesEditorTransitionGeometry.contentOpacity(0), 0)
        XCTAssertEqual(NotesEditorTransitionGeometry.contentOpacity(0.86), 0)
        XCTAssertEqual(NotesEditorTransitionGeometry.contentOpacity(0.93), 0.5, accuracy: 0.001)
        XCTAssertEqual(NotesEditorTransitionGeometry.contentOpacity(1), 1)
        XCTAssertEqual(NotesEditorTransitionGeometry.shellOpacity(0), 0)
    }

    @MainActor func testNativeWindowReversalPreservesFramePinLevelAndResponder() throws {
        _ = NSApplication.shared
        guard !NotesMotion.reduced else { throw XCTSkip("System or app has reduced motion enabled") }
        let window = NotesWindow(contentRect: NSRect(x: 180, y: 160, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        let text = SnapshotProbeTextView(frame: NSRect(x: 20, y: 20, width: 600, height: 400))
        text.string = "尚未改动的正文"
        window.contentView = text
        window.makeFirstResponder(text)
        let savedFrame = window.frame
        let anchor = NSRect(x: 420, y: 800, width: 150, height: 104)
        NotesEditorTransition.show(window, from: anchor)
        defer { NotesEditorTransition.finish(window); window.orderOut(nil) }
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        NotesEditorTransition.hide(window, to: anchor)
        let closingFrame = NotesEditorTransition.presentationFrame(for: window)
        NotesEditorTransition.show(window, from: anchor)
        XCTAssertEqual(NotesEditorTransition.presentationFrame(for: window), closingFrame)
        XCTAssertEqual(window.frame, savedFrame, "The actual editor must never be resized to the thumbnail")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(NotesEditorTransition.isAnimating(window))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(window.frame, savedFrame)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(text.string, "尚未改动的正文")
        NotesEditorTransition.show(window, from: anchor)
        XCTAssertFalse(NotesEditorTransition.isAnimating(window), "Focusing an already open editor must not restart from the rope")
        NotesEditorTransition.hide(window, to: anchor)
        XCTAssertEqual(window.alphaValue, 1, "The live editor starts closing at its current opacity")
        XCTAssertTrue(window.ignoresMouseEvents)
        NotesEditorTransition.finish(window)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, savedFrame)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(text.snapshotRequests, 0, "Opening and closing must not render the editor into a bitmap")
    }

    @MainActor func testReducedMotionNeverCreatesAnOverlayOrLeavesAnInvisibleInputWindow() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "notesReduceMotion")
        defaults.set(true, forKey: "notesReduceMotion")
        defer { defaults.set(previous, forKey: "notesReduceMotion") }
        let window = NotesWindow(contentRect: NSRect(x: 180, y: 160, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let frame = window.frame
        NotesEditorTransition.show(window, from: nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(NotesEditorTransition.isAnimating(window))
        NotesEditorTransition.hide(window, to: nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
    }
}

private final class SnapshotProbeTextView: NSTextView {
    private(set) var snapshotRequests = 0

    override func bitmapImageRepForCachingDisplay(in rect: NSRect) -> NSBitmapImageRep? {
        snapshotRequests += 1
        return super.bitmapImageRepForCachingDisplay(in: rect)
    }
}
