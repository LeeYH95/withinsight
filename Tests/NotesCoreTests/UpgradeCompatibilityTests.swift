import Foundation
import XCTest
@testable import NotesCore

final class UpgradeCompatibilityTests: XCTestCase {
    @MainActor func testLegacySnapshotWithoutEditorPaperKeepsAllContentAndAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-upgrade-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        var note = try store.create()
        note.title = "旧版本数据"; note.blocks = [NoteBlock(text: "正文", richText: Data([1, 2, 3])), NoteBlock(kind: .checklist, text: "待办", isChecked: true)]
        try store.update(note)
        let source = root.appendingPathComponent("source.txt")
        try Data("附件原文".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: note.id)
        let expected = store.document(id: note.id)!
        let file = root.appendingPathComponent("notes.json")
        var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var documents = snapshot["documents"] as! [[String: Any]]
        documents[0].removeValue(forKey: "editorPaper")
        snapshot["documents"] = documents
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let reopened = try NotesStore(directory: root)
        XCTAssertEqual(reopened.document(id: note.id), expected)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: attachment)), Data("附件原文".utf8))
        try reopened.flush()
        XCTAssertEqual(try NotesStore(directory: root).document(id: note.id), expected)
    }

    @MainActor func testUnsupportedFutureVersionIsRejectedWithoutChangingAnyBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-future-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.json")
        let content = Data("{\"version\":999,\"documents\":[]}".utf8)
        try content.write(to: file)
        XCTAssertThrowsError(try NotesStore(directory: root)) { XCTAssertEqual($0 as? NotesStoreError, .invalidStore) }
        XCTAssertEqual(try Data(contentsOf: file), content)
    }
}
