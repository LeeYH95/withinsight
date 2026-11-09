import AppKit
import SwiftUI
import NotesCore

/// A lightweight child view of the text surface. It follows TextKit geometry
/// without changing the document height or becoming part of its selection.
@MainActor final class NotesEditorContextTools {
    private weak var view: NotesContinuousTextView?
    private var host: NSHostingView<NotesContextBar>?
    private var field: NSHostingView<NotesContextField>?
    private var originalBarFrame: NSRect?
    private var fieldMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var imageID: UUID?
    private var imageRect: NSRect = .zero
    var enabled = false
    var trackingSelection = false
    var isVisible: Bool { host != nil }

    init(view: NotesContinuousTextView) { self.view = view }

    func selectionChanged() {
        guard enabled, !trackingSelection else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showSelection() }
        pending = work
        DispatchQueue.main.async(execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard field == nil else { return }
        host?.removeFromSuperview()
        host = nil
        imageID = nil
        imageRect = .zero
    }

    func detach() {
        closeField()
        hide()
    }

    func containsControl(at point: NSPoint) -> Bool {
        host?.frame.contains(point) == true || field?.frame.contains(point) == true
    }

    func hasButton(at point: NSPoint) -> Bool {
        guard let view else { return false }
        func containsButton(in candidate: NSView) -> Bool {
            guard !candidate.isHiddenOrHasHiddenAncestor,
                  candidate.visibleRect.intersection(candidate.bounds).contains(candidate.convert(point, from: view)) else { return false }
            return candidate is NotesButtonCursorRegion || candidate.subviews.contains(where: containsButton)
        }
        return host.map(containsButton) == true || field.map(containsButton) == true
    }

    func mouseMoved(to point: NSPoint, attachment: NoteAttachment?, at index: Int?) {
        guard enabled, let view, !trackingSelection, !view.hasMarkedText(),
              field == nil, view.window?.isKeyWindow == true else { return }
        if host?.frame.contains(point) == true || (imageID != nil && imageRect.contains(point)) { return }
        guard view.selectedRange().length == 0 || imageID != nil || selectedAttachment(view) else { return }
        guard let attachment, attachment.kind == .image, let index,
              let rect = glyphBounds(NSRange(location: index, length: 1), in: view) else {
            if imageID != nil { hide() }
            return
        }
        showImage(attachment, rect: rect)
    }

