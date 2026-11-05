import AppKit
import QuartzCore
import SwiftUI

/// Timings for application chrome. Hanging-card physics remain in PeggedView.
enum NotesMotion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "notesReduceMotion")
    }
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
    static var standard: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
    static var selection: Animation? { reduced ? nil : .easeInOut(duration: 0.2) }
}

struct NotesPressStyle: ButtonStyle {
    var hoverFill = true
    var liftOnHover = true
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, hoverFill: hoverFill, liftOnHover: liftOnHover)
    }
    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Bool
        let liftOnHover: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var systemReduced
        @AppStorage("notesReduceMotion") private var appReduced = false
        @State private var hovered = false
        private var reduced: Bool { systemReduced || appReduced }
        var body: some View {
            configuration.label
                .offset(y: liftOnHover && !reduced && hovered && enabled && !configuration.isPressed ? -1 : 0)
                .background(hoverFill && hovered && enabled ? NotesTheme.accent.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(!reduced && configuration.isPressed && enabled ? 0.98 : 1)
                .opacity(configuration.isPressed && enabled ? 0.84 : 1)
                .animation(reduced ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(reduced ? nil : .easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// Generation checks make a rapid close→reopen interrupt the pending close.
@MainActor enum NotesWindowMotion {
    private static var generations: [ObjectIdentifier: UInt] = [:]
    private static func next(_ window: NSWindow) -> UInt {
        let key = ObjectIdentifier(window)
        let generation = (generations[key] ?? 0) &+ 1
        generations[key] = generation
        return generation
    }
    static func show(_ window: NSWindow) {
        _ = next(window)
        let wasVisible = window.isVisible
        if !wasVisible { window.alphaValue = NotesMotion.reduced ? 1 : 0 }
        window.makeKeyAndOrderFront(nil)
        guard !NotesMotion.reduced else { window.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }
    static func hide(_ window: NSWindow) {
        NotesMenuPresenter.shared.dismiss(ifAnchoredTo: window)
        let generation = next(window)
        guard window.isVisible, !NotesMotion.reduced else {
            window.orderOut(nil); window.alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak window] in
            MainActor.assumeIsolated {
                guard let window, generations[ObjectIdentifier(window)] == generation else { return }
                window.orderOut(nil); window.alphaValue = 1
            }
        }
    }
    static func resize(_ window: NSWindow, to requested: NSRect) {
        let frame = NotesWorkspace.clampedFrame(requested, for: window)
        guard !NotesMotion.reduced else { window.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}
