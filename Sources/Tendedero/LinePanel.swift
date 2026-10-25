import AppKit

/// A transparent strip which floats over other apps and yields to our active
/// notes windows. It never takes focus and passes clicks through outside cards.
final class LinePanel: NSPanel {
    private var orderingObservers: [NSObjectProtocol] = []
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, full screen ones included. Whether the line comes down
        // over a full screen app is up to the user, see FullScreen.showLineOver.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        title = "LineNotes 挂绳"
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            orderingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.orderFrontRegardless()
                    // Resign/close notifications can arrive before keyWindow is
                    // updated. Re-evaluate once after AppKit finishes the change.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isVisible else { return }
                        self.orderFrontRegardless()
                    }
                }
            })
        }
    }
    deinit { orderingObservers.forEach(NotificationCenter.default.removeObserver) }

    static func foregroundNotesWindow(key: NSWindow?, main: NSWindow?, active: Bool) -> NSWindow? {
        guard active else { return nil }
        func owner(_ window: NSWindow?) -> NSWindow? {
            var candidate = window
            while let current = candidate {
                if current is NotesWindow { return current.isVisible && !current.isMiniaturized ? current : nil }
                candidate = current.sheetParent ?? current.parent
            }
            return nil
        }
        // A rope menu can take key status while an unrelated notes window
        // remains main. Keep the rope floating rather than lower it behind
        // that window; menus from notes still yield to their actual owner.
        if let key, let source = NotesMenuPresenter.shared.sourceWindow(for: key) {
            return owner(source)
        }
        return owner(key) ?? owner(main)
    }

    override func orderOut(_ sender: Any?) {
        NotesMenuPresenter.shared.dismiss(ifAnchoredTo: self)
        super.orderOut(sender)
    }

    override func orderFrontRegardless() {
        orderBehindNotesWindow(Self.foregroundNotesWindow(key: NSApp.keyWindow, main: NSApp.mainWindow, active: NSApp.isActive))
    }

    func orderBehindNotesWindow(_ foreground: NSWindow?) {
        if let foreground {
            // Keep the rope immediately behind our current working window,
            // above other normal windows, without making that window always-on-top.
            let targetLevel = NSWindow.Level(rawValue: min(NSWindow.Level.floating.rawValue, foreground.level.rawValue))
            if level != targetLevel { level = targetLevel }
            super.order(.below, relativeTo: foreground.windowNumber)
        } else {
            if level != .floating { level = .floating }
            super.orderFrontRegardless()
        }
    }

    /// Two-finger swipes and the scroll wheel, for moving along a long line.
    var onScroll: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, let onScroll {
            onScroll(event)
        } else {
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
