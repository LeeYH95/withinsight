import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Immediate, app-styled help without AppKit's delayed system tooltip.
    func notesTooltip(_ text: String) -> some View {
        background(NotesTooltipAnchor(text: text)).accessibilityHint(text)
    }
}

enum NotesTooltipGeometry {
    static func frame(anchor: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let below = anchor.minY - height - 7
        let y = below >= safe.minY ? below : anchor.maxY + 7
        return NSRect(x: min(max(anchor.midX - width / 2, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

private final class NotesTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class NotesTooltipPresenter {
    static let shared = NotesTooltipPresenter()
    private(set) var panel: NSPanel?
    private weak var anchorView: NSView?
    private weak var originWindow: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private let pointerLocation: () -> NSPoint
    var isPresented: Bool { panel != nil }

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) { self.pointerLocation = pointerLocation }

    func show(_ text: String, from view: NSView) {
        guard !text.isEmpty, let window = view.window, window.isVisible,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return }
        let point = view.convert(window.convertPoint(fromScreen: pointerLocation()), from: nil)
        guard view.visibleRect.contains(point) else { return }
        if anchorView === view, panel?.title == text { return }
        dismiss()

        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let font = NSFont.systemFont(ofSize: 12)
        let textWidth = min(320, max(1, visible.width - 38))
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // Measure the actual cell, including its padding and CJK fallback fonts.
        // NSString's glyph bounds can be narrower than NSTextField's drawing area.
        let measured = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000))
        let labelWidth = min(textWidth, ceil(measured.width))
        let labelHeight = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 10_000)).height)
        let size = NSSize(width: labelWidth + 22, height: labelHeight + 16)
        let popup = NotesTooltipPanel(contentRect: NotesTooltipGeometry.frame(anchor: anchor, size: size, visible: visible),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.title = text
        popup.backgroundColor = .clear
        popup.isOpaque = false
        popup.hasShadow = true
        popup.ignoresMouseEvents = true
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = true
        popup.level = .popUpMenu
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        popup.appearance = NotesTheme.appearance() ?? window.effectiveAppearance

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 9
        label.frame = NSRect(x: 11, y: 8, width: labelWidth, height: labelHeight)
        label.isSelectable = false
        label.setAccessibilityLabel(text)
        let dark = popup.appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        content.layer?.backgroundColor = NSColor(srgbRed: dark ? 0.18 : 1,
                                                 green: dark ? 0.21 : 1,
                                                 blue: dark ? 0.25 : 1, alpha: 1).cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(srgbRed: dark ? 0.29 : 0.86,green: dark ? 0.33 : 0.89,blue: dark ? 0.39 : 0.92,alpha:1).cgColor
        label.textColor = NSColor(srgbRed: dark ? 0.90 : 0.15,green: dark ? 0.92 : 0.19,blue: dark ? 0.96 : 0.24,alpha:1)
        content.addSubview(label)
        popup.contentView = content
        panel = popup; anchorView = view; originWindow = window
        if !NotesMotion.reduced { popup.alphaValue = 0 }
        window.addChildWindow(popup, ordered: .above)
        popup.orderFrontRegardless()
        if !NotesMotion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                popup.animator().alphaValue = 1
            }
        }
        installDismissal(for: window)
    }

    func dismiss(ifAnchoredTo view: NSView) {
        if anchorView === view { dismiss() }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let old = panel
        panel = nil; anchorView = nil
        if let old { originWindow?.removeChildWindow(old); old.orderOut(nil); old.close() }
        originWindow = nil
    }

    private func installDismissal(for window: NSWindow) {
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(monitor) }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
    }
}

struct NotesTooltipAnchor: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.text = text }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: view)
    }

    final class AnchorView: NSView {
        var text = ""
        private var tracking: NSTrackingArea?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { NotesTooltipPresenter.shared.show(text, from: self) }
        override func mouseExited(with event: NSEvent) { NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: self) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: self) }
        }
    }
}
