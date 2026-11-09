import AppKit
import QuartzCore
import SwiftUI

/// A critically damped spring keeps both position and velocity when the user
/// reverses direction. This value type is independent of windows and clocks.
struct NotesEditorTransitionProgress {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat

    init(open: Bool) {
        value = open ? 1 : 0
        target = value
    }

    mutating func retarget(open: Bool) { target = open ? 1 : 0 }

    @discardableResult mutating func advance(by interval: TimeInterval) -> Bool {
        guard interval.isFinite, interval > 0 else { return settled }
        let omega: CGFloat = 20
        let time = CGFloat(interval)
        let offset = value - target
        let impulse = velocity + omega * offset
        let decay = exp(-omega * time)
        value = target + (offset + impulse * time) * decay
        velocity = (velocity - omega * impulse * time) * decay
        if settled { value = target; velocity = 0; return true }
        return false
    }

    private var settled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.025 }
}

enum NotesEditorTransitionGeometry {
    static func validAnchor(_ rect: NSRect?) -> NSRect? {
        guard let rect, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 8, rect.height >= 8 else { return nil }
        return rect
    }

    static func fallbackAnchor(editor: NSRect, visible: NSRect) -> NSRect {
        let width: CGFloat = min(64, visible.width)
        let height: CGFloat = min(42, visible.height)
        let x = min(max(editor.midX - width / 2, visible.minX), visible.maxX - width)
        return NSRect(x: x, y: visible.maxY - height, width: width, height: height)
    }

    static func frame(anchor: NSRect, editor: NSRect, progress: CGFloat) -> NSRect {
        let progress = min(1, max(0, progress))
        return NSRect(x: anchor.minX + (editor.minX - anchor.minX) * progress,
                      y: anchor.minY + (editor.minY - anchor.minY) * progress,
                      width: anchor.width + (editor.width - anchor.width) * progress,
                      height: anchor.height + (editor.height - anchor.height) * progress)
    }

    /// Text appears at its real point size only near the editor destination.
    /// Closing fades it before the small paper shell reaches the rope.
    static func contentOpacity(_ progress: CGFloat) -> CGFloat {
        smoothstep((progress - 0.86) / 0.14)
    }

    static func shellOpacity(_ progress: CGFloat) -> CGFloat { smoothstep(progress / 0.12) }
    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let value = min(1, max(0, value))
        return value * value * (3 - 2 * value)
    }
}

/// Editor-only morph. The document window never changes size, responder or
/// view hierarchy, so IME, undo, pinned level and saved frame survive intact.
/// A non-interactive panel animates the paper shell while the live editor
/// fades at its full size. Both surfaces follow the same reversible spring.
@MainActor enum NotesEditorTransition {
    private static var active: [ObjectIdentifier: Transition] = [:]

    static func show(_ window: NSWindow, from proposedAnchor: NSRect?) {
        let key = ObjectIdentifier(window)
        if let transition = active[key] {
            transition.retarget(open: true)
            return
        }
        guard !NotesMotion.reduced else {
            NotesWindowMotion.show(window)
            return
        }
        if window.isVisible {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            return
        }
        start(window, anchor: proposedAnchor, opening: true)
    }

    static func hide(_ window: NSWindow, to proposedAnchor: NSRect?) {
        NotesMenuPresenter.shared.dismiss(ifAnchoredTo: window)
        let key = ObjectIdentifier(window)
        if let transition = active[key] {
            transition.retarget(open: false)
            return
        }
        guard window.isVisible, !NotesMotion.reduced else {
            NotesWindowMotion.hide(window)
            return
        }
        start(window, anchor: proposedAnchor, opening: false)
    }

    /// Used before a display change or explicit expand/restore. It settles in
    /// the last requested state and cannot leave an invisible input window.
    static func finish(_ window: NSWindow) { active[ObjectIdentifier(window)]?.finish() }
    static func isAnimating(_ window: NSWindow) -> Bool { active[ObjectIdentifier(window)] != nil }
    static func presentationFrame(for window: NSWindow) -> NSRect? { active[ObjectIdentifier(window)]?.panel.frame }

    private static func start(_ window: NSWindow, anchor proposedAnchor: NSRect?, opening: Bool) {
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let anchor = NotesEditorTransitionGeometry.validAnchor(proposedAnchor)
            ?? NotesEditorTransitionGeometry.fallbackAnchor(editor: window.frame, visible: visible)
        let transition = Transition(window: window, anchor: anchor, opening: opening)
        active[ObjectIdentifier(window)] = transition
        transition.start()
    }

    @MainActor private final class Transition {
        weak var window: NSWindow?
        let panel: NSPanel
        let canvas: PaperShellView
        let anchor: NSRect
        let editorFrame: NSRect
        let originalIgnoresMouseEvents: Bool
        var progress: NotesEditorTransitionProgress
        var timer: Timer?
        var previousTime = CACurrentMediaTime()

        init(window: NSWindow, anchor: NSRect, opening: Bool) {
            self.window = window
            self.anchor = anchor
            editorFrame = window.frame
            originalIgnoresMouseEvents = window.ignoresMouseEvents
            progress = NotesEditorTransitionProgress(open: !opening)
            progress.retarget(open: opening)
            panel = NSPanel(contentRect: opening ? anchor : window.frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.animationBehavior = .none
            panel.level = NSWindow.Level(rawValue: max(window.level.rawValue, NSWindow.Level.floating.rawValue))
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
            panel.appearance = window.appearance
            canvas = PaperShellView(frame: NSRect(origin: .zero, size: panel.frame.size))
            canvas.setAccessibilityElement(false)
            panel.contentView = canvas
        }

        func start() {
            guard let window else { finish(); return }
            window.ignoresMouseEvents = true
            if progress.target == 1 {
                window.alphaValue = 0
                window.makeKeyAndOrderFront(nil)
            }
            // Prepare the live editor at its final size before the paper fades.
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.appearance = window.appearance
            applyFrame()
            panel.orderFrontRegardless()
            previousTime = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func retarget(open: Bool) {
            progress.retarget(open: open)
            if open { window?.makeKeyAndOrderFront(nil) }
            if NotesMotion.reduced { finish() }
        }

        func tick() {
            guard window != nil, !NotesMotion.reduced else { finish(); return }
            let time = CACurrentMediaTime()
            let settled = progress.advance(by: time - previousTime)
            previousTime = time
            applyFrame()
            if settled { finish() }
        }

        func applyFrame() {
            let value = min(1, max(0, progress.value))
            panel.setFrame(NotesEditorTransitionGeometry.frame(anchor: anchor, editor: editorFrame, progress: value), display: false)
            let contentOpacity = NotesEditorTransitionGeometry.contentOpacity(value)
            window?.alphaValue = contentOpacity
            panel.alphaValue = NotesEditorTransitionGeometry.shellOpacity(value) * (1 - contentOpacity)
            canvas.progress = value
            canvas.needsDisplay = true
        }

        func finish() {
            timer?.invalidate(); timer = nil
            guard let window else {
                panel.orderOut(nil)
                active = active.filter { $0.value !== self }
                return
            }
            window.ignoresMouseEvents = originalIgnoresMouseEvents
            if progress.target == 1 {
                window.alphaValue = 1
            } else {
                window.orderOut(nil)
                window.alphaValue = 1
            }
            panel.orderOut(nil)
            active[ObjectIdentifier(window)] = nil
        }
    }

    private final class PaperShellView: NSView {
        var progress: CGFloat = 0

        override func draw(_ dirtyRect: NSRect) {
            let radius = 12 + 24 * progress
            NSColor(NotesTheme.shell).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }
}