    private func showSelection() {
        guard enabled, !trackingSelection, field == nil, let view else { return }
        if let panel = NotesMenuPresenter.shared.panel,
           NotesMenuPresenter.shared.sourceWindow(for: panel) === view.window { return }
        guard view.window?.isKeyWindow == true, view.window?.firstResponder === view,
              view.window?.attachedSheet == nil, !view.hasMarkedText(),
              view.selectedRange().length > 0 else { hide(); return }
        let selection = view.selectedRange()
        if selection.length == 1, let id = attachmentID(at: selection.location, in: view),
           let image = view.session?.note.attachments.first(where: { $0.id == id && $0.kind == .image }),
           let rect = glyphBounds(selection, in: view) {
            showImage(image, rect: rect)
            return
        }
        let visible = view.visibleRect.intersection(view.bounds).insetBy(dx: 3, dy: 3)
        guard let storage = view.textStorage, NSMaxRange(selection) <= storage.length,
              !storage.attributedSubstring(from: selection).string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let layout = view.layoutManager, let container = view.textContainer else { hide(); return }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        var rect = NSRect.null
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { bounds, _ in
            let clipped = bounds.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y).intersection(visible)
            if !clipped.isEmpty { rect = rect.union(clipped) }
        }
        guard !rect.isNull else { hide(); return }
        let width: CGFloat = 248, height: CGFloat = 43, gap: CGFloat = 7
        guard visible.width >= width else { hide(); return }
        let above = rect.minY - height - gap
        let below = rect.maxY + gap
        let y: CGFloat
        if above >= visible.minY { y = above }
        else if below + height <= visible.maxY { y = below }
        else { hide(); return }
        let x = min(max(rect.midX - width / 2, visible.minX), visible.maxX - width)
        let heading = view.selectionHeading.flatMap { [0: "正文", 1: "标题 1", 2: "标题 2"][$0] } ?? "混合"
        let buttons = [
            NotesContextButton(label: "粗体", symbol: "bold", active: view.isSelected(.bold)) { [weak self] in self?.format(.bold) },
            NotesContextButton(label: "斜体", symbol: "italic", active: view.isSelected(.italic)) { [weak self] in self?.format(.italic) },
            NotesContextButton(label: "下划线", symbol: "underline", active: view.isSelected(.underline)) { [weak self] in self?.format(.underline) },
            NotesContextButton(label: "设置链接", symbol: "link", active: link(in: selection, view: view) != nil) { [weak self] in self?.editLink(selection) }
        ]
        let surface = NotesContextBar(label: "选区格式工具", paragraph: heading, buttons: buttons) { [weak self] in
            guard let self, let anchor = self.host, let view = self.view, let window = view.window else { return }
            self.closeField(restoreFocus: true)
            let menu = NotesEditorFormatMenu.contextual(view)
            NotesMenuPresenter.shared.show(menu, from: anchor, avoidingSelection: window.convertToScreen(view.convert(rect, to: nil))) { [weak self] in
                self?.selectionChanged()
            }
        }
        let entering = host == nil || imageID != nil
        imageID = nil; imageRect = .zero
        present(surface, frame: NSRect(x: x, y: y, width: width, height: height), entering: entering)
    }

    private func showImage(_ attachment: NoteAttachment, rect: NSRect) {
        guard let view, let session = view.session else { return }
        let visible = view.visibleRect.intersection(view.bounds).insetBy(dx: 5, dy: 5)
        let image = visible.intersection(rect)
        let width: CGFloat = 132, height: CGFloat = 36
        guard !image.isEmpty, visible.width >= width, visible.height >= height else { hide(); return }
        let x = image.width >= width + 14
            ? image.maxX - width - 7
            : min(max(image.minX, visible.minX), visible.maxX - width)
        let y = image.height >= height + 10
            ? image.minY + 5
            : min(max(image.maxY - 5, visible.minY), visible.maxY - height)
        let block = session.note.blocks.first { $0.attachmentID == attachment.id }
        let buttons = [
            NotesContextButton(label: "替换图片", symbol: "arrow.left.arrow.right") { [weak self, weak session] in
                self?.hide(); session?.chooseReplacementImage(for: attachment.id)
            },
            NotesContextButton(label: "调整图片宽度", symbol: "arrow.left.and.right", active: block?.imageWide == true) { [weak self, weak session] in
                guard let self, let anchor = self.host, let session else { return }
                let menu = NSMenu(title: "图片宽度")
                for (wide, title) in [(false, "适中"), (true, "铺满正文")] {
                    let item = ClosureMenuItem(title) { [weak session] in session?.updateImageLayout(attachment.id, wide: wide) }
                    item.state = (block?.imageWide == true) == wide ? .on : .off
                    menu.addItem(item)
                }
                NotesMenuPresenter.shared.show(menu, from: anchor, alignment: .trailing)
            },
            NotesContextButton(label: "图片说明", symbol: "text.cursor", active: block?.imageCaption != nil) { [weak self, weak session] in
                self?.editValue(title: "图片说明", placeholder: "添加一句说明…", value: block?.imageCaption ?? "") { text in
                    session?.updateImageCaption(attachment.id, caption: text)
                }
            },
            NotesContextButton(label: "移除图片", symbol: "trash") { [weak self, weak session] in
                self?.hide(); session?.removeAttachment(attachment)
            }
        ]
        let entering = imageID != attachment.id
        imageID = attachment.id
        imageRect = rect
        present(NotesContextBar(label: "图片操作", paragraph: nil, buttons: buttons),
                frame: NSRect(x: x, y: y, width: width, height: height), entering: entering)
    }

    private func present(_ bar: NotesContextBar, frame: NSRect, entering: Bool) {
        guard let view else { return }
        let surface: NSHostingView<NotesContextBar>
        if let host { surface = host; surface.rootView = bar }
        else {
            surface = NSHostingView(rootView: bar)
            surface.sizingOptions = []
            surface.wantsLayer = true
            view.addSubview(surface)
            host = surface
        }
        surface.appearance = view.effectiveAppearance
        surface.frame = view.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        if entering && !NotesMotion.reduced {
            surface.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                surface.animator().alphaValue = 1
            }
        } else {
            surface.alphaValue = 1
        }
    }

    private func editLink(_ selection: NSRange) {
        guard let view else { return }
        if field != nil { closeField(restoreFocus: true); selectionChanged(); return }
        let existing = link(in: selection, view: view)
        editValue(title: "链接地址", placeholder: "https://", value: existing?.absoluteString ?? "",
                  valid: { ($0.isEmpty && existing != nil) || NotesWebLink.url(from: $0) != nil }) { [weak view] value in
            guard view?.selectedRange() == selection else { return }
            view?.applyContextLink(NotesWebLink.url(from: value), to: selection)
        }
    }

    private func format(_ action: NotesTextFormat) {
        closeField(restoreFocus: true)
        view?.session?.format(action)
    }

    private func editValue(title: String, placeholder: String, value: String,
                           valid: @escaping (String) -> Bool = { _ in true }, apply: @escaping (String) -> Void) {
        guard field == nil, let anchor = host, let view, let window = anchor.window else { return }
        let visible = view.visibleRect.intersection(view.bounds).insetBy(dx: 3, dy: 3)
        let width = min(300, visible.width), height: CGFloat = 78, gap: CGFloat = 8
        guard width >= 200, visible.height >= height + gap + anchor.frame.height else { return }
        let start = anchor.frame
        let x = min(max(start.minX, visible.minX), visible.maxX - width)
        let y = min(start.minY, visible.maxY - start.height - gap - height)
        originalBarFrame = start
        anchor.frame = view.backingAlignedRect(
            NSRect(x: x, y: y, width: imageID == nil ? width : start.width, height: start.height),
            options: .alignAllEdgesNearest
        )
        let input = NSHostingView(rootView: NotesContextField(
            title: title, placeholder: placeholder, value: value, valid: valid
        ) { [weak self] text in
            guard let self else { return }
            self.closeField(restoreFocus: true)
            apply(text)
            self.selectionChanged()
        })
        input.sizingOptions = []
        input.appearance = anchor.appearance
        input.frame = view.backingAlignedRect(
            NSRect(x: x, y: anchor.frame.maxY + gap, width: width, height: height),
            options: .alignAllEdgesNearest
        )
        field = input
        view.addSubview(input, positioned: .above, relativeTo: anchor)
        fieldMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let view = self.view, let window = view.window else { return false }
                if event.type == .keyDown {
                    guard event.window === window, event.keyCode == 53,
                          (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                    self.closeField(restoreFocus: true)
                    self.selectionChanged()
                    return true
                }
                if event.window !== window || !self.containsControl(at: view.convert(event.locationInWindow, from: nil)) {
                    self.closeField(restoreFocus: event.type == .scrollWheel && event.window === window)
                    self.hide()
                }
                return false
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        }
    }

    private func closeField(restoreFocus: Bool = false) {
        guard let field else { return }
        if let fieldMonitor { NSEvent.removeMonitor(fieldMonitor); self.fieldMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        self.field = nil
        field.removeFromSuperview()
        if let originalBarFrame { host?.frame = originalBarFrame; self.originalBarFrame = nil }
        if restoreFocus, let view { view.window?.makeFirstResponder(view) }
    }

    private func link(in range: NSRange, view: NotesContinuousTextView) -> URL? {
        guard let storage = view.textStorage, range.location < storage.length else { return nil }
        return NotesWebLink.destination(from: storage.attribute(.link, at: range.location, effectiveRange: nil))
    }

    private func selectedAttachment(_ view: NotesContinuousTextView) -> Bool {
        let range = view.selectedRange()
        return range.length == 1 && attachmentID(at: range.location, in: view) != nil
    }

    private func attachmentID(at index: Int, in view: NotesContinuousTextView) -> UUID? {
        guard let storage = view.textStorage, index < storage.length else { return nil }
        return (storage.attribute(.notesAttachment, at: index, effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:))
    }

    private func glyphBounds(_ range: NSRange, in view: NotesContinuousTextView) -> NSRect? {
        guard let layout = view.layoutManager, let container = view.textContainer,
              NSMaxRange(range) <= (view.textStorage?.length ?? 0) else { return nil }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }
}

