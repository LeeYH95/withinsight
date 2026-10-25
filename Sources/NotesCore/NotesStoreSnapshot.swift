import Foundation
import Darwin

struct NotesStoreFile: Codable {
    var version: Int = 1
    var documents: [NoteDocument]
    var recoveredDraftIDs: [UUID]?
}

struct NotesStoreSnapshot: Sendable {
    let directory: URL
    let documents: [NoteDocument]
    let savedData: Data?
    let recoveredDraftIDs: [UUID]
    static func read(directory: URL, readFile: @Sendable (URL) throws -> Data) throws -> NotesStoreSnapshot {
        guard directory.isFileURL else { throw NotesStoreError.unsafePath }
        let requestedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let files = FileManager.default
        try files.createDirectory(at: requestedDirectory, withIntermediateDirectories: true)
        // Foundation can canonicalize an alias only after its new leaf exists.
        // Validate and retain that same canonical root for all subsequent I/O.
        let directory = requestedDirectory.resolvingSymlinksInPath()
        let paths = NotesStorePaths(directory: directory)
        try paths.validateStoreRoot()
        let store = directory.appendingPathComponent("notes.json")
        try paths.rejectSymlink(at: store)
        var documents: [NoteDocument] = []
        var savedData: Data?
        var recoveredDraftIDs: [UUID] = []
        if files.fileExists(atPath: store.path) {
            let data = try readFile(store)
            savedData = data
            let decoded: NotesStoreFile
            do { decoded = try JSONDecoder().decode(NotesStoreFile.self, from: data) }
            catch { throw NotesStoreError.invalidStore }
            guard decoded.version == 1, Set(decoded.documents.map(\.id)).count == decoded.documents.count else { throw NotesStoreError.invalidStore }
            for document in decoded.documents { try paths.validate(document) }
            documents = decoded.documents
            recoveredDraftIDs = decoded.recoveredDraftIDs ?? []
        } else if try hasExistingLocalData(directory: directory, paths: paths) {
            // A missing database in an established library is data loss, not a
            // request to create an empty one. Preserve the existing local files.
            throw NotesStoreError.invalidStore
        }
        let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
        try paths.rejectSymlink(at: attachments)
        if files.fileExists(atPath: attachments.path) {
            guard let info = try paths.metadata(at: attachments), info.st_mode & S_IFMT == S_IFDIR else { throw NotesStoreError.unsafePath }
        } else { try files.createDirectory(at: attachments, withIntermediateDirectories: false) }
        return NotesStoreSnapshot(directory: directory, documents: documents, savedData: savedData, recoveredDraftIDs: recoveredDraftIDs)
    }

    private static func hasExistingLocalData(directory: URL, paths: NotesStorePaths) throws -> Bool {
        let files = FileManager.default
        let marker = directory.appendingPathComponent(".notes-write.lock")
        try paths.rejectSymlink(at: marker)
        if files.fileExists(atPath: marker.path) { return true }
        let locations: [(URL, (String) -> Bool)] = [
            (directory.appendingPathComponent("recovery"), { UUID(uuidString: $0) != nil }),
            (directory.appendingPathComponent("attachments"), { !$0.hasPrefix(".") })
        ]
        for (folder, matches) in locations {
            try paths.rejectSymlink(at: folder)
            guard files.fileExists(atPath: folder.path) else { continue }
            if try files.contentsOfDirectory(atPath: folder.path).contains(where: matches) { return true }
        }
        return false
    }
}

struct NotesStorePaths {
    let directory: URL
    func validate(_ note: NoteDocument) throws {
        guard Set(note.attachments.map(\.id)).count == note.attachments.count,
              Set(note.blocks.map(\.id)).count == note.blocks.count else { throw NotesStoreError.invalidStore }
        for attachment in note.attachments { _ = try safeAttachmentURL(attachment.relativePath) }
    }

    func validateStoreRoot() throws {
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw NotesStoreError.unsafePath }
        guard let info = try metadata(at: directory), info.st_mode & S_IFMT == S_IFDIR else { throw NotesStoreError.unsafePath }
    }

    /// lstat reads only inode metadata. FileManager.attributesOfItem also
    /// fetches unrelated extended attributes, which can block startup on a
    /// File Provider-backed folder. Never follow links for ownership checks.
    func metadata(at url: URL) throws -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return info
    }

    func rejectSymlink(at url: URL) throws {
        if let info = try metadata(at: url), info.st_mode & S_IFMT == S_IFLNK {
            throw NotesStoreError.unsafePath
        }
    }

    func safeAttachmentURL(_ relativePath: String) throws -> URL {
        try validateStoreRoot()
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.first == "attachments",
              !relativePath.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NotesStoreError.unsafePath
        }
        var candidate = directory
        for component in components {
            candidate.appendPathComponent(component)
            try rejectSymlink(at: candidate)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(directory.path + "/attachments/") else { throw NotesStoreError.unsafePath }
        return candidate
    }

}
