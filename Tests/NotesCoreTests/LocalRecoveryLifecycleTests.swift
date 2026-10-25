import Foundation
import XCTest
@testable import NotesCore

final class LocalRecoveryLifecycleTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, NotesStore, NoteDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-local-recovery-" + UUID().uuidString)
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        let note = try store.create()
        return (root, store, note)
    }

    private func withAttachment(_ attachment: NoteAttachment, in base: NoteDocument) -> NoteDocument {
        var document = base
        document.attachments = [attachment]
        document.blocks = [NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id)]
        return document
    }

    @MainActor func testSuccessfulSaveClearsDraftAndOwnedTemporaryBytesButKeepsLiveSessionReusable() throws {
        let (root, store, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), bytes = Data("latest local content".utf8)
        try bytes.write(to: source)
        let attachment = try store.importAttachment(from: source, to: base.id)
        let document = try XCTUnwrap(store.document(id: base.id))
        let journal = try NotesRecoveryJournal(directory: store.directory)
        try journal.checkpoint(document, basedOn: document, attachmentSource: { try store.url(for: $0) })
        try store.update(document)
        try journal.clear()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journal.location.path), ["owner.lock"])
        XCTAssertEqual(try Data(contentsOf: store.url(for: attachment)), bytes)
        var next = document; next.title = "next edit"
        try journal.checkpoint(next, basedOn: document, attachmentSource: { try store.url(for: $0) })
        XCTAssertEqual(try Data(contentsOf: journal.location.appendingPathComponent(attachment.relativePath)), bytes,
                       "Clearing must invalidate the asset cache so the next draft contains its own readable bytes")
        XCTAssertTrue(NotesRecoveryJournal.abandoned(in: store.directory).drafts.isEmpty,
                      "The session owner lock must still prevent another instance from replaying a live editor")
    }

    @MainActor func testRepeatedAttachmentReplacementKeepsOnlyCurrentDraftAssets() throws {
        let (root, store, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var journal: NotesRecoveryJournal? = try NotesRecoveryJournal(directory: store.directory)
        let location = journal!.location
        var latest = base
        for index in 0..<8 {
            let name = "replacement-\(index).txt", bytes = Data("replacement bytes \(index)".utf8)
            let source = root.appendingPathComponent(name)
            try bytes.write(to: source)
            let attachment = NoteAttachment(name: name, relativePath: "attachments/" + name, kind: .file, byteCount: bytes.count)
            latest = withAttachment(attachment, in: base)
            try journal!.checkpoint(latest, basedOn: base, attachmentSource: { _ in source })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.appendingPathComponent("attachments").path), [name])
            XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent(attachment.relativePath)), bytes)
        }
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        XCTAssertEqual(reopened.document(id: base.id)?.attachments, latest.attachments)
        XCTAssertEqual(reopened.document(id: base.id)?.blocks, latest.blocks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    }

    @MainActor func testFailedCheckpointRetainsPreviousDraftAndItsAttachmentForRecovery() throws {
        let (root, store, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("previous.txt"), bytes = Data("previous unsaved content".utf8)
        try bytes.write(to: source)
        let attachment = NoteAttachment(name: "previous.txt", relativePath: "attachments/previous.txt", kind: .file, byteCount: bytes.count)
        let previous = withAttachment(attachment, in: base)
        var journal: NotesRecoveryJournal? = try NotesRecoveryJournal(directory: store.directory)
        try journal!.checkpoint(previous, basedOn: base, attachmentSource: { _ in source })
        let location = journal!.location, draftFile = location.appendingPathComponent("draft.json")
        let previousDraftBytes = try Data(contentsOf: draftFile)
        let missing = NoteAttachment(name: "missing.txt", relativePath: "attachments/missing.txt", kind: .file, byteCount: 1)
        let replacement = withAttachment(missing, in: base)

        XCTAssertThrowsError(try journal!.checkpoint(replacement, basedOn: base, attachmentSource: { _ in root.appendingPathComponent("not-present") }))
        XCTAssertEqual(try Data(contentsOf: draftFile), previousDraftBytes)
        XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent(attachment.relativePath)), bytes)
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        let recovered = try XCTUnwrap(reopened.document(id: base.id))
        XCTAssertEqual(recovered.attachments, previous.attachments)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: recovered.attachments[0])), bytes)
    }

    @MainActor func testFailedAtomicDraftWriteDoesNotCollectPreviousAssets() throws {
        let (root, store, base) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("previous.txt"), bytes = Data("previous draft bytes".utf8)
        try bytes.write(to: source)
        let attachment = NoteAttachment(name: "previous.txt", relativePath: "attachments/previous.txt", kind: .file, byteCount: bytes.count)
        let previous = withAttachment(attachment, in: base)
        var journal: NotesRecoveryJournal? = try NotesRecoveryJournal(directory: store.directory)
        try journal!.checkpoint(previous, basedOn: base, attachmentSource: { _ in source })
        let location = journal!.location, draftFile = location.appendingPathComponent("draft.json")
        let previousDraftBytes = try Data(contentsOf: draftFile)
        var replacement = base; replacement.title = "replacement without the old file"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: location.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.path) }
        XCTAssertThrowsError(try journal!.checkpoint(replacement, basedOn: base, attachmentSource: { _ in source }))
        XCTAssertEqual(try Data(contentsOf: draftFile), previousDraftBytes)
        XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent(attachment.relativePath)), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.path)
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        let recovered = try XCTUnwrap(reopened.document(id: base.id))
        XCTAssertEqual(recovered.attachments, previous.attachments)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: recovered.attachments[0])), bytes)
    }
}
