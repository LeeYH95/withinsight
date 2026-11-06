import AppKit
import Foundation
import NotesCore

/// Opt-in network acceptance. Uses a private pasteboard and a disposable store;
/// the ordinary offline harness never requires these websites to be reachable.
@MainActor enum LinkMetadataProbe {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipian-live-links-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let samples = [
            ("wechat-plain", "https://mp.weixin.qq.com/s/QVu2luIrRTtNvsH-U65A8g", "如何让 Super-agent 成为同事", false),
            ("wechat-rich", "https://mp.weixin.qq.com/s/QVu2luIrRTtNvsH-U65A8g", "如何让 Super-agent 成为同事", true),
            ("youtube-watch", "https://www.youtube.com/watch?v=jNQXAC9IVRw", "Me at the zoo", false),
            ("youtube-short-rich", "https://youtu.be/jNQXAC9IVRw?t=5", "Me at the zoo", true),
            ("ordinary-github", "https://github.com/scinfu/SwiftSoup", "SwiftSoup", false)
        ]
        for (name, address, expected, rich) in samples {
            let session = NotesEditorSession(note: try store.create(), store: store)
            let view = NotesContinuousTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), textContainer: nil)
            view.session = session; session.textView = view
            view.loadDocument(session.note)
            view.publish = { [weak view, weak session] in
                guard let view, let session,
                      let blocks = try? NotesContinuousDocument.blocks(from: view.attributedString(), scale: view.readingScale, trailingAttributes: view.trailingAttributes) else { return }
                session.updateBlocks(blocks)
            }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally(); view.linkPastes.cancelAll() }
            board.setString(address, forType: .string)
            if rich {
                let link = NSAttributedString(string: address, attributes: [.link: URL(string: address)!])
                let rtf = try link.data(from: NSRange(location: 0, length: link.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                board.setData(rtf, forType: .rtf)
            }
            let start = Date()
            try require(view.readSelection(from: board), name + " paste was rejected")
            try require(view.string == address, name + " URL was not inserted immediately")
            let deadline = Date().addingTimeInterval(30)
            while view.string == address && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let title = view.string
            try require(title.contains(expected), name + " unexpected title: " + title)
            let target = NotesWebLink.destination(from: view.attributedString().attribute(.link, at: 0, effectiveRange: nil))
            try require(target?.absoluteString == address, name + " lost its original target")
            try session.commit()
            let reopenedStore = try NotesStore(directory: root)
            guard let saved = reopenedStore.document(id: session.note.id) else { throw Failure(message: name + " could not reopen note") }
            let restored = NotesContinuousDocument.render(saved, scale: view.readingScale, width: 640)
            try require(restored.string == title, name + " title was not persisted")
            try require(NotesWebLink.destination(from: restored.attribute(.link, at: 0, effectiveRange: nil))?.absoluteString == address, name + " saved target changed")
            let result: [String: Any] = ["sample": name, "title": title, "destination": address,
                                         "rich": rich, "savedAndReopened": true, "seconds": Date().timeIntervalSince(start)]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
        print("LIVE LINK ACCEPTANCE COMPLETE")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
