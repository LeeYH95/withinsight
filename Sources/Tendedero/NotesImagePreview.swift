import AppKit
import ImageIO
import SwiftUI

/// The supplied image is an immediate preview. A source URL supplies original
/// pixels independently of the editor's 2048-pixel display cache.
struct NotesImagePreview: View {
    let name: String
    let image: NSImage?
    var sourceURL: URL? = nil
    var copy: () -> Void
    var export: () -> Void
    var close: () -> Void
    @State private var original: NSImage?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var status = NotesImagePreviewStatus()
    @State private var command = NotesImagePreviewCommand()

    private var displayedImage: NSImage? { original ?? image }
    private var sheetSize: NSSize {
        NotesImagePreviewSizing.preferredSize(available: NSScreen.main?.visibleFrame.size ?? NSSize(width: 1024, height: 768))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo").foregroundStyle(NotesTheme.accent)
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if loading { ProgressView().controlSize(.small).accessibilityLabel("正在读取原图") }
                NotesIconButton(symbol: "xmark", label: "关闭图片预览 · Esc", size: 30, action: close)
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).frame(height: 52)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NotesTheme.surface)
                if let displayedImage {
                    NotesImagePreviewSurface(image: displayedImage, name: name, command: command, copy: copy, close: close) { next in
                        if status != next { status = next }
                    }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: loading ? "photo" : "photo.badge.exclamationmark")
                            .font(.system(size: 30, weight: .light))
                        Text(loading ? "正在读取图片…" : "图片暂时无法读取").font(.system(size: 13, weight: .medium))
                        if !loading { Text("仍可导出附件，保留原文件。").font(.system(size: 12)) }
                    }.foregroundStyle(NotesTheme.muted)
                }
            }.overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NotesTheme.border.opacity(0.6), lineWidth: 1) }
                .padding(.horizontal, 16)

            HStack(spacing: 4) {
                toolbarIcon("minus", label: "缩小 · ⌘−", action: .zoomOut)
                    .keyboardShortcut("-", modifiers: .command).disabled(!status.canZoomOut || displayedImage == nil)
                Text("\(Int((status.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit().frame(width: 48)
                    .foregroundStyle(NotesTheme.muted).accessibilityLabel("缩放 \(Int((status.zoom * 100).rounded()))%")
                toolbarIcon("plus", label: "放大 · ⌘+", action: .zoomIn)
                    .keyboardShortcut("=", modifiers: .command).disabled(!status.canZoomIn || displayedImage == nil)
                Divider().frame(height: 16).padding(.horizontal, 6)
                Button("适应") { perform(.fit) }.keyboardShortcut("0", modifiers: .command)
                    .frame(width: 44, height: 32).foregroundStyle(status.fitted ? NotesTheme.accent : NotesTheme.muted)
                    .accessibilityLabel("适应窗口 · ⌘0").accessibilityAddTraits(status.fitted ? [.isSelected] : [])
                    .disabled(displayedImage == nil)
                Button("100%") { perform(.actualSize) }.keyboardShortcut("1", modifiers: .command)
                    .frame(width: 48, height: 32).foregroundStyle(!status.fitted && abs(status.zoom - 1) < 0.001 ? NotesTheme.accent : NotesTheme.muted)
                    .accessibilityLabel("原始像素大小 · ⌘1").notesTooltip("原始像素大小：一个图片像素对应一个屏幕像素")
                    .disabled(displayedImage == nil)
                Spacer(minLength: 8)
                if loadFailed && image != nil {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(NotesTheme.muted)
                        .notesTooltip("原图读取失败，当前显示预览图").accessibilityLabel("原图读取失败，当前显示预览图")
                }
                Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 32, height: 32) }
                    .keyboardShortcut("c", modifiers: .command).accessibilityLabel("复制图片 · ⌘C").notesTooltip("复制图片")
                    .disabled(displayedImage == nil)
                Button(action: export) { Image(systemName: "square.and.arrow.up").frame(width: 32, height: 32) }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).accessibilityLabel("导出原图… · ⇧⌘S").notesTooltip("导出原图…")
            }.font(.system(size: 12)).buttonStyle(NotesPressStyle()).foregroundStyle(NotesTheme.muted)
                .padding(.horizontal, 18).frame(height: 56)
                .accessibilityElement(children: .contain).accessibilityLabel("图片预览工具")
        }.foregroundStyle(NotesTheme.text).background(NotesTheme.shell)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: sheetSize.width, height: sheetSize.height)
            .background {
                Button(action: copy) { EmptyView() }
                    .keyboardShortcut("c", modifiers: .control)
                    .disabled(displayedImage == nil)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            .task(id: sourceURL) {
                original = nil
                loadFailed = false
                loading = false
                guard let sourceURL else { return }
                loading = true
                let result = await Task.detached(priority: .userInitiated) {
                    autoreleasepool { NotesImagePreviewOriginal.read(sourceURL) }
                }.value
                guard !Task.isCancelled else { return }
                original = result
                loadFailed = result == nil
                loading = false
            }
    }

    private func toolbarIcon(_ symbol: String, label: String, action: NotesImagePreviewCommand.Action) -> some View {
        Button { perform(action) } label: { Image(systemName: symbol).frame(width: 30, height: 32) }
            .accessibilityLabel(label).notesTooltip(label)
    }
    private func perform(_ action: NotesImagePreviewCommand.Action) {
        command = NotesImagePreviewCommand(action: action, revision: command.revision &+ 1)
    }
}

