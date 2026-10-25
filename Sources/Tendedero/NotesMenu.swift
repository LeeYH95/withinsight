import AppKit
import QuartzCore
import SwiftUI
import NotesCore

enum NotesMenuAlignment { case leading, trailing }

/// NSMenu is only the action model. This app never asks it to draw a popup.
@MainActor final class NotesMenuNavigator: ObservableObject {
    private let root: NSMenu
    private var parents: [(menu: NSMenu, selection: Int?)] = []
    @Published private(set) var menu: NSMenu
    @Published var selected: Int?
    @Published private(set) var keyboardRevision = 0
    var items: [NSMenuItem] { menu.items.filter { !$0.isHidden } }
    var depth: Int { parents.count }
    var title: String { menu.title }
    init(_ root: NSMenu) {
        self.root = root; menu = root
        let visible = root.items.filter { !$0.isHidden }
        selected = Self.initialSelection(visible)
    }
    private static func initialSelection(_ items: [NSMenuItem]) -> Int? {
        let checked = items.indices.filter { items[$0].state == .on && available(items[$0]) }
        if checked.count == 1 && !items.contains(where: { $0.isSeparatorItem || $0.submenu != nil }) { return checked.first }
        return items.firstIndex(where: available)
    }
    static func available(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.isEnabled && (item.action != nil || item.submenu != nil)
    }
    func move(_ direction: Int) {
        let valid = items.indices.filter { Self.available(items[$0]) }
        guard !valid.isEmpty else { selected = nil; return }
        let current = selected.flatMap { valid.firstIndex(of: $0) } ?? (direction > 0 ? -1 : 0)
        selected = valid[(current + direction + valid.count) % valid.count]
        keyboardRevision += 1
    }
    func select(prefix: String) {
        guard !prefix.isEmpty else { return }
        if let index = items.firstIndex(where: { Self.available($0) && $0.title.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }) {
            selected = index; keyboardRevision += 1
        }
    }
    @discardableResult func activate(_ index: Int) -> NSMenuItem? {
        guard items.indices.contains(index), Self.available(items[index]) else { return nil }
        let item = items[index]
        if let submenu = item.submenu {
            if submenu.title.isEmpty { submenu.title = item.title }
            parents.append((menu, index)); menu = submenu
            selected = Self.initialSelection(items)
            keyboardRevision += 1
            return nil
        }
        return item
    }
    @discardableResult func back() -> Bool {
        guard let parent = parents.popLast() else { return false }
        menu = parent.menu; selected = parent.selection; keyboardRevision += 1
        return true
    }
}

