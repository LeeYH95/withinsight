import Foundation
import XCTest
@testable import NotesCore

final class ConcurrentStoreTests: XCTestCase {
    @MainActor func testStaleWriterCannotOverwriteAnotherStoresSavedNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-writers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try NotesStore(directory: root)
        var original = try first.create()
        original.title = "原始记录"; try first.update(original)
        let stale = try NotesStore(directory: root)
        var saved = try first.create()
        saved.title = "另一个实例已保存的重要记录"; try first.update(saved)
        let disk = try Data(contentsOf: root.appendingPathComponent("notes.json"))
        var edit = original; edit.title = "旧实例的未保存编辑"
        XCTAssertThrowsError(try stale.update(edit), "A stale process must report a conflict rather than erase newly saved notes")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes.json")), disk)
        XCTAssertEqual(stale.document(id: original.id)?.title, edit.title, "The losing writer keeps edits in memory for export")
        XCTAssertEqual(try NotesStore(directory: root).document(id: saved.id)?.title, saved.title)
    }

    @MainActor func testExternallyChangedOrRemovedStoreIsNotSilentlyRecreated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-external-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        _ = try store.create()
        let file = root.appendingPathComponent("notes.json")
        let saved = try Data(contentsOf: file)
        try Data("external damaged data".utf8).write(to: file)
        XCTAssertThrowsError(try store.flush())
        XCTAssertEqual(try Data(contentsOf: file), Data("external damaged data".utf8))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.flush())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try saved.write(to: file)
        XCTAssertNoThrow(try store.flush(), "Restoring the same saved snapshot permits a retry")
    }

    @MainActor func testConflictingAttachmentRemovalCannotCleanSavedAttachmentBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-conflict-attachment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try NotesStore(directory: root)
        let note = try first.create()
        let source = root.appendingPathComponent("source.txt")
        try Data("important attachment".utf8).write(to: source)
        let attachment = try first.importAttachment(from: source, to: note.id)
        let stale = try NotesStore(directory: root)
        _ = try first.create()
        XCTAssertThrowsError(try stale.removeAttachment(attachment.id, from: note.id))
        XCTAssertEqual(try Data(contentsOf: first.url(for: attachment)), Data("important attachment".utf8))
        XCTAssertEqual(try NotesStore(directory: root).document(id: note.id)?.attachments, [attachment])
    }

    @MainActor func testKeepingSharedAttachmentDoesNotLeavePhantomUnsavedChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-shared-clean-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        let first = try store.create()
        let source = root.appendingPathComponent("source.txt")
        try Data("shared bytes".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: first.id)
        var second = try store.create()
        second.attachments = [attachment]
        second.blocks = [NoteBlock(kind: .file, attachmentID: attachment.id)]
        try store.update(second)
        try store.removeAttachment(attachment.id, from: first.id)
        XCTAssertFalse(store.hasPendingChanges, "A retained referenced file is not unsaved content and must not block clean quit")
        XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), Data("shared bytes".utf8))
    }
}