enum NotesImagePreviewSizing {
    /// A large attachment never dictates the sheet's intrinsic dimensions.
    static func preferredSize(available: NSSize) -> NSSize {
        NSSize(width: min(840, max(1, available.width - 80)), height: min(620, max(1, available.height - 80)))
    }
}

private enum NotesImagePreviewOriginal {
    static func read(_ url: URL) -> NSImage? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let representation = NSBitmapImageRep(cgImage: bitmap)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct NotesImagePreviewStatus: Equatable {
    var zoom: CGFloat = 1
    var fitted = true
    var canZoomIn = true
    var canZoomOut = false
}

struct NotesImagePreviewCommand {
    enum Action { case fit, actualSize, zoomIn, zoomOut }
    var action: Action = .fit
    var revision: UInt = 0
}

private struct NotesImagePreviewSurface: NSViewRepresentable {
    let image: NSImage
    let name: String
    let command: NotesImagePreviewCommand
    let copy: () -> Void
    let close: () -> Void
    let updateStatus: (NotesImagePreviewStatus) -> Void
    func makeNSView(context: Context) -> NotesImagePreviewCanvas { NotesImagePreviewCanvas() }
    func updateNSView(_ view: NotesImagePreviewCanvas, context: Context) {
        view.close = close
        view.copyImage = copy
        view.statusChanged = { status in DispatchQueue.main.async { updateStatus(status) } }
        view.configure(image: image, name: name)
        if view.commandRevision != command.revision {
            view.commandRevision = command.revision
            view.perform(command.action)
        }
    }
}

/// Native magnification and scrolling preserve the source aspect ratio. The
/// document uses backing pixels at 100%, rather than NSImage's DPI point size.
final class NotesImagePreviewCanvas: NSScrollView {
    var close: () -> Void = {}
    var copyImage: () -> Void = {}
    var statusChanged: (NotesImagePreviewStatus) -> Void = { _ in }
    var commandRevision: UInt?
    private(set) var fitted = true
    private(set) var pixelSize = NSSize.zero
    private let picture = NotesImagePreviewPicture()
    private var viewportSize = NSSize.zero
    private var backing: CGFloat = 1
    private var updatingGeometry = false
    var imageFrameInViewport: NSRect { convert(picture.bounds, from: picture) }
    var fitZoom: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let width = max(1, contentSize.width - 40)
        let height = max(1, contentSize.height - 40)
        return min(1, min(width / picture.bounds.width, height / picture.bounds.height))
    }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = NotesImagePreviewClipView()
        documentView = picture
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 8
        usesPredominantAxisScrolling = false
        picture.canvas = self
        setAccessibilityLabel("图片预览")
        setAccessibilityHelp("双击切换适应窗口与原始像素大小；放大后可拖动或用方向键平移。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(image: NSImage, name: String) {
        picture.setAccessibilityLabel(name)
        guard picture.image !== image else { return }
        picture.image = image
        let representation = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        pixelSize = representation.map { NSSize(width: CGFloat($0.pixelsWide), height: CGFloat($0.pixelsHigh)) } ?? image.size
        updateDocumentGeometry()
    }
    override func layout() {
        super.layout()
        if viewportSize != contentSize { updateDocumentGeometry() }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateDocumentGeometry() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDocumentGeometry() }

