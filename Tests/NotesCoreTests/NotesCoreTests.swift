import Foundation
import XCTest
@testable import NotesCore

final class NotesCoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("LineNotesTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    @MainActor
    func testNewNotesAreStoredAsDraftsOffLine() async throws {
        let store = try NotesStore(directory: temporaryDirectory())
        let note = try store.create()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.document(id: note.id)?.id, note.id)
        XCTAssertTrue(note.draft)
        XCTAssertFalse(note.onLine)
        XCTAssertEqual(note.paper, .blue)
        XCTAssertEqual(note.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(try store.create(template: .checklist).blocks.first?.kind, .checklist)
        XCTAssertTrue(try store.create(template: .image).attachments.isEmpty)
    }

    @MainActor
    func testRestartPreservesIdentityOrderedBlocksChecklistAndOpaqueRichText() async throws {
        let directory = try temporaryDirectory()
        let store = try NotesStore(directory: directory)
        var note = try store.create()
        note.title = "Research"
        note.paper = .lavender
        note.pinned = true
        note.blocks = [
            NoteBlock(text: "First", richText: Data([0, 1, 2, 255]), markdown: "**First**"),
            NoteBlock(kind: .checklist, text: "Finished", isChecked: true),
            NoteBlock(text: "Last")
        ]
        try store.update(note)
        try store.setOnLine(note.id, true)
        let saved = try XCTUnwrap(store.document(id: note.id))
        let restarted = try NotesStore(directory: directory)
        XCTAssertEqual(restarted.document(id: note.id), saved)
        XCTAssertEqual(restarted.document(id: note.id)?.blocks.map(\.text), ["First", "Finished", "Last"])
        XCTAssertEqual(restarted.document(id: note.id)?.plainText, "First\nFinished\nLast")
        XCTAssertFalse(saved.draft)
        XCTAssertEqual(restarted.saveState, .saved)
    }

    @MainActor
    func testTrashAndRestoreRecoverPreviousLineMembershipWithoutExpiring() async throws {
        let directory = try temporaryDirectory()
        let store = try NotesStore(directory: directory)
        let onLine = try store.create()
        let offLine = try store.create()
        try store.setOnLine(onLine.id, true)
        try store.trash(onLine.id)
        try store.trash(offLine.id)
        // Trashing twice must not replace the original membership with false.
        try store.trash(onLine.id)
        XCTAssertFalse(try XCTUnwrap(store.document(id: onLine.id)).onLine)
        XCTAssertEqual(store.search("", scope: .trash).count, 2)
        XCTAssertTrue(store.search("", scope: .all).isEmpty)
        let restarted = try NotesStore(directory: directory)
        try restarted.restore(onLine.id)
        try restarted.restore(offLine.id)
        XCTAssertTrue(try XCTUnwrap(restarted.document(id: onLine.id)).onLine)
        XCTAssertFalse(try XCTUnwrap(restarted.document(id: offLine.id)).onLine)
        XCTAssertNil(restarted.document(id: onLine.id)?.deletedAt)
    }

    @MainActor
    func testSearchMatchesTitleAndBlocksAndHonorsScopes() async throws {
        let store = try NotesStore(directory: temporaryDirectory())
        var note = try store.create()
        note.title = "Café Plan"
        note.blocks = [NoteBlock(text: "Shipment tomorrow")]
        try store.update(note)
        XCTAssertEqual(store.search("cafe").map(\.id), [note.id])
        XCTAssertEqual(store.search("SHIPMENT", scope: .offLine).map(\.id), [note.id])
        XCTAssertTrue(store.search("Shipment", scope: .onLine).isEmpty)
        try store.setOnLine(note.id, true)
        XCTAssertEqual(store.search("Shipment", scope: .onLine).map(\.id), [note.id])
    }

    @MainActor
    func testDuplicateCopiesAttachmentsIndependentlyAndRemovalPreservesSource() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("original image.png")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: source)
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let note = try store.create()
        let attachment = try store.importAttachment(from: source, to: note.id, at: 0)
        let originalURL = try store.url(for: attachment)
        XCTAssertNotEqual(originalURL, source)
        XCTAssertEqual(store.document(id: note.id)?.blocks.first?.attachmentID, attachment.id)
        let duplicate = try store.duplicate(note.id)
        let copied = try XCTUnwrap(duplicate.attachments.first)
        XCTAssertNotEqual(copied.id, attachment.id)
        XCTAssertNotEqual(copied.relativePath, attachment.relativePath)
        XCTAssertNotEqual(duplicate.blocks.first?.id, store.document(id: note.id)?.blocks.first?.id)
        XCTAssertEqual(duplicate.blocks.first?.attachmentID, copied.id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copied)), bytes)
        try store.removeAttachment(attachment.id, from: note.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: store.url(for: copied)), bytes)
        try store.trash(duplicate.id)
        try store.permanentlyDelete(duplicate.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: copied).path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    func testFailedSaveKeepsEditedMemoryAndOldDiskCopyAndCanRetry() async throws {
        let directory = try temporaryDirectory()
        let store = try NotesStore(directory: directory)
        var note = try store.create()
        let oldDisk = try Data(contentsOf: directory.appendingPathComponent("notes.json"))
        let moved = directory.appendingPathExtension("temporarily-moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        try Data("block writes".utf8).write(to: directory)
        note.title = "Unsaved work survives"
        XCTAssertThrowsError(try store.update(note))
        XCTAssertEqual(store.document(id: note.id)?.title, "Unsaved work survives")
        guard case .failed(let message) = store.saveState else { return XCTFail("Must expose a save failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("notes.json")), oldDisk)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        try store.flush()
        XCTAssertEqual(store.saveState, .saved)
        XCTAssertEqual(try NotesStore(directory: directory).document(id: note.id)?.title, "Unsaved work survives")
    }

    @MainActor
    func testPermanentDeleteDoesNotCleanFilesUntilSaveSucceeds() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("keep me".utf8).write(to: source)
        let dataDirectory = directory.appendingPathComponent("store")
        let store = try NotesStore(directory: dataDirectory)
        let note = try store.create()
        let attachment = try store.importAttachment(from: source, to: note.id)
        try store.trash(note.id)
        let database = dataDirectory.appendingPathComponent("notes.json")
        let backup = dataDirectory.appendingPathComponent("backup.json")
        let oldData = try Data(contentsOf: database)
        try FileManager.default.moveItem(at: database, to: backup)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.permanentlyDelete(note.id))
        XCTAssertNil(store.document(id: note.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(attachment.relativePath).path))
        XCTAssertEqual(try Data(contentsOf: backup), oldData)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: backup, to: database)
        try store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        XCTAssertEqual(try String(contentsOf: source), "keep me")
    }

    @MainActor
    func testCorruptStoreIsNeverSilentlyOverwritten() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("notes.json")
        let corrupt = Data("{ invalid json".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try NotesStore(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testRejectsTraversalRootAndSymlinksBeforeReadDeleteAndExport() async throws {
        let directory = try temporaryDirectory()
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let valuable = outside.appendingPathComponent("valuable.txt")
        try Data("external".utf8).write(to: valuable)
        for path in ["../outside/valuable.txt", "/tmp/x", ".", "attachments", "attachments/../notes.json", "attachments/../../outside", "attachments/"] {
            let attachment = NoteAttachment(name: "bad", relativePath: path, kind: .file, byteCount: 1)
            XCTAssertThrowsError(try store.url(for: attachment), path)
            var note = try store.create()
            note.attachments = [attachment]
            XCTAssertThrowsError(try store.update(note), path)
        }
        let attachments = store.directory.appendingPathComponent("attachments")
        let link = attachments.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let bad = NoteAttachment(name: "valuable", relativePath: "attachments/escape/valuable.txt", kind: .file, byteCount: 1)
        XCTAssertThrowsError(try store.url(for: bad))
        XCTAssertEqual(try String(contentsOf: valuable), "external")
    }

    @MainActor
    func testMarkdownExportKeepsOrderedFormattingAndPortableAttachmentCopy() async throws {
        let directory = try temporaryDirectory()
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        var note = try store.create()
        note.title = "Project"
        note.blocks = [NoteBlock(text: "Bold", markdown: "**Bold**"), NoteBlock(kind: .checklist, text: "Done", isChecked: true)]
        try store.update(note)
        let source = directory.appendingPathComponent("my [photo].png")
        let data = Data([4, 8, 12])
        try data.write(to: source)
        _ = try store.importAttachment(from: source, to: note.id)
        let export = directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let markdown = export.appendingPathComponent("Project (copy).md")
        try store.exportMarkdown(note.id, to: markdown)
        let text = try String(contentsOf: markdown)
        XCTAssertTrue(text.hasPrefix("# Project\n"))
        XCTAssertTrue(text.contains("**Bold**\n\n- [x] Done"))
        XCTAssertFalse(text.contains(store.directory.path))
        let range = try XCTUnwrap(text.range(of: #"!\[[^\n]*\]\(([^\n)]+)\)"#, options: .regularExpression))
        let image = String(text[range])
        let relative = try XCTUnwrap(image.split(separator: "(").last?.dropLast())
        let exportedImage = export.appendingPathComponent(String(relative).removingPercentEncoding ?? String(relative))
        XCTAssertEqual(try Data(contentsOf: exportedImage), data)
        let moved = directory.appendingPathComponent("portable")
        try FileManager.default.moveItem(at: export, to: moved)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(String(relative).removingPercentEncoding ?? String(relative))), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testMissingIDsThrowConsistentLocalizedErrors() async throws {
        let store = try NotesStore(directory: temporaryDirectory())
        let missing = UUID()
        var messages: [String] = []
        let operations: [() throws -> Void] = [
            { try store.setOnLine(missing, true) }, { try store.trash(missing) },
            { try store.restore(missing) }, { try store.permanentlyDelete(missing) },
            { _ = try store.duplicate(missing) }, { try store.update(NoteDocument(id: missing)) },
            { try store.removeAttachment(UUID(), from: missing) },
            { try store.exportMarkdown(missing, to: store.directory.appendingPathComponent("missing.md")) }
        ]
        for operation in operations {
            do { try operation(); XCTFail("Missing ID must throw") }
            catch {
                XCTAssertEqual(error as? NotesStoreError, .noteNotFound)
                messages.append(error.localizedDescription)
            }
        }
        XCTAssertEqual(Set(messages).count, 1)
        XCTAssertFalse(messages.first?.isEmpty ?? true)
    }

    @MainActor
    func testReplacingInternalAttachmentWithSymlinkBlocksDestructionAndExport() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("valuable.png")
        try Data("preserve original".utf8).write(to: source)
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let note = try store.create()
        let attachment = try store.importAttachment(from: source, to: note.id)
        let internalURL = try store.url(for: attachment)
        try store.trash(note.id)
        try FileManager.default.removeItem(at: internalURL)
        try FileManager.default.createSymbolicLink(at: internalURL, withDestinationURL: source)
        XCTAssertThrowsError(try store.url(for: attachment))
        XCTAssertThrowsError(try store.removeAttachment(attachment.id, from: note.id))
        XCTAssertThrowsError(try store.permanentlyDelete(note.id))
        XCTAssertThrowsError(try store.exportMarkdown(note.id, to: directory.appendingPathComponent("export.md")))
        XCTAssertNotNil(store.document(id: note.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("export.md").path))
        XCTAssertEqual(try String(contentsOf: source), "preserve original")
    }

    @MainActor
    func testSharedInternalFileSurvivesDeletionWhileAnotherNoteReferencesIt() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("shared".utf8).write(to: source)
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let first = try store.create()
        let attachment = try store.importAttachment(from: source, to: first.id)
        var second = try store.create()
        second.attachments = [attachment]
        second.blocks = [NoteBlock(kind: .file, text: attachment.name, attachmentID: attachment.id)]
        try store.update(second)
        try store.trash(first.id)
        try store.permanentlyDelete(first.id)
        XCTAssertEqual(try String(contentsOf: store.url(for: attachment)), "shared")
        try store.removeAttachment(attachment.id, from: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.url(for: attachment).path))
        XCTAssertEqual(try String(contentsOf: source), "shared")
    }

    @MainActor
    func testCaseAliasedAttachmentRemainsReadableAfterOtherNoteIsDeleted() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("case alias survives".utf8).write(to: source)
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let first = try store.create()
        let attachment = try store.importAttachment(from: source, to: first.id)
        var alias = attachment
        alias.id = UUID()
        alias.relativePath = attachment.relativePath.lowercased()
        let originalURL = try store.url(for: attachment)
        let aliasURL = try store.url(for: alias)
        guard FileManager.default.fileExists(atPath: aliasURL.path) else {
            throw XCTSkip("This temporary volume uses case-sensitive filenames")
        }
        let originalIdentity = try originalURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let aliasIdentity = try aliasURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        guard let originalIdentity, let aliasIdentity, originalIdentity.isEqual(aliasIdentity) else {
            throw XCTSkip("Case variants do not identify the same file on this volume")
        }
        var second = try store.create()
        second.attachments = [alias]
        second.blocks = [NoteBlock(kind: .file, text: alias.name, attachmentID: alias.id)]
        try store.update(second)
        try store.trash(first.id)
        try store.permanentlyDelete(first.id)
        XCTAssertEqual(try String(contentsOf: store.url(for: alias)), "case alias survives")
        let restarted = try NotesStore(directory: store.directory)
        XCTAssertEqual(try String(contentsOf: restarted.url(for: XCTUnwrap(restarted.document(id: second.id)?.attachments.first))), "case alias survives")
        try store.removeAttachment(alias.id, from: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try String(contentsOf: source), "case alias survives")
    }

    @MainActor
    func testCleanupProtectsActualFileIdentityUntilLastReferenceIsRemoved() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.txt")
        try Data("same inode".utf8).write(to: source)
        let store = try NotesStore(directory: directory.appendingPathComponent("store"))
        let first = try store.create()
        let attachment = try store.importAttachment(from: source, to: first.id)
        var alias = attachment
        alias.id = UUID()
        alias.relativePath = "attachments/another-internal-name.txt"
        let originalURL = try store.url(for: attachment)
        let aliasURL = try store.url(for: alias)
        try FileManager.default.linkItem(at: originalURL, to: aliasURL)
        var second = try store.create()
        second.attachments = [alias]
        second.blocks = [NoteBlock(kind: .file, text: alias.name, attachmentID: alias.id)]
        try store.update(second)
        try store.trash(first.id)
        try store.permanentlyDelete(first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path), "An actual file identity still referenced by another note must be retained")
        XCTAssertEqual(try String(contentsOf: aliasURL), "same inode")
        try store.removeAttachment(alias.id, from: second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasURL.path))
    }

    func testDisplayTitleUsesOnlyTrimmedExplicitTitleOrApprovedFallback() {
        XCTAssertEqual(NoteDocument(title: "  \n ").displayTitle, "未命名闪念")
        XCTAssertEqual(NoteDocument(blocks: [NoteBlock(text: "\n  First idea\nMore details")]).displayTitle, "未命名闪念")
        XCTAssertEqual(NoteDocument(title: "  Explicit title  ").displayTitle, "Explicit title")
    }
}
