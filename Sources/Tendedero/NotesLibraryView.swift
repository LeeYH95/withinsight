import AppKit
import SwiftUI
import NotesCore

struct NotesLibraryView: View {
    let workspace: NotesWorkspace
    @ObservedObject var store: NotesStore
    @State private var scope = NoteScope.all
    @State private var query = ""
    @State private var sortTitle = false
    @State private var trashStatus: String?
    @FocusState private var searching: Bool
    @FocusState private var focusedScope: NoteScope?
    @Namespace private var tabSelection

    private struct Membership: Equatable {
        let id: UUID
        let deleted: Bool
        let onLine: Bool
    }
    private var membership: [Membership] {
        store.documents.map { Membership(id: $0.id, deleted: $0.deletedAt != nil, onLine: $0.onLine) }
    }
    private var notes: [NoteDocument] {
        let result = store.search(query, scope: scope)
        return sortTitle ? result.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending } : result
    }
    private var deletedCount: Int { store.documents.filter { $0.deletedAt != nil }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.recoveredDraftCount > 0 || !store.recoveryWarnings.isEmpty {
                recoveryBanner.padding(.horizontal, 34).padding(.bottom, 16)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) {
                    tabs.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    searchField.frame(width: 238)
                }
                VStack(alignment: .leading, spacing: 16) {
                    tabs
                    searchField.frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 34).padding(.bottom, 16)
                .background { NotesWindowDragRegion() }
            Rectangle().fill(NotesTheme.border).frame(height: 1)
            HStack {
                Text(scope == .trash && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "找到 \(notes.count) 条 · 最近删除共 \(deletedCount) 条" : "\(notes.count) 条闪念")
                    .font(.system(size: 12)).foregroundStyle(NotesTheme.muted)
                Spacer()
                if scope == .trash {
                    Button("清空最近删除") {
                        workspace.requestEmptyTrash(query: query) { count in
                            query = ""; searching = false; focusedScope = .trash
                            trashStatus = count > 0 ? "已永久删除 \(count) 条闪念" : "没有需要清空的闪念"
                        }
                    }.font(.system(size: 12)).foregroundStyle(deletedCount == 0 ? NotesTheme.muted : NotesTheme.danger)
                        .buttonStyle(NotesPressStyle()).disabled(deletedCount == 0)
                        .padding(.horizontal, 10).frame(height: 30)
                }
                NotesMenuButton("排序", alignment: .trailing, menu: sortMenu) {
                    HStack(spacing: 7) {
                        Text(sortTitle ? "标题" : "最近编辑")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 12)).foregroundStyle(NotesTheme.muted).padding(.horizontal, 10).frame(height: 30)
                }.fixedSize()
            }.padding(.horizontal, 34).padding(.vertical, 10)
            if scope == .trash, let trashStatus {
                Text(trashStatus).font(.system(size: 12)).foregroundStyle(NotesTheme.muted)
                    .padding(.horizontal, 34).padding(.bottom, 10)
            }
            Group {
                if notes.isEmpty { empty.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity) }
                else {
                    NotesEditorScroll {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 18)], alignment: .leading, spacing: 18) {
                            ForEach(notes) { note in
                                NotesLibraryCard(note: note, workspace: workspace, store: store)
                                    .transition(.opacity.combined(with: .offset(y: NotesMotion.reduced ? 0 : 4)))
                            }
                        }.padding(.horizontal, 34).padding(.top, 3).padding(.bottom, 30)
                    }.transition(.opacity)
                }
            }.animation(NotesMotion.standard, value: membership)
        }.foregroundStyle(NotesTheme.text).background(NotesTheme.shell).clipShape(RoundedRectangle(cornerRadius: 30))
            .overlay(alignment: .trailing) { NotesEditorResizeHandle(axis: .horizontal).frame(width: 7).padding(.vertical, 30) }
            .overlay(alignment: .bottom) { NotesEditorResizeHandle(axis: .vertical).frame(height: 7).padding(.horizontal, 30) }
            .overlay(alignment: .bottomTrailing) { NotesEditorResizeHandle(axis: .both).frame(width: 22, height: 22).padding(6) }
            .onReceive(NotificationCenter.default.publisher(for: .notesFocusSearch)) { _ in searching = true }
            .background(Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true))
            .onChange(of: scope) { _, _ in trashStatus = nil }
            .task(id: trashStatus) {
                guard trashStatus != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { trashStatus = nil }
            }
    }
    private var recoveryBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.recoveryWarnings.isEmpty ? "arrow.counterclockwise.circle" : "exclamationmark.circle")
                .foregroundStyle(store.recoveryWarnings.isEmpty ? NotesTheme.accent : NotesTheme.danger)
            VStack(alignment: .leading, spacing: 4) {
                if store.recoveredDraftCount > 0 {
                    Text("异常退出后，已找回 \(store.recoveredDraftCount) 份未保存内容").fontWeight(.medium)
                    Text("请在闪念库中检查；有冲突的内容已保留为独立副本。")
                        .font(.system(size: 11)).foregroundStyle(NotesTheme.muted)
                }
                if !store.recoveryWarnings.isEmpty {
                    Text(store.recoveryWarnings.joined(separator: "\n"))
                        .font(.system(size: 11)).foregroundStyle(NotesTheme.danger).lineLimit(3)
                        .textSelection(.enabled).notesTooltip(store.recoveryWarnings.joined(separator: "\n"))
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Button("打开恢复文件夹") { workspace.showRecoveryFolder() }
                if store.recoveredDraftCount > 0 {
                    Button("知道了") { store.acknowledgeRecovery() }
                }
            }.fixedSize().foregroundStyle(NotesTheme.accent)
        }.font(.system(size: 12)).buttonStyle(NotesPressStyle()).padding(12)
            .background(NotesTheme.paper(.blue), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel("异常退出恢复提示")
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("全部闪念").font(.system(size: 20, weight: .semibold))
            }.allowsHitTesting(false)
            Spacer(minLength: 20)
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 0) {
                    Button { workspace.newNote() } label: {
                        Label("新建闪念", systemImage: "plus").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 15).frame(height: 40).contentShape(Rectangle())
                    }.buttonStyle(NotesPressStyle()).accessibilityLabel("新建闪念")
                    Rectangle().fill(NotesTheme.onAccent.opacity(0.26)).frame(width: 1, height: 18)
                    NotesMenuButton("选择新建模板", tooltip: "选择新建模板", alignment: .trailing, menu: newNoteMenu) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 34, height: 40)
                    }
                }.foregroundStyle(NotesTheme.onAccent).background(NotesTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).fixedSize()
                NotesIconButton(symbol: "gearshape", label: "闪念偏好设置", size: 40) { workspace.showSettings() }
                NotesCloseWindowButton()
            }.fixedSize()
        }.padding(.horizontal, 34).padding(.top, 20).padding(.bottom, 16)
            .background { NotesWindowDragRegion() }
    }
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(NoteScope.allCases, id: \.self) { item in
                Button { withAnimation(NotesMotion.selection) { scope = item } } label: {
                    HStack(spacing: 5) {
                        Text(title(item))
                        Text("\(store.search("", scope: item).count)").font(.system(size: 11)).monospacedDigit()
                    }.font(.system(size: 13, weight: scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? NotesTheme.accent : NotesTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .bottom) {
                            if scope == item {
                                Capsule().fill(NotesTheme.accent).frame(height: 2)
                                    .matchedGeometryEffect(id: "scopeUnderline", in: tabSelection)
                                    .padding(.horizontal, 12)
                            }
                        }
                }.buttonStyle(NotesPressStyle()).focused($focusedScope, equals: item)
                    .accessibilityAddTraits(scope == item ? [.isSelected] : [])
            }
        }
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").frame(width: 16).foregroundStyle(NotesTheme.muted)
            TextField("搜索标题或正文", text: $query).textFieldStyle(.plain).focused($searching).accessibilityLabel("搜索标题或正文").notesTextContextMenu()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(NotesTheme.muted).frame(width: 24, height: 26)
                }.buttonStyle(NotesPressStyle()).accessibilityLabel("清除搜索").notesTooltip("清除搜索")
            }
        }.font(.system(size: 13)).padding(.leading, 12).padding(.trailing, query.isEmpty ? 12 : 6).frame(height: 38)
            .background(NotesTheme.shell, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(searching ? NotesTheme.accent.opacity(0.55) : NotesTheme.border, lineWidth: 1))
            .animation(NotesMotion.quick, value: searching)
    }
    private func newNoteMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("文字闪念") { workspace.newNote() }.notesSymbol("doc.text"))
        menu.addItem(ClosureMenuItem("待办清单") { workspace.newNote(template: .checklist) }.notesSymbol("checklist"))
        menu.addItem(ClosureMenuItem("图文闪念") { workspace.newNote(template: .image) }.notesSymbol("photo"))
        return menu
    }
    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        let recent = ClosureMenuItem("最近编辑") { withAnimation(NotesMotion.selection) { sortTitle = false } }
        recent.state = sortTitle ? .off : .on
        menu.addItem(recent)
        let title = ClosureMenuItem("标题") { withAnimation(NotesMotion.selection) { sortTitle = true } }
        title.state = sortTitle ? .on : .off
        menu.addItem(title)
        return menu
    }
    private func title(_ scope: NoteScope) -> String { switch scope { case .all: return "全部闪念"; case .onLine: return "挂绳上"; case .offLine: return "已取下"; case .trash: return "最近删除" } }
    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: query.isEmpty ? (scope == .trash ? "trash" : "doc.text") : "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(NotesTheme.accent)
            Text(query.isEmpty ? (scope == .trash ? "最近删除里没有闪念" : "留下一点想法") : "没有找到相关闪念").font(.system(size: 21, weight: .semibold))
            Text(query.isEmpty ? (scope == .trash ? "移到这里的闪念可以恢复。" : "写一点 → 挂上去 → 随时找回") : "试试其他关键词，或开始一条新闪念。").font(.system(size: 14)).foregroundStyle(NotesTheme.muted)
            HStack(spacing: 16) {
                if !query.isEmpty { Button("清除搜索") { query = "" }.buttonStyle(NotesPressStyle()) }
                if scope != .trash {
                    Button { workspace.newNote() } label: {
                        Text("新建闪念").font(.system(size: 13, weight: .medium)).padding(.horizontal, 18).frame(height: 36)
                            .foregroundStyle(NotesTheme.onAccent).background(NotesTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(NotesPressStyle())
                }
            }
        }.padding(40)
    }
}

