import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

final class NotesTooltipTests: XCTestCase {
    @MainActor func testMenuHelpIsExplicitForUnlabelledControls() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HStack {
            NotesMenuButton("显示大小", menu: { NSMenu() }) { Text("显示 100%") }
            NotesMenuButton("更多操作", tooltip: "更多操作", menu: { NSMenu() }) { Image(systemName: "ellipsis") }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func hints(_ view: NSView) -> [String] {
            (view as? NotesTooltipAnchor.AnchorView).map { [$0.text] } ?? view.subviews.flatMap(hints)
        }
        XCTAssertEqual(hints(host), ["更多操作"], "Visible labels must not acquire automatic hover popups; icons can opt in independently of their accessible names")
        window.orderOut(nil)
    }

    @MainActor func testActualLabelFitsChineseAndMultilineHelp() throws {
        _ = NSApplication.shared
        let pointer = NSEvent.mouseLocation
        let window = NotesWindow(contentRect: NSRect(x: pointer.x - 40, y: pointer.y - 25, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        window.contentView = anchor
        window.orderFront(nil)
        // This test measures the real native label, not physical mouse routing.
        // Supply a point in the actual window so user pointer movement cannot
        // turn a size assertion into a nondeterministic hover dismissal.
        let presenter = NotesTooltipPresenter(pointerLocation: { window.convertPoint(toScreen: NSPoint(x: 50, y: 30)) })
        defer { presenter.dismiss(); window.orderOut(nil) }
        for text in ["文字格式 · 粗体 / 斜体 / 下划线", "收回挂绳，保留正文与附件 · Esc", "导出图片副本：一份很长的参考图片文件名，包含中文、English words 和更多说明。", "第一行\n第二行：完整显示多行提示"] {
            presenter.show(text, from: anchor)
            let panel = try XCTUnwrap(presenter.panel)
            let label = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
            let needed = try XCTUnwrap(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000))
            XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, needed.height, "Tooltip must fit the native cell, including CJK fallback and cell padding: \(text)")
            XCTAssertTrue(panel.contentView!.bounds.contains(label.frame))
            XCTAssertEqual(label.stringValue, text)
            if text.hasPrefix("文字格式"), let folder = ProcessInfo.processInfo.environment["SHIPIAN_QA_EVIDENCE"],
               let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("tooltip-chinese-fixed.png"), options: .atomic)
            }
            presenter.dismiss()
        }
    }
}
