import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        let isRecording = item.isRecording
        view.itemID = id
        view.onReorder = { dragged, after in
            if after { line.move(dragged, after: id) } else { line.move(dragged, before: id) }
        }
        if let noteID = item.noteID {
            view.url = nil
            view.dragURLProvider = { line.noteDragURL?(noteID) }
            view.dragImage = item.thumb
            view.outsideOperations = [.copy, .delete]
            view.onClick = { line.open(id) }
            view.onDoubleClick = { line.open(id) }
            view.onLongPress = { line.open(id) }
            view.onForceClick = { line.open(id) }
            view.onDragStart = { line.draggingID = id }
            view.onDragEnd = { line.draggingID = nil }
            view.onTrash = { line.onDeleteNote?(noteID) }
            view.onDiscard = { line.discard(id) }
            view.onPressChange = { line.pressedID = $0 ? id : nil }
            view.setAccessibilityLabel("\(item.noteTitle ?? "闪念")，点按编辑；角落按钮从绳上取下")
            view.hoverHelp = "点按编辑 · 拖动排序 · 拖出为含附件的 Markdown 文件夹"
            view.crossHelp = "从挂绳取下，保留闪念"
            view.setAccessibilityHelp(view.hoverHelp)
            view.toolTip = nil
            view.menuProvider = {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem("打开闪念") { line.open(id) })
                menu.addItem(ClosureMenuItem("复制内容") { line.copy(id) })
                menu.addItem(ClosureMenuItem("制作副本") { line.onDuplicateNote?(noteID) })
                menu.addItem(ClosureMenuItem("导出 Markdown…") { line.onExportNote?(noteID) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("从绳上取下") { line.discard(id) })
                menu.addItem(ClosureMenuItem("移到最近删除…") { line.onDeleteNote?(noteID) }.notesDanger())
                return menu
            }
            return
        }
        view.dragURLProvider = nil
        view.outsideOperations = [.copy, .move, .delete]
        view.toolTip = nil
        view.hoverHelp = "点按复制 · 双击打开 · 按住标注 · 拖动排序"
        view.crossHelp = "从挂绳取下"
        view.setAccessibilityHelp(view.hoverHelp)
        view.setAccessibilityLabel("截图：\(item.url.lastPathComponent)，点按复制；双击打开")
        view.url = item.url
        view.dragImage = item.thumb
        view.onClick = { line.copy(id) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onForceClick = { line.quickLook(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            // Items say themselves whether they can be used.
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { line.quickLook(id) })
            if !isRecording {
                menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) }.notesDanger())
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) }.notesDanger())
            }
            let left = ClosureMenuItem(L("Take down everything to the left")) { line.takeDown(id, toTheLeft: true) }
            left.isEnabled = !line.neighbours(of: id, toTheLeft: true).isEmpty
            menu.addItem(left)
            let right = ClosureMenuItem(L("Take down everything to the right")) { line.takeDown(id, toTheLeft: false) }
            right.isEnabled = !line.neighbours(of: id, toTheLeft: false).isEmpty
            menu.addItem(right)
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    static var activeDragID: UUID?
    var itemID: UUID?
    var onReorder: ((UUID, Bool) -> Void)?
    var dragURLProvider: (() -> URL?)?
    var outsideOperations: NSDragOperation = [.copy, .move, .delete]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = Self.activeDragID, source != itemID else { return [] }
        return .move
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { Self.activeDragID != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = Self.activeDragID, source != itemID else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        onReorder?(source, point.x >= bounds.midX)
        return true
    }
    /// A photo's menu is open. It reaches past the line, so the line waits.
    static var isShowingMenu = false

    var url: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    var hoverHelp = ""
    var crossHelp = ""
    private var helpTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let helpTracking { removeTrackingArea(helpTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area); helpTracking = area
    }
    override func mouseEntered(with event: NSEvent) { showHelp(event) }
    override func mouseMoved(with event: NSEvent) { showHelp(event) }
    override func mouseExited(with event: NSEvent) { NotesTooltipPresenter.shared.dismiss(ifAnchoredTo: self) }
    private func showHelp(_ event: NSEvent) {
        guard !Self.isDragging, downPoint == nil else { return }
        NotesTooltipPresenter.shared.show(isInCross(event) ? crossHelp : hoverHelp, from: self)
    }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func accessibilityPerformPress() -> Bool { NotesTooltipPresenter.shared.dismiss(); onClick(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        NotesTooltipPresenter.shared.dismiss()
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        guard let url = dragURLProvider?() ?? url else { return }
        startedDrag = true
        endPress()
        Self.activeDragID = itemID

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NotesMenuPresenter.shared.show(menuProvider(), from: self, at: convert(event.locationInWindow, from: nil))
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? outsideOperations : (Self.activeDragID != nil ? .move : [])
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        Self.activeDragID = nil
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