enum NotesMenuGeometry {
    static func containsVisiblePoint(_ point: NSPoint, in view: NSView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.visibleRect.contains(point)
    }
    static func frame(anchor: NSRect, size: NSSize, visible: NSRect, alignment: NotesMenuAlignment) -> NSRect {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        let x = alignment == .trailing ? anchor.maxX - width : anchor.minX
        let below = anchor.minY - height - 8
        let y = below >= safe.minY ? below : anchor.maxY + 8
        return NSRect(x: min(max(x, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

private final class NotesPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class NotesMenuPresenter {
    static let shared = NotesMenuPresenter()
    private(set) var panel: NSPanel?
    private(set) var navigator: NotesMenuNavigator?
    private weak var anchorView: NSView?
    private weak var originWindow: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private var anchorRect = NSRect.zero
    private var alignment = NotesMenuAlignment.leading
    private var togglesFromAnchor = false
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onDismiss: (() -> Void)?
    private var prefix = ""
    private var lastTyped = Date.distantPast
    var isPresented: Bool { panel != nil }

    /// A popup can be anchored to the rope or status bar while an unrelated
    /// notes window remains main. Resolve ownership from the actual anchor.
    func sourceWindow(for popup: NSWindow) -> NSWindow? {
        popup === panel ? originWindow : nil
    }

    func toggle(_ menu: NSMenu, from view: NSView, alignment: NotesMenuAlignment = .leading) {
        if panel != nil, anchorView === view { dismiss(); return }
        show(menu, from: view, alignment: alignment, togglesFromAnchor: true)
    }
    func show(_ menu: NSMenu, from view: NSView, at point: NSPoint? = nil,
              alignment: NotesMenuAlignment = .leading, togglesFromAnchor: Bool = false,
              onDismiss: (() -> Void)? = nil) {
        guard let window = view.window else { return }
        NotesTooltipPresenter.shared.dismiss()
        dismiss(animated: false)
        let model = NotesMenuNavigator(menu)
        guard !model.items.isEmpty else { return }
        self.navigator = model; anchorView = view; originWindow = window
        // AX presses and clicks in a background window may run before AppKit
        // updates keyWindow; the control's own editor is the focus destination.
        previousKeyWindow = window.canBecomeKey ? window : NSApp.keyWindow
        self.alignment = alignment; self.onDismiss = onDismiss
        self.togglesFromAnchor = togglesFromAnchor
        let local = point.map { NSRect(origin: $0, size: .zero) } ?? view.bounds
        anchorRect = window.convertToScreen(view.convert(local, to: nil))
        let popup = NotesPopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.title = menu.title.isEmpty ? "闪念操作菜单" : menu.title
        popup.backgroundColor = .clear; popup.isOpaque = false; popup.hasShadow = true
        popup.isReleasedWhenClosed = false
        popup.level = .popUpMenu; popup.hidesOnDeactivate = false
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        popup.appearance = NotesTheme.appearance() ?? window.effectiveAppearance
        let host = NSHostingView(rootView: NotesMenuSurface(navigator: model, presenter: self))
        host.sizingOptions = []
        popup.contentView = host
        panel = popup
        layout(animated: false)
        let final = popup.frame
        if !NotesMotion.reduced { popup.alphaValue = 0; popup.setFrame(final.offsetBy(dx: 0, dy: 4), display: false) }
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true {
            // Taking key status would interrupt an input method composition.
            // The local monitor can handle dismissal while its editor stays key.
            popup.orderFrontRegardless()
        } else { popup.makeKeyAndOrderFront(nil) }
        if !NotesMotion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                popup.animator().alphaValue = 1; popup.animator().setFrame(final, display: true)
            }
        }
        installMonitors(for: window)
    }
    private func layout(animated: Bool) {
        guard let panel, let navigator else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) } ?? originWindow?.screen ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let windowFrame = originWindow?.frame.intersection(screenFrame) ?? screenFrame
        let visible = windowFrame.isEmpty ? screenFrame : windowFrame
        if navigator.menu is NotesPaperMenu {
            var frame = NotesMenuGeometry.frame(anchor: anchorRect, size: NSSize(width: 260, height: min(212,visible.height - 16)), visible: visible, alignment: alignment)
            if anchorRect.maxY + 8 + frame.height <= visible.maxY - 8 { frame.origin.y = anchorRect.maxY + 8 }
            panel.setFrame(frame, display: true)
            return
        }
        let longest = navigator.items.map { (($0.title + ($0.notesDetail.isEmpty ? "" : "  " + $0.notesDetail)) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 150
        let width = min(390, max(248, longest + 90))
        let rows = navigator.items.reduce(CGFloat(0)) { $0 + ($1.isSeparatorItem ? 13 : 36) }
        let header: CGFloat = navigator.depth > 0 || !navigator.title.isEmpty ? 39 : 0
        let size = NSSize(width: width, height: min(rows + header + 14, min(650, visible.height - 24)))
        let frame = NotesMenuGeometry.frame(anchor: anchorRect, size: size, visible: visible, alignment: alignment)
        if animated && !NotesMotion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
    func choose(_ index: Int) {
        guard let navigator else { return }
        let depth = navigator.depth
        if let item = navigator.activate(index) {
            // Release tracking before an action opens a save panel or another window.
            if navigator.menu is NotesPaperMenu {
                Self.dispatch(item)
                navigator.selected = index
            } else {
                dismiss(animated: false)
                Self.dispatch(item)
            }
        } else if navigator.depth != depth { layout(animated: true) }
    }
    func back() { if navigator?.back() == true { layout(animated: true) } }
    static func dispatch(_ item: NSMenuItem) {
        guard item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func dismiss(ifAnchoredTo window: NSWindow) {
        if originWindow === window { dismiss(animated: false) }
    }
    func dismiss(animated: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let old = panel
        let previous = previousKeyWindow
        panel = nil; navigator = nil; anchorView = nil; originWindow = nil; previousKeyWindow = nil
        if old?.isKeyWindow == true { old?.resignKey() }
        if previous?.isVisible == true { previous?.makeKey() }
        prefix = ""; lastTyped = .distantPast
        let finished = onDismiss; onDismiss = nil; finished?()
        guard let old else { return }
        old.ignoresMouseEvents = true
        if animated && !NotesMotion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1; old.animator().alphaValue = 0
            } completionHandler: { old.close() }
        } else { old.close() }
    }
    private func installMonitors(for window: NSWindow) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel], handler: { [weak self] event in
            let forwarded: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if event.window === panel { return }
                if event.type != .scrollWheel, self.togglesFromAnchor, let source = self.anchorView, event.window === source.window,
                   source.bounds.contains(source.convert(event.locationInWindow, from: nil)) { return }
                self.dismiss()
            }
            return forwarded
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            var forwarded: NSEvent? = event
            MainActor.assumeIsolated { if let self { forwarded = self.handleKey(event) } }
            return forwarded
        }) { monitors.append(monitor) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(animated: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        })
    }
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let navigator else { return event }
        // Respect an input method's ongoing marked text; only Escape dismisses.
        if (originWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            if event.keyCode == 53 { dismiss(); return nil }
            return forwardAndDismiss(event)
        }
        if navigator.menu is NotesPaperMenu {
            switch event.keyCode {
            case 53: dismiss(); return nil
            case 125: navigator.move(3); return nil
            case 126: navigator.move(-3); return nil
            case 124: navigator.move(1); return nil
            case 123: navigator.move(-1); return nil
            case 115: navigator.selected = 0; return nil
            case 119: navigator.selected = navigator.items.count - 1; return nil
            case 36, 76, 49: if let index = navigator.selected { choose(index) }; return nil
            case 48: return forwardAndDismiss(event)
            default: break
            }
        }
        switch event.keyCode {
        case 53: if navigator.depth > 0 { back() } else { dismiss() }; return nil
        case 125: navigator.move(1); return nil
        case 126: navigator.move(-1); return nil
        case 124: if let index = navigator.selected, navigator.items[index].submenu != nil { choose(index) }; return nil
        case 123: back(); return nil
        case 36, 76, 49: if let index = navigator.selected { choose(index) }; return nil
        case 48: return forwardAndDismiss(event)
        default: break
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.charactersIgnoringModifiers, !text.isEmpty {
            if Date().timeIntervalSince(lastTyped) > 0.65 { prefix = "" }
            prefix += text; lastTyped = Date(); navigator.select(prefix: prefix)
            return nil
        }
        return forwardAndDismiss(event)
    }
    private func forwardAndDismiss(_ event: NSEvent) -> NSEvent? {
        // The event targets the temporary panel, so forward explicitly after
        // restoring its source window instead of losing it in a closed panel.
        let destination = previousKeyWindow
        dismiss(animated: false)
        if let destination, destination.isVisible {
            let forwarded = event.window === destination ? event : NSEvent.keyEvent(with: .keyDown,
                location: event.locationInWindow, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: destination.windowNumber, context: nil, characters: event.characters ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
            if !destination.performKeyEquivalent(with: forwarded) { destination.sendEvent(forwarded) }
        } else { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        return nil
    }
}

private struct NotesMenuSurface: View {
    @ObservedObject var navigator: NotesMenuNavigator
    let presenter: NotesMenuPresenter
    var body: some View {
        if let paperMenu = navigator.menu as? NotesPaperMenu {
            NotesPaperPalette(navigator: navigator, menu: paperMenu, presenter: presenter)
        } else { actionMenu }
    }
    private var actionMenu: some View {
        VStack(spacing: 0) {
            if navigator.depth > 0 {
                Button { presenter.back() } label: {
                    HStack(spacing: 9) { Image(systemName: "chevron.left"); Text(navigator.title.isEmpty ? "返回" : navigator.title); Spacer() }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(NotesTheme.muted).padding(.horizontal, 12).frame(height: 36)
                }.buttonStyle(NotesPressStyle()).accessibilityLabel("返回上一级菜单")
                Rectangle().fill(NotesTheme.border.opacity(0.7)).frame(height: 1).padding(.horizontal, 7).padding(.bottom, 2)
            } else if !navigator.title.isEmpty {
                HStack { Text(navigator.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(NotesTheme.muted); Spacer() }
                    .padding(.horizontal, 12).frame(height: 36)
                Rectangle().fill(NotesTheme.border.opacity(0.7)).frame(height: 1).padding(.horizontal, 7).padding(.bottom, 2)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(navigator.items.enumerated()), id: \.offset) { index, item in
                            if item.isSeparatorItem {
                                Rectangle().fill(NotesTheme.border.opacity(0.7)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)
                            } else { row(item, at: index).id(index) }
                        }
                    }
                }.scrollIndicators(.never)
                    .onChange(of: navigator.keyboardRevision) { _, _ in
                        if let index = navigator.selected { scroll.scrollTo(index, anchor: .center) }
                    }
            }
        }.padding(7).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotesTheme.shell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NotesTheme.border.opacity(0.85), lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain).accessibilityLabel("闪念操作菜单")
    }
    private func row(_ item: NSMenuItem, at index: Int) -> some View {
        let selected = navigator.selected == index && NotesMenuNavigator.available(item)
        let checked = item.state == .on
        return Button { presenter.choose(index) } label: {
            HStack(spacing: 9) {
                ZStack {
                    if item.state != .off { Image(systemName: item.state == .mixed ? "minus" : "checkmark").font(.system(size: 12, weight: .semibold)) }
                    else if let image = item.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 15, height: 15) }
                }.frame(width: 18)
                if let paper = item.notesPaperSwatch {
                    Circle().fill(NotesTheme.editorSwatch(paper))
                        .overlay(Circle().stroke(NotesTheme.border, lineWidth: 1))
                        .frame(width: 17, height: 17).accessibilityHidden(true)
                }
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 10)
                if !item.notesDetail.isEmpty { Text(item.notesDetail).font(.system(size: 11)).foregroundStyle(NotesTheme.muted) }
                if item.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                else if !item.keyEquivalent.isEmpty { Text(shortcut(item)).font(.system(size: 11)).foregroundStyle(NotesTheme.muted) }
            }.font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(item.notesDestructive ? NotesTheme.danger : (selected || checked ? NotesTheme.accent : NotesTheme.text))
                .padding(.horizontal, 10).frame(height: 36).frame(maxWidth: .infinity)
                .background(NotesTheme.accent.opacity(selected ? 0.11 : (checked ? 0.06 : 0)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .opacity(item.isEnabled ? 1 : 0.42)
        }.buttonStyle(.plain).disabled(!NotesMenuNavigator.available(item))
            .onHover { if $0 && NotesMenuNavigator.available(item) { navigator.selected = index } }
            .animation(NotesMotion.quick, value: selected)
            .accessibilityLabel(item.title).accessibilityValue(item.state == .on ? "已选中" : "")
    }
    private func shortcut(_ item: NSMenuItem) -> String {
        let mask = item.keyEquivalentModifierMask
        return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
            + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
    }
}

