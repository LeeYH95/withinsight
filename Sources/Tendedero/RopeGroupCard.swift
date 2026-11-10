import AppKit
import SwiftUI

struct RopeGroupCard: View {
    let group: RopeGroup
    let revealed: Bool
    let onToggle: () -> Void
    @State private var lifted = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Frame.radius) }
    private var showCue: Bool { revealed && !HangingMotion.reduced }

    private var coverSize: CGSize {
        let maxWidth = Layout.cardWidth - 24
        if group.kind == .notes {
            return PeggedView.photoSize(for: group.cover.thumb.size, maxWidth: maxWidth)
        }
        return CGSize(width: maxWidth, height: Layout.photoMaxHeight)
    }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin().zIndex(1)
            Image(nsImage: group.cover.thumb)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: group.kind == .images ? .fill : .fit)
                .frame(width: coverSize.width, height: coverSize.height)
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset))
                .padding(Frame.inset)
                .background(NotesTheme.shell, in: shape)
                .overlay(alignment: .bottom) {
                    RopeGroupBadge(group: group).offset(y: lifted ? -2 : 0).padding(.bottom, 8)
                }
                .shadow(color: .black.opacity(0.15), radius: 7, y: 4)
                .background {
                    // The backing cards follow the visible cover size.
                    ZStack {
                        paperLayer(NotesTheme.paper(.blue), x: 6, y: 7, angle: 4)
                        paperLayer(NotesTheme.surface, x: -5, y: 4, angle: -3)
                    }
                }
            .accessibilityHidden(true)
            .overlay {
                RopeGroupButton(group: group, onToggle: onToggle)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: HitRectsKey.self, value: [group.id: proxy.frame(in: .global)])
                }
            }
        }
        .task(id: showCue) {
            lifted = false
            guard showCue else { return }
            do {
                try await Task.sleep(for: .milliseconds(460))
                withAnimation(.easeInOut(duration: 0.48)) { lifted = true }
                try await Task.sleep(for: .milliseconds(520))
                withAnimation(.easeInOut(duration: 0.48)) { lifted = false }
            } catch { return }
        }
    }

    private func paperLayer(_ color: Color, x: CGFloat, y: CGFloat, angle: Double) -> some View {
        shape.fill(color)
            .overlay { shape.strokeBorder(NotesTheme.shell.opacity(0.85), lineWidth: 0.75) }
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
    }

}

struct RopeGroupBadge: View {
    let group: RopeGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.kind.symbol).foregroundStyle(NotesTheme.accent)
            Text(group.kind.label).fontWeight(.semibold)
            Text(group.members.count, format: .number).monospacedDigit().foregroundStyle(NotesTheme.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .scaleEffect(x: group.expanded ? -1 : 1, y: 1)
        }
        .font(.system(size: 11))
        .foregroundStyle(NotesTheme.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassFrame(capsule: true)
        .fixedSize()
    }
}

/// The floating rope never takes key focus, including when another app is active.
struct RopeGroupButton: NSViewRepresentable {
    let group: RopeGroup
    let onToggle: () -> Void

    func makeNSView(context: Context) -> HitButton { HitButton(frame: .zero) }

    func updateNSView(_ button: HitButton, context: Context) {
        button.onToggle = onToggle
        let action = group.expanded ? "收起" : "展开"
        button.setAccessibilityLabel("\(action)\(group.kind.label)，\(group.members.count) \(group.kind.unit)")
        button.setAccessibilityIdentifier("rope.group." + group.kind.rawValue)
    }

    final class HitButton: NSButton {
        var onToggle: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            isTransparent = true
            target = self
            action = #selector(activateGroup)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func activateGroup() { onToggle?() }
    }
}