    private func updateDocumentGeometry() {
        guard !updatingGeometry, pixelSize.width > 0, pixelSize.height > 0 else { return }
        updatingGeometry = true
        defer { updatingGeometry = false }
        viewportSize = contentSize
        backing = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        picture.frame = NSRect(origin: .zero, size: NSSize(width: pixelSize.width / backing, height: pixelSize.height / backing))
        minMagnification = min(0.1, fitZoom)
        setZoom(fitted ? fitZoom : magnification, fitted: fitted)
    }

    func perform(_ action: NotesImagePreviewCommand.Action) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        switch action {
        case .fit: setZoom(fitZoom, fitted: true)
        case .actualSize: setZoom(1, fitted: false)
        case .zoomIn: setZoom(magnification * 1.25, fitted: false)
        case .zoomOut: setZoom(magnification / 1.25, fitted: false)
        }
    }
    func toggleFit() { perform(fitted ? .actualSize : .fit) }

    private func setZoom(_ value: CGFloat, fitted: Bool) {
        self.fitted = fitted
        // Preserve the user's viewport center while stepping zoom. Fit and
        // actual-size commands start from the image center.
        let center = fitted || abs(value - 1) < 0.0001
            ? NSPoint(x: picture.bounds.midX, y: picture.bounds.midY)
            : NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(maxMagnification, max(minMagnification, value)), centeredAt: center)
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
        window?.invalidateCursorRects(for: picture)
        reportStatus()
    }
    override func magnify(with event: NSEvent) {
        fitted = false
        super.magnify(with: event)
        reportStatus()
    }
    private func reportStatus() {
        statusChanged(NotesImagePreviewStatus(zoom: magnification, fitted: fitted,
                                             canZoomIn: magnification < maxMagnification - 0.0001,
                                             canZoomOut: magnification > minMagnification + 0.0001))
    }
    func pan(by delta: NSSize) {
        guard magnification > fitZoom + 0.0001 else { return }
        let bounds = contentView.bounds
        let proposed = NSRect(x: bounds.minX + delta.width / magnification, y: bounds.minY + delta.height / magnification,
                              width: bounds.width, height: bounds.height)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]) == .control,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyImage()
            return
        }
        switch event.keyCode {
        case 53: close()
        case 123: pan(by: NSSize(width: -48, height: 0))
        case 124: pan(by: NSSize(width: 48, height: 0))
        case 125: pan(by: NSSize(width: 0, height: 48))
        case 126: pan(by: NSSize(width: 0, height: -48))
        default: super.keyDown(with: event)
        }
    }
}

private final class NotesImagePreviewClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
        if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        return result
    }
}

private final class NotesImagePreviewPicture: NSView {
    weak var canvas: NotesImagePreviewCanvas?
    var image: NSImage? { didSet { needsDisplay = true } }
    private var dragPoint: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvas)
        if event.clickCount == 2 { canvas?.toggleFit(); dragPoint = nil }
        else { dragPoint = event.locationInWindow }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragPoint else { return }
        canvas?.pan(by: NSSize(width: dragPoint.x - event.locationInWindow.x, height: event.locationInWindow.y - dragPoint.y))
        self.dragPoint = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
    override func resetCursorRects() {
        if let canvas, canvas.magnification > canvas.fitZoom + 0.0001 { addCursorRect(bounds, cursor: .openHand) }
    }
}