private struct NotesContextButton {
    let label: String
    let symbol: String
    var active = false
    let action: () -> Void
}

private enum NotesContextStyle {
    static let paper = NotesTheme.adaptive(0xFCFDFF, 0x343A45)
    static let border = NotesTheme.adaptive(0xD8DFEB, 0x4A5463)
    static let ink = NotesTheme.adaptive(0x647084, 0xB5BFCE)
    static let blue = NotesTheme.adaptive(0x4D63AC, 0xA9BDF5)
    static let selected = NotesTheme.adaptive(0xE9EEF9, 0x405272)

    static func surface(_ radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape.fill(paper)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .shadow(color: Color(notesHex: 0x304263).opacity(0.13), radius: 10, y: 4)
    }
}

private struct NotesContextBar: View {
    let label: String
    let paragraph: String?
    let buttons: [NotesContextButton]
    var showParagraph: () -> Void = {}

    var body: some View {
        HStack(spacing: paragraph == nil ? 1 : 2) {
            if let paragraph {
                Button(action: showParagraph) {
                    HStack {
                        Text(paragraph).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 3)
                        Image(nsImage: NotesPrototypeGlyph.caretDown).renderingMode(.template)
                    }.padding(.horizontal, 10).frame(width: 80, height: 31)
                }
                .buttonStyle(NotesPressStyle(liftOnHover: false))
                .background { NotesButtonCursor() }
                .accessibilityLabel("段落样式，当前\(paragraph)")
                divider
            }
            ForEach(buttons, id: \.label) { item in
                if paragraph != nil && item.symbol == "link" { divider }
                Button(action: item.action) {
                    glyph(item.symbol)
                        .foregroundStyle(item.active ? NotesContextStyle.blue : NotesContextStyle.ink)
                        .frame(width: paragraph == nil ? 29 : 31, height: paragraph == nil ? 28 : 31)
                        .background(item.active ? NotesContextStyle.selected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(NotesPressStyle(hoverFill: !item.active, liftOnHover: false))
                .background { NotesButtonCursor() }
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(item.active ? .isSelected : [])
                .help(item.label)
            }
        }
        .padding(.horizontal, paragraph == nil ? 4 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: paragraph == nil ? .center : .leading)
        .foregroundStyle(NotesTheme.text)
        .background { NotesContextStyle.surface(paragraph == nil ? 10 : 12) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var divider: some View {
        Rectangle().fill(NotesContextStyle.border).frame(width: 1, height: 17).padding(.horizontal, 4)
    }

    @ViewBuilder private func glyph(_ symbol: String) -> some View {
        if let image = NotesPrototypeGlyph.tools[symbol] {
            Image(nsImage: image).renderingMode(.template)
        } else {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
        }
    }
}

// Phosphor Regular SVG paths used by the editor prototype (MIT).
private enum NotesPrototypeGlyph {
    static let tools = [
        "bold": image("M178.48,115.7A44,44,0,0,0,148,40H80a8,8,0,0,0-8,8V200a8,8,0,0,0,8,8h80a48,48,0,0,0,18.48-92.3ZM88,56h60a28,28,0,0,1,0,56H88Zm72,136H88V128h72a32,32,0,0,1,0,64Z", size: 18),
        "italic": image("M200,56a8,8,0,0,1-8,8H157.77L115.1,192H144a8,8,0,0,1,0,16H64a8,8,0,0,1,0-16H98.23L140.9,64H112a8,8,0,0,1,0-16h80A8,8,0,0,1,200,56Z", size: 18),
        "underline": image("M200,224a8,8,0,0,1-8,8H64a8,8,0,0,1,0-16H192A8,8,0,0,1,200,224Zm-72-24a64.07,64.07,0,0,0,64-64V56a8,8,0,0,0-16,0v80a48,48,0,0,1-96,0V56a8,8,0,0,0-16,0v80A64.07,64.07,0,0,0,128,200Z", size: 18),
        "link": image("M165.66,90.34a8,8,0,0,1,0,11.32l-64,64a8,8,0,0,1-11.32-11.32l64-64A8,8,0,0,1,165.66,90.34ZM215.6,40.4a56,56,0,0,0-79.2,0L106.34,70.45a8,8,0,0,0,11.32,11.32l30.06-30a40,40,0,0,1,56.57,56.56l-30.07,30.06a8,8,0,0,0,11.31,11.32L215.6,119.6a56,56,0,0,0,0-79.2ZM138.34,174.22l-30.06,30.06a40,40,0,1,1-56.56-56.57l30.05-30.05a8,8,0,0,0-11.32-11.32L40.4,136.4a56,56,0,0,0,79.2,79.2l30.06-30.07a8,8,0,0,0-11.32-11.31Z", size: 18),
    ]
    static let caretDown = image("M213.66,101.66l-80,80a8,8,0,0,1-11.32,0l-80-80A8,8,0,0,1,53.66,90.34L128,164.69l74.34-74.35a8,8,0,0,1,11.32,11.32Z", size: 11)
    static let check = image("M229.66,77.66l-128,128a8,8,0,0,1-11.32,0l-56-56a8,8,0,0,1,11.32-11.32L96,188.69,218.34,66.34a8,8,0,0,1,11.32,11.32Z", size: 15)

    private static func image(_ path: String, size: Int) -> NSImage {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 256 256">
          <path d="\(path)"/>
        </svg>
        """
        return NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: size, height: size))
    }
}

private struct NotesContextField: View {
    let title: String
    let placeholder: String
    @State var value: String
    let valid: (String) -> Bool
    let apply: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(NotesContextStyle.ink)
            HStack(spacing: 8) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(NotesTheme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 29)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(NotesContextStyle.border, lineWidth: 1)
                    }
                    .accessibilityLabel(title)
                    .focused($focused)
                    .onSubmit { if valid(value) { apply(value) } }
                Button { if valid(value) { apply(value) } } label: {
                    Label { Text("应用") } icon: { Image(nsImage: NotesPrototypeGlyph.check).renderingMode(.template) }
                        .font(.system(size: 11))
                        .foregroundStyle(NotesTheme.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 29)
                        .background(NotesContextStyle.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(NotesPressStyle(hoverFill: false))
                    .background { if valid(value) { NotesButtonCursor() } }
                    .help(valid(value) ? "应用" : "请输入有效的网页地址")
            }
        }.padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background { NotesContextStyle.surface(14) }
            .onAppear { focused = true }
    }
}

struct NotesButtonCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NotesButtonCursorRegion() }
    func updateNSView(_ view: NSView, context: Context) {}
}

final class NotesButtonCursorRegion: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        let region = visibleRect.intersection(bounds)
        // A fully clipped view has a null intersection with an infinite origin.
        guard !region.isEmpty else { return }
        addCursorRect(region, cursor: .pointingHand)
    }
}
