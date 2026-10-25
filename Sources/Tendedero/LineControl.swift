import AppKit
import SwiftUI

/// Quiet paper objects at the end of the rope. Their transparent hit targets
/// are larger than the artwork, without adding another button-shaped surface.
struct LineControl: View {
    @ObservedObject var line: Line
    let isNew: Bool
    @StateObject private var motion = HangingSwing()

    static let newID = UUID()
    static let libraryID = UUID()
    static let targetSize = CGSize(width: 40, height: 44)
    private static let clipScale: CGFloat = 0.72
    static var pinAbove: CGFloat { Layout.pinAbove * clipScale }
    private static var clipHeight: CGFloat { 26 * clipScale }
    private static var overlap: CGFloat { 4.5 + pinAbove - clipHeight }
    static var hangingHeight: CGFloat { clipHeight + overlap + targetSize.height }

    static func templateMenu(for line: Line) -> NSMenu {
        let menu = NSMenu(title: "新建闪念")
        menu.addItem(ClosureMenuItem("文字闪念") { line.onNewNote?("text") }.notesSymbol("doc.text"))
        menu.addItem(ClosureMenuItem("待办清单") { line.onNewNote?("checklist") }.notesSymbol("checklist"))
        menu.addItem(ClosureMenuItem("图文闪念") { line.onNewNote?("image") }.notesSymbol("photo"))
        return menu
    }

    var body: some View {
        VStack(spacing: Self.overlap) {
            Clothespin()
                .scaleEffect(Self.clipScale)
                .frame(width: 9 * Self.clipScale, height: Self.clipHeight)
                .zIndex(1)
            NativePaperButton(isNew: isNew, action: {
                motion.nudge(2.2)
                line.onShowNotes?()
            }, menu: isNew ? {
                Self.templateMenu(for: line)
            } : nil, onMenuPress: { motion.nudge(2.2) })
            .frame(width: Self.targetSize.width, height: Self.targetSize.height)
            .background(GeometryReader { g in
                Color.clear.preference(key: HitRectsKey.self,
                    value: [isNew ? Self.newID : Self.libraryID: g.frame(in: .global)])
            })
        }
        .frame(width: Self.targetSize.width, height: Self.hangingHeight, alignment: .top)
        .rotationEffect(.degrees(motion.angle), anchor: .top)
        .offset(y: motion.arrived ? 0 : -46)
        .opacity(motion.arrived ? 1 : 0)
        .onAppear { motion.arrive() }
        .onChange(of: line.gust) { _, _ in motion.breeze() }
    }
}

private struct NativePaperButton: NSViewRepresentable {
    let isNew: Bool
    let action: () -> Void
    let menu: (() -> NSMenu)?
    let onMenuPress: () -> Void

    func makeNSView(context: Context) -> LinePaperButton { LinePaperButton(frame: .zero) }
    func updateNSView(_ button: LinePaperButton, context: Context) {
        let label = isNew ? "新建闪念" : "全部闪念"
        button.isNew = isNew
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(label)
        button.setAccessibilityIdentifier(isNew ? "line.newNote" : "line.noteLibrary")
        button.toolTip = nil
        button.handler = action
        button.menuProvider = menu
        button.onMenuPress = onMenuPress
        button.updateArtwork()
    }
}

/// SwiftUI paints the paper, while the NSButton keeps normal keyboard, menu
/// anchoring, accessibility presses and hit testing in the transparent panel.
private final class LinePaperButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private var focused = false
    private let artwork = PaperArtworkHost(rootView: LinePaperFace(isNew: false))
    var isNew = false
    var handler: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    var onMenuPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; isBordered = false
        focusRingType = .none
        target = self; action = #selector(performAction)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.setAccessibilityElement(false)
        addSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focused = true; updateArtwork() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focused = false; updateArtwork() }
        return accepted
    }
    func updateArtwork() {
        artwork.rootView = LinePaperFace(isNew: isNew, hovered: hovered, pressed: pressed, focused: focused)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateArtwork()
    }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; updateArtwork()
        NotesTooltipPresenter.shared.show(isNew ? "新建闪念" : "全部闪念", from: self)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; updateArtwork()
        NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: self)
    }
    @objc private func performAction() {
        NotesTooltipPresenter.shared.dismiss()
        if let menuProvider {
            onMenuPress?()
            NotesMenuPresenter.shared.toggle(menuProvider(), from: self, alignment: .trailing)
        } else { handler?() }
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true; updateArtwork()
        if menuProvider != nil {
            performAction()
            pressed = false; updateArtwork()
        } else {
            super.mouseDown(with: event)
            pressed = false; updateArtwork()
        }
    }
    override func accessibilityPerformPress() -> Bool { performAction(); return true }
}

