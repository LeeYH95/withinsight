import Foundation
import Darwin

enum NotesStoreLock {
    static func withLock<T>(directory: URL, _ body: () throws -> T) throws -> T {
        try NotesStorePaths(directory: directory).validateStoreRoot()
        let lock = directory.appendingPathComponent(".notes-write.lock")
        let fd = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NotesStoreError.storeBusy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