struct NotesMenuButton<Label: View>: View {
    let name: String
    let tooltip: String?
    var alignment: NotesMenuAlignment
    var menu: () -> NSMenu
    @ViewBuilder var label: () -> Label
    @State private var anchor: NSView?
    init(_ name: String, tooltip: String? = nil, alignment: NotesMenuAlignment = .leading,
         menu: @escaping () -> NSMenu, @ViewBuilder label: @escaping () -> Label) {
        self.name = name; self.tooltip = tooltip; self.alignment = alignment; self.menu = menu; self.label = label
    }
    var body: some View {
        Button {
            if let anchor { NotesMenuPresenter.shared.toggle(menu(), from: anchor, alignment: alignment) }
        } label: { label() }
            .buttonStyle(NotesPressStyle()).accessibilityLabel(name)
            .background { if let tooltip { NotesTooltipAnchor(text: tooltip) } }
            .background(NotesMenuAnchor { anchor = $0 })
    }
}

struct NotesMenuAnchor: NSViewRepresentable {
    let receive: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        DispatchQueue.main.async { receive(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func notesContextMenu(_ menu: @escaping () -> NSMenu) -> some View {
        modifier(NotesContextMenuModifier(menu: menu))
    }
    func notesTextContextMenu() -> some View {
        modifier(NotesContextMenuModifier(menu: { NSMenu() }, textEditing: true))
    }
}

private struct NotesContextMenuModifier: ViewModifier {
    let menu: () -> NSMenu
    var textEditing = false
    func body(content: Content) -> some View {
        content.background(ContextAnchor(menu: menu, textEditing: textEditing))
    }
    private struct ContextAnchor: NSViewRepresentable {
        let menu: () -> NSMenu
        let textEditing: Bool
        func makeNSView(context: Context) -> ContextView { ContextView() }
        func updateNSView(_ nsView: ContextView, context: Context) { nsView.menuProvider = menu; nsView.textEditing = textEditing }
    }
    private final class ContextView: NSView {
        var menuProvider: () -> NSMenu = { NSMenu() }
        var textEditing = false
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                var forwarded: NSEvent? = event
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                          NotesMenuGeometry.containsVisiblePoint(self.convert(event.locationInWindow, from: nil), in: self) else { return }
                    if self.textEditing {
                        if NotesTextMenu.showFieldMenu(inside: self, event: event) { forwarded = nil }
                    } else {
                        NotesMenuPresenter.shared.show(self.menuProvider(), from: self, at: self.convert(event.locationInWindow, from: nil))
                        forwarded = nil
                    }
                }
                return forwarded
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension NSMenuItem {
    @discardableResult func notesDanger() -> Self { notesDestructive = true; return self }
    @discardableResult func notesSymbol(_ name: String) -> Self {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return self
    }
    var notesDetail: String {
        get { (representedObject as? NotesMenuMetadata)?.detail ?? "" }
        set { representedObject = NotesMenuMetadata(destructive: notesDestructive, detail: newValue, paper: notesPaperSwatch) }
    }
    var notesDestructive: Bool {
        get { (representedObject as? NotesMenuMetadata)?.destructive == true }
        set { representedObject = NotesMenuMetadata(destructive: newValue, detail: notesDetail, paper: notesPaperSwatch) }
    }
    var notesPaperSwatch: NotePaper? {
        get { (representedObject as? NotesMenuMetadata)?.paper }
        set { representedObject = NotesMenuMetadata(destructive: notesDestructive, detail: notesDetail, paper: newValue) }
    }
}
private struct NotesMenuMetadata { let destructive: Bool; var detail: String = ""; var paper: NotePaper? = nil }

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func fire() { handler() }
}
