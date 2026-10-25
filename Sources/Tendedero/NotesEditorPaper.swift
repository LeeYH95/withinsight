import AppKit
import SwiftUI
import NotesCore

/// The editor and library preview share one paper surface. Hanging thumbnails
/// retain their existing NotesTheme.paper appearance.
struct NotesEditorPaper: View {
    let paper: NotePaper
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduced
    private static let image = Bundle.main.url(forResource: "NoteAtmosphere", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = Self.image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    LinearGradient(colors: [Color(notesHex: 0xFCFDFE), Color(notesHex: 0xE6F4FE)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                wash
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .animation(reduced || NotesMotion.reduced ? nil : .easeOut(duration: 0.18), value: paper)
    }
    private var wash: Color {
        if scheme == .dark {
            switch paper {
            case .plain: return Color(notesHex: 0x293039).opacity(0.96)
            case .blue: return Color(notesHex: 0x233247).opacity(0.96)
            case .lavender: return Color(notesHex: 0x312B47).opacity(0.96)
            case .rose: return Color(notesHex: 0x3D2B3C).opacity(0.96)
            case .warm: return Color(notesHex: 0x3A3429).opacity(0.96)
            case .gray: return Color(notesHex: 0x293B44).opacity(0.96)
            }
        }
        switch paper {
        case .plain: return .white.opacity(0.65)
        case .blue: return .clear
        case .lavender: return Color(notesHex: 0xE4DAF7).opacity(0.45)
        case .rose: return Color(notesHex: 0xF7DEE9).opacity(0.48)
        case .warm: return Color(notesHex: 0xFDF2D3).opacity(0.61)
        case .gray: return Color(notesHex: 0xD7E2E8).opacity(0.44)
        }
    }
}