private struct NotesLibraryCard: View {
    let note: NoteDocument
    let workspace: NotesWorkspace
    let store: NotesStore
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @AppStorage("notesReduceMotion") private var appReduced = false
    private var reduced: Bool { systemReduced || appReduced }
    private var hasImage: Bool { note.attachments.contains { $0.kind == .image } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if note.deletedAt == nil { workspace.open(note.id) }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: note.blocks.contains(where: { $0.kind == .checklist }) ? "checklist" : "doc.text")
                        Text(note.deletedAt != nil ? "最近删除" : (note.onLine ? "挂绳上" : (note.draft ? "草稿" : "已取下")))
                        Spacer()
                        if note.pinned { Image(systemName: "pin.fill") }
                    }.font(.system(size: 11)).foregroundStyle(NotesTheme.muted)
                    Text(note.displayTitle).font(.system(size: 18, weight: .semibold)).lineLimit(hasImage ? 1 : 2)
                    if let attachment = note.attachments.first(where: { $0.kind == .image }) {
                        NotesLibraryThumbnail(url: try? store.url(for: attachment))
                            .frame(height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(note.blocks.filter { $0.kind == .paragraph || $0.kind == .checklist }.prefix(hasImage ? 1 : 2))) { block in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                if block.kind == .checklist { Image(systemName: block.isChecked ? "checkmark.square.fill" : "square").foregroundStyle(block.isChecked ? NotesTheme.accent : NotesTheme.muted) }
                                Text(block.text).lineLimit(1)
                            }
                        }
                    }.font(.system(size: 13)).foregroundStyle(NotesTheme.muted)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, minHeight: 176, maxHeight: 176, alignment: .topLeading).clipped().contentShape(Rectangle())
            }.buttonStyle(NotesPressStyle(hoverFill: false))
                .accessibilityLabel("\(note.displayTitle)，\(note.onLine ? "挂绳上" : (note.draft ? "草稿" : "已取下"))")
            HStack(spacing: 10) {
                Text(note.updatedAt, style: .date).font(.system(size: 11)).foregroundStyle(NotesTheme.muted)
                Spacer(minLength: 2)
                if note.deletedAt != nil {
                    Button("恢复") { workspace.restore(note.id) }.foregroundStyle(NotesTheme.accent)
                    Button { workspace.permanentlyDelete(note.id) } label: { Image(systemName: "trash.slash").frame(width: 26, height: 30) }.foregroundStyle(NotesTheme.danger).notesTooltip("永久删除").accessibilityLabel("永久删除：" + note.displayTitle)
                } else {
                    Button(note.onLine ? "取下" : "挂上") {
                        if note.onLine { _ = workspace.takeOff(note.id) } else { workspace.hang(note.id) }
                    }.foregroundStyle(NotesTheme.accent)
                    NotesMenuButton("闪念更多操作", tooltip: "闪念更多操作", alignment: .trailing, menu: moreMenu) {
                        Image(systemName: "ellipsis").frame(width: 26, height: 30).foregroundStyle(NotesTheme.muted)
                    }.fixedSize()
                    Button { workspace.requestTrash(note.id) } label: { Image(systemName: "trash").frame(width: 26, height: 30) }.foregroundStyle(NotesTheme.muted).notesTooltip("移到最近删除").accessibilityLabel("移到最近删除：" + note.displayTitle)
                }
            }.font(.system(size: 12)).buttonStyle(NotesPressStyle())
                .padding(.horizontal, 15).padding(.bottom, 4).frame(height: 48)
        }.background { NotesEditorPaper(paper: note.effectiveEditorPaper) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(hovered ? NotesTheme.accent.opacity(0.28) : NotesTheme.border, lineWidth: 1))
            .shadow(color: NotesTheme.accent.opacity(hovered ? 0.08 : 0), radius: hovered ? 10 : 4, x: 0, y: hovered ? 5 : 2)
            .offset(y: hovered && !reduced ? -2 : 0)
            .onHover { hovered = $0 }
            .animation(reduced ? nil : .easeOut(duration: 0.14), value: hovered)
    }
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("打开") { workspace.open(note.id) }.notesSymbol("arrow.up.forward.app"))
        menu.addItem(ClosureMenuItem("复制内容") { workspace.copy(note.id) }.notesSymbol("doc.on.doc"))
        menu.addItem(ClosureMenuItem("制作副本") { workspace.duplicate(note.id) }.notesSymbol("plus.square.on.square"))
        menu.addItem(ClosureMenuItem("导出 Markdown 及附件…") { workspace.export(note.id) }.notesSymbol("square.and.arrow.up"))
        return menu
    }
}

private struct NotesLibraryThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 10).fill(NotesTheme.muted.opacity(0.05)).overlay(Image(systemName: "photo").foregroundStyle(NotesTheme.muted)) }
        }.task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await NotesImageCache.thumbnails.loadedImage(at: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

extension Notification.Name { static let notesFocusSearch = Notification.Name("LineNotes.focusSearch") }

struct NotesCloseWindowButton: View {
    var size: CGFloat = 40
    @State private var target = NotesCloseWindowReference()
    var body: some View {
        Button { target.window?.performClose(nil) } label: {
            Image(systemName: "xmark").font(.system(size: 16)).foregroundStyle(NotesTheme.muted).frame(width: size, height: size)
        }.buttonStyle(NotesPressStyle()).accessibilityLabel("关闭窗口").notesTooltip("关闭窗口")
            .background(NotesCloseWindowAnchor { target.window = $0 })
    }
}

private final class NotesCloseWindowReference {
    weak var window: NSWindow?
}

private struct NotesCloseWindowAnchor: NSViewRepresentable {
    let receive: (NSWindow?) -> Void
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.receive = receive
        return view
    }
    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.receive = receive
        receive(nsView.window)
    }
    final class AnchorView: NSView {
        var receive: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            receive?(window)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
