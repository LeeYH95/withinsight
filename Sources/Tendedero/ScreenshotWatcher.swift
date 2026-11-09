import Foundation
import CoreServices

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    enum ImageSource { case screenshots, folder, airDrop }
    enum Availability: Equatable { case connecting, listening, unavailable }

    private struct FileVersion: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func == (left: Self, right: Self) -> Bool {
            left.device == right.device && left.inode == right.inode && left.size == right.size
                && left.modified.tv_sec == right.modified.tv_sec && left.modified.tv_nsec == right.modified.tv_nsec
        }
    }

    private struct AirDropScan {
        var files: [String: FileVersion]
        var waiting: [String: TimeInterval] = [:]
        var arrivals: [(url: URL, version: FileVersion)] = []
    }

    let folder: URL
    private let imageSource: ImageSource
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// Screen recordings carry no tag, so they are only picked up in
    /// Tendedero's own folder, where nothing else is saved.
    private let acceptsRecordings: Bool
    private var known: Set<String>?
    private var knownAirDropFiles: [String: FileVersion]?
    private var waitingForAirDrop: [String: TimeInterval] = [:]
    private let launchDate: Date
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// A `start()` that is still waiting on the folder, off the main thread.
    private var starting = false
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A capture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while one of the two was still pending.
    private var stopped = false
    private var generation = 0
    private var availability: Availability?
    private let onNew: (URL) -> Void
    private let onChange: () -> Void
    private let onAirDropImage: ((URL) -> Bool)?
    private let onAvailability: ((Availability) -> Void)?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the system capture folder, a user-selected image folder, or
    /// the new AirDrop images in Downloads.
    init(folder: URL? = nil, imageSource: ImageSource = .screenshots,
         since: Date = Date(), onAirDropImage: ((URL) -> Bool)? = nil,
         onAvailability: ((Availability) -> Void)? = nil,
         onNew: @escaping (URL) -> Void = { _ in }, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.imageSource = imageSource
        launchDate = since
        self.onAirDropImage = onAirDropImage
        self.onAvailability = onAvailability
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = imageSource == .screenshots
            && self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path
        acceptsRecordings = imageSource != .airDrop
            && self.folder.standardizedFileURL.path == Inbox.folder.standardizedFileURL.path
    }

    static func screenshotFolder() -> URL {
        let fm = FileManager.default
        // Read fresh through cfprefsd: inbox mode changes this value at runtime.
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let domain = "com.apple.screencapture" as CFString
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The folder is opened off the main thread, because `open()` blocks while
    /// macOS asks whether Tendedero may look inside it. On the Desktop that is
    /// the consent prompt, and it waits for an answer. Asking from
    /// `applicationDidFinishLaunching` meant the app had not finished launching
    /// while that was pending: no status item appeared, and the signal sources
    /// that put the screenshot settings back never ran.
    func start() {
        stopped = false
        guard source == nil, !starting else { return }
        starting = true
        if availability == nil { setAvailability(.connecting) }
        let request = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(self.folder.path, O_EVTONLY)
            let error = fd < 0 ? errno : 0
            DispatchQueue.main.async {
                guard self.generation == request else {
                    if fd >= 0 { close(fd) }
                    return
                }
                self.watch(fd, error: error)
            }
        }
    }

    /// Starts watching, then reads the folder. The watcher is live before the
    /// listing begins, so a capture that lands in between is not lost.
    private func watch(_ fd: Int32, error: Int32) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            if imageSource == .airDrop {
                reconnect(error: error)
            } else {
                NSLog("Tendedero: cannot watch \(folder.path)")
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        let request = generation
        src.setEventHandler { [weak self] in
            guard let self, self.generation == request, let source = self.source else { return }
            if self.imageSource == .airDrop, !source.data.intersection([.rename, .delete]).isEmpty {
                self.reconnect(error: ENOENT)
            } else {
                self.scheduleScan()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        refresh()
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, and a listing that lands
    /// afterwards is dropped.
    func stop() {
        stopped = true
        waitingForAirDrop.removeAll()
        availability = nil
        cancelWork()
    }

    private func cancelWork() {
        generation += 1
        starting = false
        listing = false
        missed = false
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func setAvailability(_ state: Availability) {
        guard imageSource == .airDrop, availability != state else { return }
        availability = state
        onAvailability?(state)
    }

    private func reconnect(error: Int32) {
        if availability != .unavailable { NSLog("拾片 AirDrop 下载目录暂不可用 (\(error))") }
        cancelWork()
        setAvailability(.unavailable)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending = nil
            self.start()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func scheduleScan(retryAirDropOnly: Bool = false) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.refresh(retryAirDropOnly: retryAirDropOnly)
        }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + (retryAirDropOnly ? 1 : 0.2), execute: work)
    }

    /// Reads the folder off the main thread. Sorting by creation date and
    /// reading it back costs one filesystem call per file, and this folder can
    /// be the Desktop, so none of it belongs on the main thread.
    private func refresh(retryAirDropOnly: Bool = false) {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        let request = generation
        let previous = known
        let previousAirDropFiles = knownAirDropFiles
        let waiting = waitingForAirDrop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.imageSource == .airDrop {
                do {
                    let files = try retryAirDropOnly
                        ? waiting.keys.map { URL(fileURLWithPath: $0) } : self.listFolder()
                    let scan = self.scanAirDrop(files, previous: previousAirDropFiles, waiting: waiting, retryOnly: retryAirDropOnly)
                    DispatchQueue.main.async {
                        guard self.generation == request else { return }
                        self.adoptAirDrop(scan, fullScan: !retryAirDropOnly)
                    }
                } catch {
                    let code = (error as NSError).code
                    DispatchQueue.main.async {
                        guard self.generation == request else { return }
                        self.reconnect(error: Int32(clamping: code))
                    }
                }
            } else {
                let files = (try? self.listFolder()) ?? []
                let base = previous ?? Set(files.filter { self.creationDate($0) < self.launchDate }.map(\.path))
                let candidates = files.filter { !base.contains($0.path) && self.isCandidate($0) }
                let seen = Set(files.map(\.path))
                DispatchQueue.main.async {
                    guard self.generation == request else { return }
                    for url in candidates { self.onNew(url) }
                    if self.known != nil { self.onChange() }
                    self.known = seen
                    self.finishScan()
                }
            }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func finishScan() {
        listing = false
        guard !stopped else { return }
        if missed {
            missed = false
            refresh()
        } else if !waitingForAirDrop.isEmpty, pending == nil {
            scheduleScan(retryAirDropOnly: true)
        }
    }

    private func scanAirDrop(_ files: [URL], previous: [String: FileVersion]?,
                             waiting: [String: TimeInterval], retryOnly: Bool) -> AirDropScan {
        let now = ProcessInfo.processInfo.systemUptime
        var scan = AirDropScan(files: retryOnly ? previous ?? [:] : [:])
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) || ext == "heif" || ext == "dng",
                  let version = FileVersion(url) else { continue }
            let path = url.path
            scan.files[path] = version
            let changed = previous?[path] != version
            guard changed || waiting[path] != nil else { continue }
            let deadline = changed ? now + 60 : waiting[path] ?? now + 60
            guard deadline > now else { continue }

            let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey, .addedToDirectoryDateKey])
            let metadata = values?.quarantineProperties
            let received = metadata?[kLSQuarantineTimeStampKey as String] as? Date
            if metadata?[kLSQuarantineTypeKey as String] as? String == "LSQuarantineTypeAirDrop",
               let received, received.timeIntervalSince1970 >= floor(launchDate.timeIntervalSince1970) {
                scan.arrivals.append((url, version))
                scan.waiting[path] = deadline
            } else if previous != nil || (values?.addedToDirectoryDate ?? .distantPast) >= launchDate {
                // A new file can gain or change its source marker after the
                // directory event. Until then it must not be treated as AirDrop.
                scan.waiting[path] = deadline
            }
        }
        return scan
    }

    private func adoptAirDrop(_ scan: AirDropScan, fullScan: Bool) {
        let first = knownAirDropFiles == nil
        knownAirDropFiles = scan.files
        waitingForAirDrop = scan.waiting
        for (url, version) in scan.arrivals where FileVersion(url) == version {
            let accepted: Bool
            if let onAirDropImage {
                accepted = onAirDropImage(url)
            } else {
                onNew(url)
                accepted = true
            }
            if accepted { waitingForAirDrop.removeValue(forKey: url.path) }
        }
        if fullScan {
            setAvailability(.listening)
            if !first { onChange() }
        }
        finishScan()
    }

    private func listFolder() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        if isRecording(url) { return acceptsRecordings }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? isScreenCapture(url) : true
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
