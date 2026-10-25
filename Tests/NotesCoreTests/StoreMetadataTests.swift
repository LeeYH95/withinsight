import Foundation
import XCTest
@testable import NotesCore

final class StoreMetadataTests: XCTestCase {
    @MainActor func testFirstOpenCreatesCanonicalStoreUnderTemporaryDirectoryAlias() async throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Shipian-first-open-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let location = parent.appendingPathComponent("new-store", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        let store = try await NotesStore.open(directory: location)
        XCTAssertEqual(store.directory.path, location.resolvingSymlinksInPath().path)
        let note = try store.create()
        let reopened = try await NotesStore.open(directory: location)
        XCTAssertEqual(reopened.documents.map(\.id), [note.id])
    }

    @MainActor func testRestartRejectsSymbolicLinkReplacingInternalAttachment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LineNotes-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("keep original".utf8).write(to: source)
        let location = root.appendingPathComponent("store")
        let store = try NotesStore(directory: location)
        let note = try store.create()
        let attachment = try store.importAttachment(from: source, to: note.id)
        let internalURL = try store.url(for: attachment)
        try FileManager.default.removeItem(at: internalURL)
        try FileManager.default.createSymbolicLink(at: internalURL, withDestinationURL: source)
        XCTAssertThrowsError(try NotesStore(directory: location)) { error in
            XCTAssertEqual(error as? NotesStoreError, .unsafePath)
        }
        XCTAssertEqual(try String(contentsOf: source), "keep original")
    }
}
