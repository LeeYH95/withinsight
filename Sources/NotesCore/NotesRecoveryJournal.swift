import Foundation
import CryptoKit
import Darwin

/// An editor's durable draft. The lifetime lock prevents a second running app
/// from recovering an editor which is still alive. Deinit never deletes a draft.
public final class NotesRecoveryJournal {
    public let location: URL
    private let storeDirectory: URL
    private let owner: Int32
    private let sessionID: UUID
    private let recoveredNoteID = UUID()
    private var cachedAssets: [String: RecoveryAsset] = [:]

    public init(directory: URL) throws {
        storeDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let paths = NotesStorePaths(directory: storeDirectory)
        try paths.validateStoreRoot()
        let root = storeDirectory.appendingPathComponent("recovery", isDirectory: true)
        try Self.ensureDirectory(root, paths: paths)
        sessionID = UUID()
        location = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try Self.ensureDirectory(location, paths: paths)
        owner = try Self.lockOwner(at: location, create: true)
    }

    deinit { flock(owner, LOCK_UN); Darwin.close(owner) }

    public func checkpoint(_ document: NoteDocument, basedOn base: NoteDocument,
                           attachmentSource: (NoteAttachment) throws -> URL) throws {
        try NotesStoreLock.withLock(directory: storeDirectory) {
            let paths = NotesStorePaths(directory: storeDirectory)
            try paths.validate(document); try paths.validate(base)
            guard document.id == base.id else { throw NotesStoreError.invalidStore }
            try paths.rejectSymlink(at: location)
            var assets: [RecoveryAsset] = []
            for attachment in document.attachments {
                if assets.contains(where: { $0.path == attachment.relativePath }) { continue }
                if let cached = cachedAssets[attachment.relativePath] {
                    assets.append(cached); continue
                }
                let source = try attachmentSource(attachment)
                guard let info = try paths.metadata(at: source), info.st_mode & S_IFMT == S_IFREG else { throw NotesStoreError.attachmentNotFound }
                let target = try Self.assetURL(attachment.relativePath, in: location, paths: paths)
                try Self.ensureDirectory(target.deletingLastPathComponent(), paths: paths)
                let data = try Data(contentsOf: source)
                try Self.write(data, to: target, paths: paths)
                let asset = RecoveryAsset(path: attachment.relativePath, sha256: Self.hash(data), size: data.count)
                cachedAssets[attachment.relativePath] = asset
                assets.append(asset)
            }
            let record = RecoveryRecord(version: 1, sessionID: sessionID, revisionID: UUID(), recoveredNoteID: recoveredNoteID,
                                        base: base, document: document, assets: assets)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try Self.write(encoder.encode(record), to: location.appendingPathComponent("draft.json"), paths: paths)
            // Publish the replacement before collecting bytes belonging to the
            // previous draft. A failed write must leave that draft recoverable.
            cachedAssets = Dictionary(uniqueKeysWithValues: assets.map { ($0.path, $0) })
            try pruneAssets(keeping: assets, paths: paths)
        }
    }

    /// Keep the owner lock file until this editor dies; later edits reuse it.
    public func clear() throws {
        try NotesStoreLock.withLock(directory: storeDirectory) {
            let draft = location.appendingPathComponent("draft.json")
            let paths = NotesStorePaths(directory: storeDirectory)
            try paths.rejectSymlink(at: draft)
            if FileManager.default.fileExists(atPath: draft.path) { try FileManager.default.removeItem(at: draft) }
            cachedAssets.removeAll()
            try pruneAssets(keeping: [], paths: paths)
        }
    }

