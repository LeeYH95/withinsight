import AppKit
import SwiftUI
import NotesCore

struct NoteEditorView: View {
    @ObservedObject var session: NotesEditorSession
    let workspace: NotesWorkspace
    var expand: () -> Void
    @AppStorage("notesReadingScale") private var readingScale = 1.0
    @State private var bodyHeight: CGFloat = 140
    @State private var preview: NoteAttachment?
    @ObservedObject private var images = NotesImageCache.shared
    private var displayScale: CGFloat { CGFloat(min(2, max(0.75, readingScale))) }
    var body: some View {
        GeometryReader { frame in
          VStack(spacing: 0) {
            header(compact: frame.size.width <= 620, narrow: frame.size.width <= 450)
                .padding(.horizontal, frame.size.width <= 450 ? 20 : 28).frame(height: 64)
            VStack(spacing: 0) {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            NotesTitleTextField(session: session, scale: displayScale, compact: frame.size.width <= 620)
                                .fixedSize(horizontal: false, vertical: true)
                            NotesContinuousBody(session: session, scale: displayScale, onHeight: { bodyHeight = $0 }, onAttachment: { attachment in
                                if attachment.kind == .image {
                                    if let url = try? session.localURL(for: attachment), images.hasFailed(url) { images.retry(url) }
                                    else { preview = attachment }
                                } else { session.openAttachment(attachment) }
                            }).frame(height: max(bodyHeight, viewport.size.height - 90 * displayScale))
                            if let failure = session.attachmentFailure {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.circle")
                                    Text(failure).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                    if let label = session.attachmentRetryLabel { Button(label) { session.retryAttachments() } }
                                }.font(.system(size: 12)).foregroundStyle(NotesTheme.danger).padding(12)
                            }
                        }.padding(.horizontal, frame.size.width <= 450 ? 24 : 36)
                            .padding(.top, 14).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.never).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                toolbar.padding(.horizontal, frame.size.width <= 450 ? 20 : 28)
                    .padding(.top, 8).padding(.bottom, 12).frame(height: 64)
                if let failure = session.failure {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.recoveryProtected ? "保存未完成，已输入的内容暂存在本机" : "更改还没有保存，请保留此窗口并重试").fontWeight(.medium)
                            Text(failure).font(.system(size: 11)).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        Button("重试") { retry() }.buttonStyle(NotesPressStyle())
                        Button("复制内容") { session.copyCurrentText() }.buttonStyle(NotesPressStyle())
                    }.font(.system(size: 12)).foregroundStyle(NotesTheme.danger).padding(14).background(NotesTheme.danger.opacity(0.08))
                }
            }
          }
        }.background { NotesEditorPaper(paper: session.note.effectiveEditorPaper) }
            .foregroundStyle(NotesTheme.text).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .trailing) { NotesEditorResizeHandle(axis: .horizontal).frame(width: 7).padding(.vertical, 28) }
            .overlay(alignment: .bottom) { NotesEditorResizeHandle(axis: .vertical).frame(height: 7).padding(.horizontal, 28) }
            .overlay(alignment: .bottomTrailing) { NotesEditorResizeHandle(axis: .both).frame(width: 22,height: 22).padding(6) }
            .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: drop)
            .sheet(item: $preview) { attachment in imagePreview(attachment) }
            .onReceive(session.store.$saveState) { state in if case .failed(let reason) = state { session.failure = reason } }
    }
    private func header(compact: Bool, narrow: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            ZStack(alignment: .leading) {
                NotesWindowDragRegion()
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(NotesTheme.accent).font(.system(size: 21))
                    if !compact { Text("闪念").font(.system(size: 14, weight: .medium)) }
                    Text(saveStatus)
                        .font(.system(size: 11)).foregroundStyle(session.failure == nil ? NotesTheme.muted : NotesTheme.danger)
                        .accessibilityLabel(saveLabel)
                    Spacer()
                }.allowsHitTesting(false)
            }
            NotesMenuButton("显示大小", alignment: .trailing, menu: { NotesEditorFormatMenu.displayMenu(readingScale) { readingScale = $0 } }) {
                HStack(spacing: 6) {
                    if !compact { Text("显示").foregroundStyle(NotesTheme.muted) }
                    Text("\(Int((readingScale * 100).rounded()))%")
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.font(.system(size: 12)).padding(.horizontal, 5).frame(height: 34)
            }.fixedSize()
            NotesIconButton(symbol: session.note.pinned ? "pin.fill" : "pin", label: session.note.pinned ? "取消窗口置顶" : "窗口置顶", selected: session.note.pinned) { session.togglePin() }
            if !narrow { NotesIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "展开或恢复窗口", action: expand) }
            NotesMenuButton("更多操作", tooltip: "更多操作", alignment: .trailing, menu: editorMenu) {
                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 34, height: 34).foregroundStyle(NotesTheme.muted)
            }.fixedSize()
            NotesIconButton(symbol: "xmark", label: "关闭闪念 · Esc") { workspace.closeEditor(session.note.id) }
        }
    }
    private func editorMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("复制内容") { workspace.copy(session.note.id) }.notesSymbol("doc.on.doc"))
        menu.addItem(ClosureMenuItem("制作副本") { workspace.duplicate(session.note.id) }.notesSymbol("plus.square.on.square"))
        menu.addItem(ClosureMenuItem("导出 Markdown 及附件…") { workspace.export(session.note.id) }.notesSymbol("square.and.arrow.up"))
        menu.addItem(.separator())
        let paper = NSMenuItem(title: "纸张颜色",action: nil,keyEquivalent: "").notesSymbol("circle")
        paper.submenu = NotesPaperMenu.options(selected: session.note.effectiveEditorPaper, select: session.setPaper)
        menu.addItem(paper)
        menu.addItem(ClosureMenuItem("展开或恢复窗口",handler: expand).notesSymbol("arrow.up.left.and.arrow.down.right"))
        if session.note.onLine {
            menu.addItem(ClosureMenuItem("从绳上取下") { _ = workspace.takeOff(session.note.id) }.notesSymbol("arrow.down.to.line"))
        } else {
            menu.addItem(ClosureMenuItem("挂上去") { workspace.hang(session.note.id, hide: true) }.notesSymbol("arrow.up.to.line"))
        }
        let trash = ClosureMenuItem("移到最近删除…") { workspace.requestTrash(session.note.id) }.notesSymbol("trash")
        trash.notesDestructive = true
        menu.addItem(trash)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("全部闪念") { workspace.showLibrary() }.notesSymbol("square.grid.2x2"))
        menu.addItem(ClosureMenuItem("偏好设置…") { workspace.showSettings() }.notesSymbol("gearshape"))
        return menu
    }
    private var toolbar: some View {
        HStack(spacing: 6) {
            NotesMenuButton("文字格式 · Aa", tooltip: "文字格式 · Aa", menu: { NotesEditorFormatMenu.make(session) }) {
                Image(nsImage: NotesEditorIcon.text.image).resizable().frame(width: 24,height: 24)
                    .frame(width: 38,height: 38).foregroundStyle(NotesTheme.muted)
            }.fixedSize()
            NotesEditorTool(icon: .checklist,label: "待办清单") { session.addBlock(.checklist) }
            NotesEditorTool(icon: .image,label: "添加图片") { session.chooseAttachment(imagesOnly: true) }
            NotesEditorTool(icon: .attachment,label: "添加附件") { session.chooseAttachment(imagesOnly: false) }
            Spacer(minLength: 12)
            NotesEditorTool(icon: .undo,label: "撤销 · ⌘Z") { session.undo() }
                .disabled(!session.undoManager.canUndo).opacity(session.undoManager.canUndo ? 1 : 0.45)
            NotesEditorTool(icon: .redo,label: "重做 · ⇧⌘Z") { session.redo() }
                .disabled(!session.undoManager.canRedo).opacity(session.undoManager.canRedo ? 1 : 0.45)
            NotesPaperButton(session: session)
        }.accessibilityElement(children: .contain).accessibilityLabel("闪念底部工具区")
    }
    private var saveStatus: String {
        if session.failure != nil { return "保存失败" }
        return session.dirty ? "正在保存…" : "已保存"
    }
    private var saveLabel: String {
        if session.failure != nil {
            return session.recoveryProtected ? "保存失败，已输入的内容暂存在本机，请在下方重试" : "保存失败 · 请保留此窗口并在下方重试"
        }
        if session.dirty { return "正在保存…" }
        return "已自动保存到本机"
    }
    private func retry() { do { try session.commit() } catch { session.failure = error.localizedDescription } }
    private func attachmentImage(_ attachment: NoteAttachment) -> NSImage? {
        do { return images.image(at: try session.localURL(for: attachment)) } catch { return nil }
    }
    private func imagePreview(_ attachment: NoteAttachment) -> some View {
        VStack(spacing: 16) {
            HStack { Text(attachment.name).font(.headline); Spacer(); Button("完成") { preview = nil }.keyboardShortcut(.cancelAction) }
            if let image = attachmentImage(attachment) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Label("图片无法读取，可尝试打开或导出附件", systemImage: "exclamationmark.circle") }
            HStack { Button("打开原尺寸副本") { session.openAttachment(attachment) }; Button("导出…") { session.exportAttachment(attachment) }; Spacer() }
        }.padding(24).frame(minWidth: 500, idealWidth: 760, minHeight: 350, idealHeight: 560).background(NotesTheme.shell)
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                accepted = true
                _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                    DispatchQueue.main.async {
                        if let error { session.reportAttachmentFailure(error.localizedDescription) }
                        else if let url = object as? URL { session.importURLs([url]) }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, error in DispatchQueue.main.async { if let image = object as? NSImage { session.pasteImage(image) } else if let error { session.reportAttachmentFailure(error.localizedDescription) } } }
            }
        }
        return accepted
    }
}
