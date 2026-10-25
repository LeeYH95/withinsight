import AppKit
import SwiftUI

enum NotesResizeAxis { case horizontal, vertical, both }

enum NotesResizeGeometry {
    static func frame(_ start:NSRect,delta:NSSize,axis:NotesResizeAxis,minimum:NSSize,visible:NSRect) -> NSRect {
        let width = axis == .vertical ? start.width : min(max(minimum.width,start.width + delta.width),visible.maxX - start.minX)
        let height = axis == .horizontal ? start.height : min(max(minimum.height,start.height - delta.height),start.maxY - visible.minY)
        return NSRect(x:start.minX,y:start.maxY - height,width:width,height:height)
    }
}

/// Borderless windows do not consistently expose AppKit's edge resize hit regions.
/// These transparent regions preserve the top/left anchor and have no visible grip.
struct NotesEditorResizeHandle:NSViewRepresentable {
    let axis:NotesResizeAxis
    func makeNSView(context:Context) -> Handle { Handle(axis:axis) }
    func updateNSView(_ view:Handle,context:Context) {}

    final class Handle:NSView {
        let axis:NotesResizeAxis
        private var start: (frame: NSRect, pointer: NSPoint, visible: NSRect)?
        init(axis:NotesResizeAxis) { self.axis = axis; super.init(frame:.zero); setAccessibilityElement(false) }
        required init?(coder:NSCoder) { nil }
        override func resetCursorRects() {
            let cursor:NSCursor
            switch axis { case .horizontal:cursor = .resizeLeftRight; case .vertical:cursor = .resizeUpDown; case .both:cursor = Self.diagonalCursor }
            addCursorRect(bounds,cursor:cursor)
        }
        private static let diagonalCursor:NSCursor = {
            let image = NSImage(size:NSSize(width:24,height:24),flipped:false) { _ in
                let path = NSBezierPath()
                path.move(to:NSPoint(x:5,y:19)); path.line(to:NSPoint(x:19,y:5))
                path.move(to:NSPoint(x:5,y:12)); path.line(to:NSPoint(x:5,y:19)); path.line(to:NSPoint(x:12,y:19))
                path.move(to:NSPoint(x:12,y:5)); path.line(to:NSPoint(x:19,y:5)); path.line(to:NSPoint(x:19,y:12))
                path.lineJoinStyle = .round; path.lineCapStyle = .round
                NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
                NSColor.black.setStroke(); path.lineWidth = 1.5; path.stroke(); return true
            }
            return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
        }()
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event:NSEvent) {
            start = nil
            guard let window, window.attachedSheet == nil, !event.modifierFlags.contains(.control) else { return }
            NotesMenuPresenter.shared.dismiss(); NotesTooltipPresenter.shared.dismiss()
            start = (window.frame, window.convertPoint(toScreen:event.locationInWindow), window.screen?.visibleFrame ?? window.frame)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let start, window.attachedSheet == nil else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let frame = NotesResizeGeometry.frame(start.frame, delta: NSSize(width: point.x - start.pointer.x, height: point.y - start.pointer.y), axis: axis, minimum: window.minSize, visible: start.visible)
            window.setFrame(frame, display: true)
        }
        override func mouseUp(with event: NSEvent) { start = nil }
    }
}
