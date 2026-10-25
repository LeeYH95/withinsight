import AppKit
import SwiftUI
import NotesCore

/// System settings are owned by the running app: changing their defaults alone
/// would leave watchers, capacity and the registered global shortcut out of sync.
struct NotesSettingsSnapshot: Equatable {
    var watchesScreenshots = false
    var copiesImages = false
    var loginEnabled = false
    var loginNeedsApproval = false
    var screenshotFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    var extraFolders: [URL] = []
    var capacity: Int?
    var shortcut = "未设置"
}

@MainActor struct NotesSettingsActions {
    var systemAvailable = false
    var read: () -> NotesSettingsSnapshot = { NotesSettingsSnapshot() }
    var watchScreenshots: (Bool) -> Void = { _ in }
    var copyImages: (Bool) -> Void = { _ in }
    var toggleLogin: () -> Void = {}
    var chooseFolder: () -> Void = {}
    var removeFolder: (URL) -> Void = { _ in }
    var setCapacity: (Int?) -> Void = { _ in }
    var changeShortcut: () -> Void = {}
}

struct NotesSettingsView: View {
    var actions = NotesSettingsActions()
    @AppStorage("notesTheme") private var theme = "system"
    @AppStorage("notesPaper") private var paper = "blue"
    @AppStorage("notesReadingScale") private var readingScale = 1.0
    @AppStorage("notesAutoHang") private var autoHang = false
    @AppStorage("notesReduceMotion") private var reduceMotion = false
    @AppStorage("menuBarRevealOff") private var hoverDisabled = false
    @AppStorage("quietHang") private var quietHang = false
    @State private var section = Section.notes
    @State private var system = NotesSettingsSnapshot()

