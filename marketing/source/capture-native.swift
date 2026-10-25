import AppKit
import SwiftUI
import NotesCore

// Isolated launch configuration for this renderer only. Production launch
// options are excluded when compiling it; no personal data/defaults are used.
enum LaunchOptions {
    static let appName = "拾片"
    static let version = "0.5.14"
    static let testBuild = false
    static let demo = true
    static let lineDefaults = UserDefaults(suiteName: "local.shipian.launch-capture.line")!
    static var directory: URL { URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) }
}

@main struct LaunchCapture {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        UserDefaults.standard.set("light", forKey: "notesTheme")
        UserDefaults.standard.set(true, forKey: "notesReduceMotion")
        UserDefaults.standard.set(1.0, forKey: "notesReadingScale")
        UserDefaults.standard.set(false, forKey: "notesAutoHang")
        LaunchOptions.lineDefaults.removePersistentDomain(forName: "local.shipian.launch-capture.line")
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "local.shipian.launch-capture")
            LaunchOptions.lineDefaults.removePersistentDomain(forName: "local.shipian.launch-capture.line")
        }
        let store = try NotesStore(directory: LaunchOptions.directory)
        try DemoNotes.seed(store)
        let workspace = NotesWorkspace(store: store)
        let line = Line(restoring: false, gusts: false)
        line.revealed = true
        line.onNewNote = { workspace.newNote(template: NoteTemplate(rawValue: $0) ?? .text) }
        line.onShowNotes = { workspace.showLibrary() }
        for resource in ["DemoGallery", "DemoArchitecture"] {
            if let url = Bundle.main.url(forResource: resource, withExtension: "png") {
                line.hang(url, quietly: true)
            }
        }
        for note in store.documents where note.deletedAt == nil {
            line.hangNote(note.id, thumbnail: workspace.thumbnail(for: note), title: note.displayTitle, quietly: true)
        }
        let rope = LinePanel(content: NSHostingView(rootView: LineView(line: line)))
        rope.setFrame(NSRect(x: 0, y: 500, width: 1920, height: Layout.panelHeight), display: false)
        rope.orderFrontRegardless()
        settle()
        try capture(rope, named: "rope-native.png", into: output)
        rope.orderOut(nil)

        let note = try XCTlessUnwrap(store.documents.first { $0.title == "把灵感留下来" })
        workspace.open(note.id)
        let editor = try XCTlessUnwrap(NSApp.windows.first { $0.title == note.title && $0.isVisible })
        editor.setContentSize(NSSize(width: 920, height: 650))
        editor.makeFirstResponder(nil)
        settle()
        try capture(editor, named: "editor-light.png", into: output)

        workspace.showLibrary()
        let library = try XCTlessUnwrap(NSApp.windows.first { $0.title == "全部闪念" && $0.isVisible })
        library.setContentSize(NSSize(width: 820, height: 560))
        library.makeFirstResponder(nil)
        settle()
        try capture(library, named: "library-light.png", into: output)

        workspace.showSettings()
        let settings = try XCTlessUnwrap(NSApp.windows.first { $0.title == "闪念偏好设置" && $0.isVisible })
        settings.makeFirstResponder(nil)
        settle()
        try capture(settings, named: "settings-light.png", into: output)
        settings.orderOut(nil)
        library.orderOut(nil)

        UserDefaults.standard.set("dark", forKey: "notesTheme")
        for window in NSApp.windows { window.appearance = NotesTheme.appearance() }
        editor.appearance = NSAppearance(named: .darkAqua)
        editor.makeKeyAndOrderFront(nil)
        editor.makeFirstResponder(nil)
        settle()
        try capture(editor, named: "editor-dark.png", into: output)

        UserDefaults.standard.set("light", forKey: "notesTheme")
        for window in NSApp.windows { window.appearance = NotesTheme.appearance() }
        let anchor = NSButton(frame: NSRect(x: 100, y: 150, width: 40, height: 44))
        let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 246))
        anchorView.addSubview(anchor)
        let menuRope = LinePanel(content: anchorView)
        menuRope.setFrame(NSRect(x: 700, y: 500, width: 400, height: 246), display: false)
        menuRope.orderFrontRegardless()
        NotesMenuPresenter.shared.show(LineControl.templateMenu(for: line), from: anchor)
        settle()
        try capture(try XCTlessUnwrap(NotesMenuPresenter.shared.panel), named: "new-menu.png", into: output)
        NotesMenuPresenter.shared.dismiss(animated: false)
        menuRope.orderOut(nil)
        for window in NSApp.windows { window.orderOut(nil) }
        print("Captured six native views using synthetic demo content.")
        withExtendedLifetime((workspace, line, rope, menuRope)) {}
    }

    @MainActor static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.65)) }
    @MainActor static func capture(_ window: NSWindow, named name: String, into output: URL) throws {
        let view = try XCTlessUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTlessUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTlessUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
        print(name, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
    static func XCTlessUnwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "LaunchCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native view unavailable"]) }
        return value
    }
}
