import AppKit
import SwiftUI
import NotesCore

struct NoteThumbnail: View {
    let note: NoteDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: note.blocks.contains(where: { $0.kind == .checklist }) ? "checklist" : "doc.text").foregroundStyle(NotesTheme.accent)
                Text(note.displayTitle).font(.system(size: 21, weight: .semibold)).lineLimit(1)
            }.padding(.horizontal, 20).padding(.top, 18)
            VStack(alignment: .leading, spacing: 12) {
                let checks = note.blocks.filter { $0.kind == .checklist }
                if !checks.isEmpty {
                    ForEach(Array(checks.prefix(2))) { block in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: block.isChecked ? "checkmark.square.fill" : "square").foregroundStyle(block.isChecked ? NotesTheme.accent : NotesTheme.muted)
                            Text(block.text.isEmpty ? "待办事项" : block.text).lineLimit(2)
                        }
                    }
                } else {
                    Text(note.blocks.filter { $0.kind == .paragraph }.map(\.text).joined(separator: "\n").isEmpty ? (note.attachments.first?.name ?? "写一点，留在眼前。") : note.blocks.filter { $0.kind == .paragraph }.map(\.text).joined(separator: "\n"))
                        .lineLimit(5).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 24)).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(NotesTheme.paper(note.paper), in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 10).padding(.bottom, 10)
        }.foregroundStyle(NotesTheme.text).frame(width: 405, height: 280).background(NotesTheme.shell)
    }
    @MainActor static func image(for note: NoteDocument) -> NSImage {
        let renderer = ImageRenderer(content: NoteThumbnail(note: note).environment(\.colorScheme, (NotesTheme.appearance() ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 405, height: 280))
    }
}