    private enum Section: String, CaseIterable, Identifiable {
        case notes = "闪念", line = "挂绳", appearance = "外观", screenshots = "截图", shortcuts = "快捷键"
        var id: Self { self }
        var icon: NotesEditorIcon {
            switch self {
            case .notes: return .document
            case .line: return .sliders
            case .appearance: return .sun
            case .screenshots: return .image
            case .shortcuts: return .keyboard
            }
        }
    }
    private let scales = [0.75, 1.0, 1.25, 1.5]
    private var scaleTitle: String { "\(Int((readingScale * 100).rounded()))%" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NotesAppIcon.image() {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                Text("偏好设置").font(.system(size: 20, weight: .semibold))
                Spacer()
                NotesCloseWindowButton()
            }.padding(.horizontal, 24).frame(height: 64)
                .background { NotesWindowDragRegion() }
            divider
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(NotesTheme.border).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.rawValue).font(.system(size: 17, weight: .semibold)).padding(.bottom, 18)
                        content
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 24)
                }.scrollIndicators(.never).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(NotesTheme.text).background(NotesTheme.shell)
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Section.allCases) { item in
                Button {
                    NotesMenuPresenter.shared.dismiss()
                    NotesTooltipPresenter.shared.dismiss()
                    section = item
                    refresh()
                } label: {
                    HStack(spacing: 11) {
                        Image(nsImage: item.icon.image).resizable().frame(width: 18, height: 18).frame(width: 20)
                        Text(item.rawValue).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 13).frame(height: 40)
                        .foregroundStyle(section == item ? NotesTheme.accent : NotesTheme.muted)
                        .background(section == item ? NotesTheme.paper(.blue) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(NotesPressStyle(hoverFill: false))
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
            Spacer()
            Text("拾片 · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "本地版"))
                .font(.system(size: 11)).foregroundStyle(NotesTheme.muted).padding(12)
        }.padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 12).frame(width: 148)
            .accessibilityElement(children: .contain).accessibilityLabel("设置分类")
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .notes:
            row("默认纸张", detail: "用于新建闪念，已有闪念保持原样。") {
                menuValue((NotePaper(rawValue: paper) ?? .blue).chineseName, name: "默认纸张", menu: paperMenu) {
                    Circle().fill(NotesTheme.editorSwatch(NotePaper(rawValue: paper) ?? .blue))
                        .overlay(Circle().stroke(NotesTheme.border, lineWidth: 1)).frame(width: 17, height: 17)
                }
            }
            toggle("新建闪念自动挂上", detail: "关闭此项时，新建内容先留在全部闪念。", value: $autoHang)
            quietNote("内容自动保存在本机。收起窗口，想法也还在。")
        case .line:
            row("唤出方式") {
                menuValue(hoverDisabled ? "仅手动唤出" : "指针靠近顶部", name: "唤出方式", menu: activationMenu)
            }
            toggle("新内容出现时展开", detail: "新内容挂上时，短暂展开挂绳。", value: Binding(get: { !quietHang }, set: { quietHang = !$0 }))
            toggle("登录时启动", detail: system.loginNeedsApproval ? "请在系统设置的登录项中允许拾片。" : nil,
                   value: Binding(get: { system.loginEnabled || system.loginNeedsApproval }, set: { _ in actions.toggleLogin(); refresh() }))
                .disabled(!actions.systemAvailable)
            if !actions.systemAvailable { systemNote }
        case .appearance:
            appearanceControl.padding(.bottom, 8)
            row("显示大小", detail: "只放大阅读画面，不改文字字号。与闪念右上角同步。") {
                menuValue(scaleTitle, name: "显示大小", menu: scaleMenu)
            }
            toggle("减少动态效果", detail: "系统开启减少动态时也会生效。", value: $reduceMotion)
            quietNote("设置即时生效。文字字号在闪念底部 Aa 菜单中调整。")
        case .screenshots:
            toggle("启用截图监听", detail: "将截图文件夹中新保存的图片挂到绳上。",
                   value: Binding(get: { system.watchesScreenshots }, set: { actions.watchScreenshots($0); refresh() }))
                .disabled(!actions.systemAvailable)
            row("截图文件夹", detail: system.screenshotFolder.path) {
                textButton("打开") { NSWorkspace.shared.open(system.screenshotFolder) }
            }
            ForEach(system.extraFolders, id: \.path) { folder in
                row("额外监听文件夹", detail: folder.path) {
                    NotesIconButton(symbol: "minus.circle", label: "停止监听此文件夹") { actions.removeFolder(folder); refresh() }
                        .disabled(!actions.systemAvailable)
                }
            }
            row("同时监听其他文件夹", detail: "最多添加 3 个，不移动原始文件。") {
                textButton("添加文件夹…") { actions.chooseFolder(); refresh() }
                    .disabled(!actions.systemAvailable || system.extraFolders.count >= 3)
            }
            toggle("复制图片时挂到绳上", detail: "开启后读取剪贴板中的图片，文字不会被收集。",
                   value: Binding(get: { system.copiesImages }, set: { actions.copyImages($0); refresh() }))
                .disabled(!actions.systemAvailable)
            row("挂绳保留数量", detail: "超出屏幕宽度时，可横向滚动查看。") {
                menuValue(system.capacity.map { "\($0) 项" } ?? "适应屏幕", name: "挂绳保留数量", menu: capacityMenu)
            }
            if !actions.systemAvailable { systemNote }
        case .shortcuts:
            row("唤出或收起挂绳", detail: system.shortcut) {
                textButton("更改…") { actions.changeShortcut(); refresh() }.disabled(!actions.systemAvailable)
            }
            ForEach([("新建闪念", "⌘N"), ("查找闪念", "⌘F"), ("粗体 / 斜体 / 下划线", "⌘B / I / U"), ("撤销 / 重做", "⌘Z / ⇧⌘Z"), ("收起闪念或菜单", "Esc")], id: \.0) { item in
                row(item.0) { Text(item.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(NotesTheme.muted) }
            }
            if !actions.systemAvailable { systemNote }
        }
    }

    private var divider: some View { Rectangle().fill(NotesTheme.border).frame(height: 1) }
    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(NotesTheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                control().fixedSize()
            }.padding(.vertical, 16)
            divider
        }
    }
    private func toggle(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        row(title, detail: detail) { Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(NotesTheme.accent).accessibilityLabel(title) }
    }
    private func quietNote(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(NotesTheme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 22)
    }
    private var systemNote: some View { quietNote("验收模式不会更改系统启动项、截图监听或剪贴板权限。") }
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.system(size: 12, weight: .medium)).foregroundStyle(NotesTheme.accent)
            .padding(.horizontal, 12).frame(height: 32).background(NotesTheme.paper(.blue), in: RoundedRectangle(cornerRadius: 8))
            .buttonStyle(NotesPressStyle())
    }
    private func menuValue(_ title: String, name: String, menu: @escaping () -> NSMenu) -> some View {
        menuValue(title, name: name, menu: menu) { EmptyView() }
    }
    private func menuValue<Leading: View>(_ title: String, name: String, menu: @escaping () -> NSMenu, @ViewBuilder leading: @escaping () -> Leading) -> some View {
        NotesMenuButton(name, alignment: .trailing, menu: menu) {
            HStack(spacing: 9) {
                leading()
                Text(title).font(.system(size: 13))
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(NotesTheme.muted)
            }.padding(.horizontal, 10).frame(height: 34).contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private var appearanceControl: some View {
        HStack(spacing: 6) {
            ForEach([("light", "浅色", "sun.max"), ("dark", "深色", "moon"), ("system", "跟随系统", "desktopcomputer")], id: \.0) { item in
                Button { withAnimation(NotesMotion.quick) { theme = item.0 } } label: {
                    HStack(spacing: 8) { Image(systemName: item.2).font(.system(size: 16)); Text(item.1).font(.system(size: 12)) }
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(theme == item.0 ? NotesTheme.accent : NotesTheme.muted)
                        .background(theme == item.0 ? NotesTheme.paper(.blue) : NotesTheme.muted.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(NotesPressStyle()).accessibilityLabel("外观：" + item.1).accessibilityAddTraits(theme == item.0 ? [.isSelected] : [])
            }
        }
    }
    private func refresh() {
        let current = actions.read()
        if current != system { system = current }
    }
    private func paperMenu() -> NSMenu { NotesPaperMenu.options(selected: NotePaper(rawValue: paper) ?? .blue) { paper = $0.rawValue } }
    private func scaleMenu() -> NSMenu {
        choiceMenu(scales.map { ("\(Int($0 * 100))%", $0) }, selected: readingScale) { readingScale = $0 }
    }
    private func activationMenu() -> NSMenu {
        choiceMenu([("指针靠近顶部", false), ("仅手动唤出", true)], selected: hoverDisabled) { hoverDisabled = $0 }
    }
    private func capacityMenu() -> NSMenu {
        choiceMenu([("适应屏幕", nil), ("25 项", 25), ("50 项", 50), ("100 项", 100)], selected: system.capacity) { actions.setCapacity($0); refresh() }
    }
    private func choiceMenu<Value: Equatable>(_ options: [(String, Value)], selected: Value, select: @escaping (Value) -> Void) -> NSMenu {
        let menu = NSMenu()
        for (title, value) in options {
            let item = ClosureMenuItem(title) { select(value) }
            item.state = value == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
