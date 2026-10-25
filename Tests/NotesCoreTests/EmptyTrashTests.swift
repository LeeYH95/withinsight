import Foundation
import XCTest
@testable import NotesCore

final class EmptyTrashTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, NotesStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-empty-trash-" + UUID().uuidString)
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, store)
    }

    @MainActor func testBatchDeletionPersistsAndKeepsLiveNotesAndOriginalFiles() throws {
        let (root, store) = try fixture()
        var keep = try store.create(); keep.title = "保留的灵感"; try store.update(keep)
        keep = try XCTUnwrap(store.document(id: keep.id))
        let first = try store.create(), second = try store.create()
        let original = root.appendingPathComponent("original.txt"), bytes = Data("原始附件".utf8)
        try bytes.write(to: original)
        let attachment = try store.importAttachment(from: original, to: first.id)
        try store.trash(first.id); try store.trash(second.id)

        XCTAssertEqual(try store.emptyTrash([first.id, second.id, keep.id]), [first.id, second.id])
        XCTAssertEqual(store.documents.map(\.id), [keep.id])
        XCTAssertEqual(try NotesStore(directory: store.directory).documents, store.documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(store.document(id: keep.id), keep)
    }

    @MainActor func testConfirmationIDsDoNotIncludeNewTrashAndSkipRestoredNotes() throws {
        let (_, store) = try fixture()
        let first = try store.create(), restored = try store.create(), newer = try store.create()
        try store.trash(first.id); try store.trash(restored.id)
        let confirmed = Set(store.search("", scope: .trash).map(\.id))
        try store.restore(restored.id); try store.trash(newer.id)

        XCTAssertEqual(try store.emptyTrash(confirmed), [first.id])
        XCTAssertNil(store.document(id: first.id))
        XCTAssertNil(store.document(id: restored.id)?.deletedAt)
        XCTAssertNotNil(store.document(id: newer.id)?.deletedAt)
    }

    @MainActor func testEmptyOrStaleRequestDoesNotWrite() throws {
        let (_, store) = try fixture()
        let note = try store.create()
        let file = store.directory.appendingPathComponent("notes.json")
        let before = try Data(contentsOf: file)
        XCTAssertTrue(try store.emptyTrash([]).isEmpty)
        XCTAssertTrue(try store.emptyTrash([UUID(), note.id]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(store.saveState, .saved)
    }

    @MainActor func testSharedAttachmentIsKeptUntilLastReferenceIsDeleted() throws {
        let (root, store) = try fixture()
        let keep = try store.create(), remove = try store.create()
        let source = root.appendingPathComponent("shared.txt"), bytes = Data("共享的内部附件".utf8)
        try bytes.write(to: source)
        let attachment = try store.importAttachment(from: source, to: keep.id)
        var second = remove
        second.attachments = [attachment]
        second.blocks = [NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id)]
        try store.update(second); try store.trash(remove.id)

        _ = try store.emptyTrash([remove.id])
        XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), bytes)
        try store.trash(keep.id)
        _ = try store.emptyTrash([keep.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testFailedPrimarySavePreservesVisibleTrashAndOwnedBytes() throws {
        let (root, store) = try fixture()
        let first = try store.create(), second = try store.create()
        let source = root.appendingPathComponent("source.txt")
        try Data("不能先删".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: first.id)
        try store.trash(first.id); try store.trash(second.id)
        let before = store.documents, file = store.directory.appendingPathComponent("notes.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.emptyTrash([first.id, second.id]))
        XCTAssertEqual(store.documents, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        XCTAssertEqual(try store.emptyTrash([first.id, second.id]), [first.id, second.id])
        XCTAssertTrue(try NotesStore(directory: store.directory).documents.isEmpty)
    }

    @MainActor func testUnsafeAttachmentAbortsWholeBatchBeforeMutation() throws {
        let (root, store) = try fixture()
        let first = try store.create(), second = try store.create()
        let source = root.appendingPathComponent("source.txt")
        try Data("原始文件保留".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: second.id)
        try store.trash(first.id); try store.trash(second.id)
        let owned = try store.url(for: attachment), before = store.documents
        let saved = try Data(contentsOf: store.directory.appendingPathComponent("notes.json"))
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: source)
        XCTAssertThrowsError(try store.emptyTrash([first.id, second.id]))
        XCTAssertEqual(store.documents, before)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("notes.json")), saved)
        XCTAssertEqual(try String(contentsOf: source), "原始文件保留")
    }

    @MainActor func testConcurrentStoreChangeRejectsBatchWithoutOverwritingNewerData() throws {
        let (_, store) = try fixture()
        let note = try store.create(); try store.trash(note.id)
        let other = try NotesStore(directory: store.directory)
        let createdElsewhere = try other.create()
        let file = store.directory.appendingPathComponent("notes.json"), newerData = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.emptyTrash([note.id])) { XCTAssertEqual($0 as? NotesStoreError, .storeChanged) }
        XCTAssertNotNil(store.document(id: note.id))
        XCTAssertEqual(try Data(contentsOf: file), newerData)
        XCTAssertNotNil(try NotesStore(directory: store.directory).document(id: createdElsewhere.id))
    }

    @MainActor func testAttachmentCleanupFailureDoesNotResurrectCommittedTrash() throws {
        let (root, store) = try fixture()
        let note = try store.create(), source = root.appendingPathComponent("source.txt")
        try Data("删除完成后清理".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: note.id)
        try store.trash(note.id)
        let folder = store.directory.appendingPathComponent("attachments")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try store.emptyTrash([note.id]))
        XCTAssertNil(store.document(id: note.id))
        XCTAssertNil(try NotesStore(directory: store.directory).document(id: note.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
    }

    @MainActor func testStaleRecoveryCannotResurrectBulkDeletedNoteOrAttachment() throws {
        let (root, store) = try fixture()
        let note = try store.create()
        let source = root.appendingPathComponent("source.txt")
        try Data("一次性资料".utf8).write(to: source)
        let attachment = try store.importAttachment(from: source, to: note.id)
        let base = try XCTUnwrap(store.document(id: note.id))
        var draft = base; draft.title = "遗留恢复内容"
        var journal: NotesRecoveryJournal? = try NotesRecoveryJournal(directory: store.directory)
        try journal!.checkpoint(draft, basedOn: base, attachmentSource: { try store.url(for: $0) })
        let location = journal!.location
        try store.trash(note.id); _ = try store.emptyTrash([note.id]); journal = nil

        let reopened = try NotesStore(directory: store.directory)
        XCTAssertTrue(reopened.documents.isEmpty)
        XCTAssertEqual(reopened.recoveredDraftCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
    }
}