    private func pruneAssets(keeping assets: [RecoveryAsset], paths: NotesStorePaths) throws {
        let files = FileManager.default
        let root = location.appendingPathComponent("attachments", isDirectory: true)
        try paths.rejectSymlink(at: root)
        guard files.fileExists(atPath: root.path) else { return }
        let retained = try Set(assets.map { asset -> String in
            let url = try Self.assetURL(asset.path, in: location, paths: paths)
            guard let info = try paths.metadata(at: url), info.st_mode & S_IFMT == S_IFREG else { throw NotesStoreError.unsafePath }
            return "\(info.st_dev):\(info.st_ino)"
        })
        func prune(_ folder: URL) throws {
            guard let info = try paths.metadata(at: folder), info.st_mode & S_IFMT == S_IFDIR else { throw NotesStoreError.unsafePath }
            for child in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                try paths.rejectSymlink(at: child)
                guard let info = try paths.metadata(at: child) else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: try prune(child)
                case S_IFREG:
                    // Case aliases can name the same file on the local volume.
                    if !retained.contains("\(info.st_dev):\(info.st_ino)") { try files.removeItem(at: child) }
                default: throw NotesStoreError.unsafePath
                }
            }
            if try files.contentsOfDirectory(atPath: folder.path).isEmpty { try files.removeItem(at: folder) }
        }
        try prune(root)
    }

    static func abandoned(in directory: URL) -> (drafts: [AbandonedDraft], warnings: [String]) {
        let paths = NotesStorePaths(directory: directory)
        let root = directory.appendingPathComponent("recovery", isDirectory: true)
        var drafts: [AbandonedDraft] = [], warnings: [String] = []
        do {
            try paths.rejectSymlink(at: root)
            guard FileManager.default.fileExists(atPath: root.path) else { return ([], []) }
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
                do {
                    try paths.rejectSymlink(at: folder)
                    guard let info = try paths.metadata(at: folder), info.st_mode & S_IFMT == S_IFDIR else { throw NotesStoreError.unsafePath }
                    let descriptor: Int32
                    do { descriptor = try lockOwner(at: folder, create: false) }
                    catch NotesStoreError.storeBusy { continue }
                    let handle = AbandonedDraft(location: folder, owner: descriptor)
                    let file = folder.appendingPathComponent("draft.json")
                    try paths.rejectSymlink(at: file)
                    guard FileManager.default.fileExists(atPath: file.path) else {
                        try handle.consume(); continue
                    }
                    let record = try JSONDecoder().decode(RecoveryRecord.self, from: Data(contentsOf: file))
                    guard record.version == 1, record.sessionID.uuidString == folder.lastPathComponent,
                          record.document.id == record.base.id,
                          Set(record.assets.map(\.path)).count == record.assets.count,
                          Set(record.assets.map(\.path)) == Set(record.document.attachments.map(\.relativePath)) else { throw NotesStoreError.invalidStore }
                    try paths.validate(record.document); try paths.validate(record.base)
                    handle.record = record
                    // Validate every owned byte before exposing any recovered note.
                    for asset in record.assets { _ = try handle.data(for: asset, paths: paths) }
                    drafts.append(handle)
                } catch { warnings.append("一份恢复副本暂时无法读取，原文件已保留：" + folder.lastPathComponent + "。" + error.localizedDescription) }
            }
        } catch { warnings.append("恢复目录无法读取，原文件已保留。" + error.localizedDescription) }
        return (drafts, warnings)
    }

    fileprivate static func assetURL(_ path: String, in folder: URL, paths: NotesStorePaths) throws -> URL {
        _ = try paths.safeAttachmentURL(path)
        var url = folder
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part)); try paths.rejectSymlink(at: url)
        }
        return url
    }
    private static func ensureDirectory(_ url: URL, paths: NotesStorePaths) throws {
        try paths.rejectSymlink(at: url)
        if let info = try paths.metadata(at: url) {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw NotesStoreError.unsafePath }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private static func lockOwner(at folder: URL, create: Bool) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let fd = Darwin.open(folder.appendingPathComponent("owner.lock").path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw NotesStoreError.storeBusy }
        return fd
    }
    fileprivate static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ data: Data, to url: URL, paths: NotesStorePaths) throws {
        try paths.rejectSymlink(at: url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

struct RecoveryAsset: Codable {
    let path: String
    let sha256: String
    let size: Int
}

struct RecoveryRecord: Codable {
    let version: Int
    let sessionID: UUID
    let revisionID: UUID
    let recoveredNoteID: UUID
    let base: NoteDocument
    var document: NoteDocument
    let assets: [RecoveryAsset]
}

final class AbandonedDraft {
    let location: URL
    private let owner: Int32
    var record: RecoveryRecord!
    init(location: URL, owner: Int32) { self.location = location; self.owner = owner }
    deinit { flock(owner, LOCK_UN); Darwin.close(owner) }
    func data(for asset: RecoveryAsset, paths: NotesStorePaths) throws -> Data {
        let url = try NotesRecoveryJournal.assetURL(asset.path, in: location, paths: paths)
        guard let info = try paths.metadata(at: url), info.st_mode & S_IFMT == S_IFREG else { throw NotesStoreError.unsafePath }
        let data = try Data(contentsOf: url)
        guard data.count == asset.size, NotesRecoveryJournal.hash(data) == asset.sha256 else { throw NotesStoreError.invalidStore }
        return data
    }
    func consume() throws { try FileManager.default.removeItem(at: location) }
}
