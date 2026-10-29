import AppKit
import SwiftUI
import NotesCore

@MainActor struct NoteThumbnail: View {
    let note: NoteDocument
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: note.blocks.contains(where: { $0.kind == .checklist }) ? "checklist" : "doc.text").foregroundStyle(NotesTheme.accent)
                Text(note.displayTitle).font(.system(size: 21, weight: .semibold)).lineLimit(1)
            }.padding(.horizontal, 20).padding(.top, 18)
            GeometryReader { geometry in
                let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
                Image(nsImage: NoteThumbnailText.image(for: note, size: geometry.size, appearance: appearance))
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// The paper supplies a real height constraint. Native text drawing wraps into
/// that space and truncates only its last visible line, including later blocks.
@MainActor enum NoteThumbnailText {
    static let font = NSFont.systemFont(ofSize: 24)

    static func content(for note: NoteDocument) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let blocks = note.blocks.filter { $0.kind == .paragraph || $0.kind == .checklist }
        for (index, block) in blocks.enumerated() {
            let text = NSMutableAttributedString(string: "")
            if block.kind == .checklist { text.append(marker(checked: block.isChecked)) }
            text.append(NSAttributedString(string: block.text.isEmpty && block.kind == .checklist ? "待办事项" : block.text))
            if index < blocks.count - 1 { text.append(NSAttributedString(string: "\n")) }
            let string = text.string as NSString
            var cursor = 0
            while cursor < text.length {
                let range = string.paragraphRange(for: NSRange(location: cursor, length: 0))
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                if block.kind == .checklist {
                    style.headIndent = 35
                    style.firstLineHeadIndent = cursor == 0 ? 0 : style.headIndent
                    style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                    style.paragraphSpacing = NSMaxRange(range) == text.length && index < blocks.count - 1 ? 12 : 0
                }
                text.addAttributes([.font: font, .foregroundColor: NSColor(NotesTheme.text), .paragraphStyle: style], range: range)
                cursor = NSMaxRange(range)
            }
            result.append(text)
        }
        if result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSAttributedString(string: note.attachments.first?.name ?? "写一点，留在眼前。",
                                      attributes: [.font: font, .foregroundColor: NSColor(NotesTheme.text)])
        }
        return result
    }

    private static func marker(checked: Bool) -> NSAttributedString {
        let name = checked ? "checkmark.square.fill" : "square"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)) else { return NSAttributedString(string: checked ? "☑\t" : "☐\t") }
        let ink = NSColor(checked ? NotesTheme.accent : NotesTheme.muted)
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            ink.setFill(); rect.fill(using: .sourceIn)
            return true
        }
        let token = NSTextAttachment()
        token.attachmentCell = NotesChecklistAttachmentCell(image: image, font: font)
        let result = NSMutableAttributedString(attachment: token)
        result.append(NSAttributedString(string: "\t"))
        return result
    }

    static func image(for note: NoteDocument, size: NSSize, appearance: NSAppearance) -> NSImage {
        guard size.width > 0, size.height > 0 else { return NSImage(size: .zero) }
        return NSImage(size: size, flipped: true) { rect in
            appearance.performAsCurrentDrawingAppearance {
                NSBezierPath(rect: rect).addClip()
                content(for: note).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            }
            return true
        }
    }
}
