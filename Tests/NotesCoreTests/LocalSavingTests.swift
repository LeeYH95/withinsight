import Foundation
import XCTest
@testable import NotesCore

final class LocalSavingTests: XCTestCase {
    @MainActor func testEstablishedLibraryWithMissingMainFileIsNotRecreatedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-missing-local-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root)
        _ = try store.create()
        let file = root.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try NotesStore(directory: root)) { XCTAssertEqual($0 as? NotesStoreError, .invalidStore) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testDeletedNotesDoNotRecreateOwnedFilesFromStaleRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-disposable-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(directory: root.appendingPathComponent("library"))
        let note = try store.create()
        let original = root.appendingPathComponent("disposable.txt")
        try Data("一次性附件".utf8).write(to: original)
        let attachment = try store.importAttachment(from: original, to: note.id)
        let base = try XCTUnwrap(store.document(id: note.id))
        var draft = base; draft.title = "已决定删除的内容"
        var journal: NotesRecoveryJournal? = try NotesRecoveryJournal(directory: store.directory)
        try journal!.checkpoint(draft, basedOn: base, attachmentSource: { try store.url(for: $0) })
        let temporary = journal!.location
        try store.trash(note.id); try store.permanentlyDelete(note.id)
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        XCTAssertTrue(reopened.documents.isEmpty)
        XCTAssertEqual(reopened.recoveredDraftCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try reopened.url(for: attachment).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    @MainActor func testLocalSaveReopenAndDeletionDoNotCreateArchives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-local-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("library")
        let store = try NotesStore(directory: directory)
        var keep = try store.create()
        keep.title = "继续写的灵感"
        keep.blocks = [NoteBlock(text: "本地保存的正文")]
        try store.update(keep)
        let disposable = try store.create()
        try store.trash(disposable.id)
        try store.permanentlyDelete(disposable.id)
        let reopened = try await NotesStore.open(directory: directory)
        XCTAssertEqual(reopened.documents, store.documents)
        XCTAssertEqual(reopened.document(id: keep.id)?.plainText, "本地保存的正文")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library Backups").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library Backup Captures").path))
    }

    @MainActor func testDeletingAnAttachmentNeedsOnlyTheLocalLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-local-attachment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("library")
        let store = try NotesStore(directory: directory)
        let note = try store.create()
        let original = root.appendingPathComponent("original.txt")
        let bytes = Data("附件原文".utf8)
        try bytes.write(to: original)
        let attachment = try store.importAttachment(from: original, to: note.id)
        let owned = try store.url(for: attachment)
        // Historical archive paths must no longer participate in normal saving.
        for suffix in [" Backups", " Backup Captures"] {
            let old = root.appendingPathComponent("library" + suffix)
            if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
            try Data("旧路径不可用".utf8).write(to: old)
        }
        try store.removeAttachment(attachment.id, from: note.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertTrue(try NotesStore(directory: directory).document(id: note.id)?.attachments.isEmpty == true)
    }
}
