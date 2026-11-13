import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .large }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let controlsWidth: CGFloat = 149
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Center the visible cards. When the rope overflows, keep the spacing
    /// and let scrolling bring older cards in from the left.
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        if count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let contentWidth = max(300, width - Layout.controlsWidth)
            let presentation = line.ropePresentation
            let expandedGroup = presentation.groups.first(where: \.expanded)
            let liveIDs = Set(line.items.lazy.filter { !$0.falling }.map(\.id))
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ZStack(alignment: .topLeading) {
                    ForEach(line.items) { item in
                        let shown = !presentation.hides(item.id) && !item.falling
                        let x = line.hangingX(for: item.id, width: width, presentation: presentation)
                        let ropeY = Layout.ropeY(x: x, width: width)
                        let group = expandedGroup?.cover.id == item.id ? expandedGroup : nil
                        PeggedView(item: item, line: line, participates: shown, expandedGroup: shown ? group : nil)
                            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                            .opacity(shown ? edgeOpacity(x: x, width: contentWidth) : 0)
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                    }

                    ForEach(presentation.groups.filter { group in
                        !group.expanded && group.members.contains { liveIDs.contains($0.id) }
                    }, id: \.id) { group in
                        let x = line.hangingX(for: group.id, width: width, presentation: presentation)
                        let ropeY = Layout.ropeY(x: x, width: width)
                        RopeGroupCard(group: group, revealed: line.revealed) { line.toggleRopeGroup(group.kind) }
                            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                            .opacity(edgeOpacity(x: x, width: contentWidth))
                            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                            .zIndex(1)
                    }
                }
                .frame(width: contentWidth, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .animation(groupMotion, value: line.expandedRopeGroup)
                .animation(groupMotion, value: presentation.groups.map(\.id))
                ScreenshotSweepOverlay(motion: line.screenshotSweep)
                ScreenshotClearControl(line: line)
                    .position(x: width - 128, y: Layout.ropeY(x: width - 128, width: width) - LineControl.pinAbove + LineControl.hangingHeight / 2)
                LineControl(line: line, isNew: false)
                    .position(x: width - 79, y: Layout.ropeY(x: width - 79, width: width) - LineControl.pinAbove + LineControl.hangingHeight / 2)
                LineControl(line: line, isNew: true)
                    .position(x: width - 34, y: Layout.ropeY(x: width - 34, width: width) - LineControl.pinAbove + LineControl.hangingHeight / 2)
                if line.screenshotClear == nil, line.screenshotClearUndoCount > 0 {
                    ScreenshotClearResult(line: line)
                        .position(x: width / 2, y: geo.size.height - 23)
                        .transition(.opacity)
                } else if line.screenshotClear == nil, !line.copiedImagesUndoIDs.isEmpty {
                    CopiedImagesResult(line: line)
                        .position(x: width / 2, y: geo.size.height - 23)
                        .transition(.opacity)
                }
            }
            .animation(HangingMotion.reduced ? nil : .spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(HangingMotion.reduced ? nil : .easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(HangingMotion.reduced ? nil : .easeOut(duration: 0.15), value: line.screenshotClearUndoCount)
            .animation(HangingMotion.reduced ? nil : .easeOut(duration: 0.15), value: line.copiedImagesUndoIDs)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(HangingMotion.reduced ? nil : (line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22)), value: line.revealed)
            .onPreferenceChange(HitRectsKey.self) { rects in
                let viewport = CGRect(x: 0, y: 0, width: contentWidth, height: geo.size.height)
                let cardIDs = Set(line.items.map(\.id) + RopeGroupKind.allCases.map(\.id))
                line.hitRects = rects.reduce(into: [:]) { result, pair in
                    let rect = cardIDs.contains(pair.key) ? pair.value.intersection(viewport) : pair.value
                    if !rect.isNull && !rect.isEmpty { result[pair.key] = rect }
                }
            }
        }
    }

    private var groupMotion: Animation? {
        HangingMotion.reduced ? nil : .timingCurve(0.31, 0.22, 0.24, 1, duration: 0.44)
    }

    private func edgeOpacity(x: CGFloat, width: CGFloat) -> Double {
        min(1, max(0, min(x, width - x) / 90))
    }
}

private struct Hint: View {
    var body: some View {
        Text("记一条闪念，或截下一点灵感")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
