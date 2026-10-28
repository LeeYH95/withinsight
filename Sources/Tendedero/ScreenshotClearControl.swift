import AppKit
import ImageIO
import SwiftUI

@MainActor enum LineControlImages {
    static let picture = load("ClearScreenshots", crop: CGRect(x: 385, y: 334, width: 635, height: 515))
    static let pole = load("ShortScreenshotPole", crop: CGRect(x: 38, y: 195, width: 2045, height: 327))

    private static func load(_ name: String, crop: CGRect) -> NSImage? {
        var url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LineControls")
        #if DEBUG
        if url == nil {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Tendedero/Resources/LineControls/\(name).png")
        }
        #endif
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = original.cropping(to: crop.integral) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct ScreenshotClearControl: View {
    @ObservedObject var line: Line
    @StateObject private var motion = HangingSwing()
    static let clearID = UUID()
    static let undoID = UUID()

    var body: some View {
        VStack(spacing: -7.38) {
            Clothespin().scaleEffect(0.72).frame(width: 6.48, height: 18.72).zIndex(1)
            NativeScreenshotClearButton(line: line, pressed: { motion.nudge(2.2) })
                .frame(width: 40, height: 44)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: HitRectsKey.self, value: [Self.clearID: geo.frame(in: .global)])
                })
        }
        .frame(width: 40, height: LineControl.hangingHeight, alignment: .top)
        .rotationEffect(.degrees(motion.angle), anchor: .top)
        .offset(y: motion.arrived ? 0 : -46).opacity(motion.arrived ? 1 : 0)
        .onAppear { motion.arrive() }
        .onChange(of: line.gust) { _, _ in motion.breeze() }
    }
}

private struct NativeScreenshotClearButton: NSViewRepresentable {
    let line: Line
    let pressed: () -> Void
    func makeNSView(context: Context) -> ScreenshotClearButton { ScreenshotClearButton(frame: .zero) }
    func updateNSView(_ button: ScreenshotClearButton, context: Context) {
        button.isEnabled = line.screenshotClear == nil && line.clearableScreenshotCount > 0
        button.helpText = line.screenshotClear != nil ? "正在取下截图，请稍候"
            : line.clearableScreenshotCount == 0 ? "绳上没有截图\n闪念继续留在绳上"
            : "取下全部截图\n保留闪念与原文件"
        button.setAccessibilityIdentifier("line.clearScreenshots")
        button.setAccessibilityLabel("取下全部截图")
        button.setAccessibilityHelp(button.helpText)
        button.toolTip = nil
        button.handler = { pressed(); line.requestScreenshotClear() }
        button.updateArtwork()
    }
}

private final class ScreenshotClearButton: NSButton {
    var helpText = ""
    var handler: (() -> Void)?
    private var area: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    private var focused = false
    private let artwork = ClearArtworkHost(rootView: ScreenshotClearFace())

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; isBordered = false; focusRingType = .none
        target = self; action = #selector(performClear)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.setAccessibilityElement(false)
        addSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor), artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            artwork.topAnchor.constraint(equalTo: topAnchor), artwork.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder(); if accepted { focused = true; updateArtwork() }; return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder(); if accepted { focused = false; updateArtwork() }; return accepted
    }
    func updateArtwork() {
        artwork.rootView = ScreenshotClearFace(enabled: isEnabled, hovered: hovered, pressed: pressed, focused: focused)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateArtwork() }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        self.area = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true; updateArtwork(); NotesTooltipPresenter.shared.show(helpText, from: self)
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false; updateArtwork(); NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: self)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; updateArtwork(); super.mouseDown(with: event); pressed = false; updateArtwork()
    }
    @objc private func performClear() {
        guard isEnabled else { return }
        NotesTooltipPresenter.shared.dismiss(); handler?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; performClear(); return true
    }
}

private final class ClearArtworkHost: NSHostingView<ScreenshotClearFace> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ScreenshotClearFace: View {
    var enabled = true
    var hovered = false
    var pressed = false
    var focused = false
    var body: some View {
        Group {
            if let image = LineControlImages.picture { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "photo.badge.minus").resizable().scaledToFit().foregroundStyle(NotesTheme.muted) }
        }
        .frame(width: 32, height: 26)
        .opacity(enabled ? 1 : 0.38)
        .scaleEffect(HangingMotion.reduced ? 1 : pressed ? 0.95 : hovered && enabled ? 1.035 : 1)
        .overlay { if focused { RoundedRectangle(cornerRadius: 5).stroke(NotesTheme.accent, lineWidth: 1.5).padding(-3) } }
        .animation(HangingMotion.reduced ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(HangingMotion.reduced ? nil : .easeOut(duration: 0.1), value: pressed)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}

struct ScreenshotSweepOverlay: View {
    @ObservedObject var motion: ScreenshotSweepMotion
    var body: some View {
        GeometryReader { _ in
            if let pose = motion.pose, let image = LineControlImages.pole {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 58, height: 9.3)
                    .rotationEffect(.degrees(pose.angle), anchor: .trailing)
                    .position(x: pose.tip.x - 29, y: pose.tip.y)
                    .opacity(pose.opacity)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ScreenshotClearResult: View {
    @ObservedObject var line: Line
    var body: some View {
        HStack(spacing: 16) {
            Text("已取下 \(line.screenshotClearUndoCount) 张截图").foregroundStyle(NotesTheme.text)
            Button { line.undoScreenshotClear() } label: {
                Label("撤销", systemImage: "arrow.uturn.backward").foregroundStyle(NotesTheme.accent)
            }
            .buttonStyle(NotesPressStyle(hoverFill: false)).accessibilityIdentifier("line.undoScreenshotClear")
        }
        .font(.system(size: 12)).padding(.horizontal, 13).padding(.vertical, 8)
        .background(NotesTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(NotesTheme.border, lineWidth: 0.6))
        .shadow(color: NotesTheme.adaptive(0x303E50, 0x101824).opacity(0.12), radius: 5, y: 2)
        .background(GeometryReader { geo in
            Color.clear.preference(key: HitRectsKey.self, value: [ScreenshotClearControl.undoID: geo.frame(in: .global)])
        })
    }
}
