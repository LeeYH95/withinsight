import Foundation
import XCTest
@testable import NotesCore

final class RecoveryJournalTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, NotesStore, NoteDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shipian-recovery-" + UUID().uuidString)
        let store = try NotesStore(directory: root.appendingPathComponent("store"))
        var note = try store.create(); note.title = "原始记录"; try store.update(note)
        return (root, store, store.document(id: note.id)!)
    }
    @MainActor private func checkpoint(_ note: NoteDocument, base: NoteDocument, store: NotesStore) throws -> NotesRecoveryJournal {
        let journal = try NotesRecoveryJournal(directory: store.directory)
        try journal.checkpoint(note, basedOn: base, attachmentSource: { try store.url(for: $0) })
        return journal
    }
    @MainActor func testAbandonedDraftRecoversAndIsConsumed() throws {
        let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = base; draft.title = "强退前刚输入"; draft.blocks[0].text = "中文正文 English"; draft.blocks[0].richText = Data("rtf-exact-bytes".utf8)
        var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
        let folder = journal!.location; journal = nil
        let reopened = try NotesStore(directory: store.directory)
        XCTAssertEqual(reopened.document(id: base.id)?.title, draft.title)
        XCTAssertEqual(reopened.document(id: base.id)?.blocks, draft.blocks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor func testLiveEditorJournalIsNotReplayedBySecondInstance() throws {
        let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = base; draft.title = "活跃编辑器中的文字"
        let journal = try checkpoint(draft, base: base, store: store)
        let second = try NotesStore(directory: store.directory)
        XCTAssertEqual(second.document(id: base.id)?.title, base.title)
        withExtendedLifetime(journal) {}
    }
    @MainActor func testDivergentCanonicalEditIsPreservedAsSeparateRecoveredDraft() throws {
        let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = base; draft.title = "待恢复输入"
        var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
        var latest = base; latest.title = "另一个实例的新内容"; try store.update(latest)
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        XCTAssertEqual(reopened.document(id: base.id)?.title, latest.title)
        let recovered = reopened.documents.filter { $0.id != base.id }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered.first?.title.hasPrefix(draft.title) == true)
        XCTAssertTrue(recovered.first?.draft == true); XCTAssertFalse(recovered.first?.onLine ?? true)
        _ = journal
    }
    @MainActor func testTrashAndPermanentDeletionDiscardStaleDraftsWithoutRecreatingNotes() throws {
        for permanentlyDelete in [false, true] {
            let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var draft = base; draft.blocks[0].text = "仍需找回的内容"
            var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
            try store.trash(base.id)
            if permanentlyDelete { try store.permanentlyDelete(base.id) }
            journal = nil
            let reopened = try NotesStore(directory: store.directory)
            if permanentlyDelete { XCTAssertNil(reopened.document(id: base.id)) }
            else { XCTAssertNotNil(reopened.document(id: base.id)?.deletedAt) }
            XCTAssertTrue(reopened.documents.filter { $0.id != base.id && $0.deletedAt == nil }.isEmpty)
            XCTAssertEqual(reopened.recoveredDraftCount, 0)
            _ = journal
        }
    }
    @MainActor func testReplayReceiptSurvivesCrashBeforeJournalConsumption() throws {
        let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = base; draft.title = "冲突恢复内容"
        var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
        let folder = journal!.location, copy = root.appendingPathComponent("saved-journal")
        try FileManager.default.copyItem(at: folder, to: copy)
        var latest = base; latest.title = "更新后的原记录"; try store.update(latest)
        journal = nil
        let first = try NotesStore(directory: store.directory)
        XCTAssertEqual(first.documents.count, 2)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: copy, to: folder)
        let second = try NotesStore(directory: store.directory)
        XCTAssertEqual(second.documents, first.documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    @MainActor func testCorruptDraftIsPreservedWithoutBlockingValidLibrary() throws {
        let (root, store, base) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = base; draft.title = "待恢复输入"
        var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
        let file = journal!.location.appendingPathComponent("draft.json")
        let broken = Data("incomplete draft".utf8); try broken.write(to: file); journal = nil
        let reopened = try NotesStore(directory: store.directory)
        XCTAssertEqual(reopened.documents, store.documents)
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    @MainActor func testMissingAttachmentIsRecoveredFromIndependentJournalCopy() throws {
        let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt"), bytes = Data("重要附件字节".utf8)
        try bytes.write(to: source)
        let attachment = try store.importAttachment(from: source, to: original.id)
        let base = store.document(id: original.id)!
        var draft = base; draft.title = "附件需要恢复"
        var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
        try FileManager.default.removeItem(at: store.url(for: attachment)); try FileManager.default.removeItem(at: source)
        journal = nil
        let reopened = try NotesStore(directory: store.directory)
        let recovered = try XCTUnwrap(reopened.document(id: base.id))
        XCTAssertEqual(recovered.title, draft.title)
        XCTAssertEqual(try Data(contentsOf: reopened.url(for: recovered.attachments[0])), bytes)
        _ = journal
    }
    @MainActor func testSharedAttachmentPathsRecoverWithoutDuplicateMetadataIDs() throws {
        for collision in [false, true] {
            let (root, store, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("shared.txt"), bytes = Data("shared original bytes".utf8)
            try bytes.write(to: file)
            let first = try store.importAttachment(from: file, to: original.id)
            var base = store.document(id: original.id)!
            var second = first; second.id = UUID(); second.name = "same-owned-file.txt"
            base.attachments.append(second); base.blocks.append(NoteBlock(kind: .file, text: second.name, attachmentID: second.id))
            try store.update(base); base = store.document(id: base.id)!
            var draft = base; draft.title = "共享附件后的新输入"
            var journal: NotesRecoveryJournal? = try checkpoint(draft, base: base, store: store)
            let changed = Data("newer external bytes".utf8)
            if collision { try changed.write(to: store.url(for: first)) }
            journal = nil
            let reopened = try NotesStore(directory: store.directory)
            let recovered = try XCTUnwrap(reopened.documents.first { $0.title.hasPrefix(draft.title) })
            XCTAssertEqual(Set(recovered.attachments.map(\.id)).count, 2)
            XCTAssertEqual(recovered.blocks.compactMap(\.attachmentID), base.blocks.compactMap(\.attachmentID))
            for asset in recovered.attachments { XCTAssertEqual(try Data(contentsOf: reopened.url(for: asset)), bytes) }
            if collision { XCTAssertEqual(try Data(contentsOf: reopened.url(for: first)), changed) }
            _ = journal
        }
    }
}
