import AppKit
import SwiftUI
import NotesCore

/// A menu action model with a palette surface. Keeping it in the existing
/// presenter shares click-away, IME protection and source responder restoration.
@MainActor final class NotesPaperMenu: NSMenu {
    let papers = NotePaper.allCases
    private(set) var selectedPaper: NotePaper
    private let selectPaper: (NotePaper) -> Void
    init(selected: NotePaper, select: @escaping (NotePaper) -> Void) {
        selectedPaper = selected; selectPaper = select
        super.init(title: "纸张颜色")
        for paper in papers {
            let item = ClosureMenuItem(paper.chineseName) { [weak self] in self?.select(paper) }
            item.state = paper == selected ? .on : .off
            addItem(item)
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    static func options(selected: NotePaper, select: @escaping (NotePaper) -> Void) -> NSMenu {
        let menu = NSMenu()
        for paper in NotePaper.allCases {
            let item = ClosureMenuItem(paper.chineseName) { select(paper) }
            item.notesPaperSwatch = paper
            item.state = paper == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    private func select(_ paper: NotePaper) {
        selectedPaper = paper
        for (index, item) in items.enumerated() { item.state = papers[index] == paper ? .on : .off }
        selectPaper(paper)
    }
}

struct NotesPaperPalette: View {
    @ObservedObject var navigator: NotesMenuNavigator
    let menu: NotesPaperMenu
    let presenter: NotesMenuPresenter
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("纸张颜色").font(.system(size: 12)).foregroundStyle(NotesTheme.muted).padding(.horizontal, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(menu.papers.enumerated()), id: \.element) { index, paper in
                    let active = menu.selectedPaper == paper
                    Button { presenter.choose(index) } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 9).fill(NotesTheme.editorSwatch(paper))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? NotesTheme.accent : NotesTheme.border, lineWidth: active ? 1.5 : 1))
                                .frame(width: 36, height: 30)
                                .overlay { if active { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(NotesTheme.accent) } }
                            Text(paper.chineseName).font(.system(size: 12)).foregroundStyle(active ? NotesTheme.accent : NotesTheme.muted)
                        }.frame(maxWidth: .infinity).frame(height: 73)
                            .background(NotesTheme.accent.opacity(navigator.selected == index ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(NotesPressStyle(hoverFill: false))
                        .accessibilityLabel("选择" + paper.chineseName + "纸张")
                        .accessibilityValue(active ? "已选中" : "")
                        .accessibilityAddTraits(active ? [.isSelected] : [])
                        .onHover { if $0 { navigator.selected = index } }
                }
            }
        }.padding(14).foregroundStyle(NotesTheme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotesTheme.shell, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NotesTheme.border, lineWidth: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel("纸张颜色")
    }
}

struct NotesPaperButton: View {
    @ObservedObject var session: NotesEditorSession
    @State private var anchor: NSView?
    private var paper: NotePaper { session.note.effectiveEditorPaper }
    var body: some View {
        Button {
            guard let anchor else { return }
            NotesMenuPresenter.shared.toggle(NotesPaperMenu(selected: paper, select: session.setPaper), from: anchor, alignment: .trailing)
        } label: {
            Circle().fill(NotesTheme.editorSwatch(paper))
                .overlay(Circle().stroke(NotesTheme.muted, lineWidth: 0.8))
                .frame(width: 20, height: 20).frame(width: 38, height: 38).contentShape(Rectangle())
        }.buttonStyle(NotesPressStyle())
            .accessibilityLabel("纸张颜色，当前：" + paper.chineseName)
            .notesTooltip("纸张颜色：" + paper.chineseName + " · 点击更换")
            .background(NotesMenuAnchor { anchor = $0 })
    }
}