private final class PaperArtworkHost: NSHostingView<LinePaperFace> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Actual miniature paper layers rather than icon glyphs. Their label has the
/// same low visual weight as the approved 28 × 35 pt prototype object.
private struct LinePaperFace: View {
    let isNew: Bool
    var hovered = false
    var pressed = false
    var focused = false

    private let sheet = RoundedRectangle(cornerRadius: 4, style: .continuous)
    private var front: Color { NotesTheme.adaptive(0xFAFCFD, 0x3E4B5D) }
    private var active: Bool { hovered || focused }

    var body: some View {
        ZStack {
            if !isNew {
                sheet.fill(NotesTheme.adaptive(0xEEF1F4, 0x28313E))
                    .overlay(sheet.strokeBorder(NotesTheme.muted.opacity(0.14), lineWidth: 0.5))
                    .rotationEffect(.degrees(active && !HangingMotion.reduced ? -8 : -5), anchor: .top)
                    .offset(x: active && !HangingMotion.reduced ? -2 : -1, y: 3)
                sheet.fill(NotesTheme.adaptive(0xF4F7F9, 0x323E4D))
                    .overlay(sheet.strokeBorder(NotesTheme.muted.opacity(0.14), lineWidth: 0.5))
                    .rotationEffect(.degrees(active && !HangingMotion.reduced ? 6 : 4), anchor: .top)
                    .offset(x: active && !HangingMotion.reduced ? 2 : 1, y: 1.5)
            }
            sheet.fill(LinearGradient(colors: [front, front.opacity(0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(sheet.strokeBorder(NotesTheme.muted.opacity(0.16), lineWidth: 0.5))
                .overlay(alignment: .top) {
                    Text(isNew ? "新建" : "闪念")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(NotesTheme.muted)
                        .padding(.top, 13)
                }
                .overlay(alignment: .bottom) {
                    if !isNew {
                        VStack(spacing: 2) {
                            Capsule().fill(NotesTheme.muted.opacity(0.22))
                            Capsule().fill(NotesTheme.muted.opacity(0.14))
                        }.frame(width: 12, height: 4).padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isNew {
                        PaperLift().fill(LinearGradient(colors: [front, NotesTheme.border], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 6, height: 6)
                            .offset(x: active && !HangingMotion.reduced ? -0.5 : 0,
                                    y: active && !HangingMotion.reduced ? -0.5 : 0)
                    }
                }
                .overlay {
                    if focused { sheet.stroke(NotesTheme.accent, lineWidth: 1.5).padding(-2) }
                }
        }
        .frame(width: 28, height: 35)
        .shadow(color: NotesTheme.adaptive(0x303E50, 0x101824).opacity(active ? 0.15 : 0.10), radius: active ? 3 : 1.5, y: active ? 3 : 2)
        .scaleEffect(HangingMotion.reduced ? 1 : (pressed ? 0.95 : (active ? 1.035 : 1)), anchor: .top)
        .animation(HangingMotion.reduced ? nil : (pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6)), value: pressed)
        .animation(HangingMotion.reduced ? nil : .easeOut(duration: 0.18), value: active)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}

private struct PaperLift: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                              control: CGPoint(x: rect.midX, y: rect.maxY - 1))
            path.closeSubpath()
        }
    }
}
