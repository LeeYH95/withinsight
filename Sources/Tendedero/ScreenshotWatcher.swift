import Foundation
import CoreServices

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Tendedero never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    enum ImageSource { case screenshots, folder, airDrop }

    let folder: URL
    private let imageSource: ImageSource
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// Screen recordings carry no tag, so they are only picked up in
    /// Tendedero's own folder, where nothing else is saved.
    private let acceptsRecordings: Bool
    private var known: Set<String>?
    private var waitingForAirDropMetadata: [String: TimeInterval] = [:]
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
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the system capture folder, a user-selected image folder, or
    /// the new AirDrop images in Downloads.
    init(folder: URL? = nil, imageSource: ImageSource = .screenshots,
         onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.imageSource = imageSource
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

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(self.folder.path, O_EVTONLY)
            DispatchQueue.main.async { self.watch(fd) }
        }
    }

    /// Starts watching, then reads the folder. The watcher is live before the
    /// listing begins, so a capture that lands in between is not lost.
    private func watch(_ fd: Int32) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            NSLog("Tendedero: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
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
        missed = false
        waitingForAirDropMetadata.removeAll()
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (retryAirDropOnly ? 0.5 : 0.2), execute: work)
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
        let previous = known
        let waiting = waitingForAirDropMetadata
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let files = retryAirDropOnly
                ? waiting.keys.map { URL(fileURLWithPath: $0) }
                : self.listFolder()
            let seen = retryAirDropOnly ? nil : Set(files.map(\.path))
            let result: (images: [URL], waiting: [String: TimeInterval])
            if self.imageSource == .airDrop {
                result = self.airDropArrivals(in: files, previouslySeen: previous, waiting: waiting)
            } else {
                let base = previous ?? Set(files.filter { self.creationDate($0) < self.launchDate }.map(\.path))
                result = (files.filter { !base.contains($0.path) && self.isCandidate($0) }, [:])
            }
            DispatchQueue.main.async { self.adopt(seen, result.images, waiting: result.waiting) }
        }
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func adopt(_ seen: Set<String>?, _ candidates: [URL], waiting: [String: TimeInterval]) {
        listing = false
        guard !stopped else { return }
        for url in candidates { onNew(url) }
        if let seen {
            let first = known == nil
            known = seen
            if !first { onChange() }
        }
        waitingForAirDropMetadata = waiting
        if missed {
            missed = false
            refresh()
        } else if !waiting.isEmpty, pending == nil {
            scheduleScan(retryAirDropOnly: true)
        }
    }

    private func airDropArrivals(in files: [URL], previouslySeen: Set<String>?, waiting: [String: TimeInterval])
        -> (images: [URL], waiting: [String: TimeInterval]) {
        let now = ProcessInfo.processInfo.systemUptime
        var images: [URL] = []
        var stillWaiting: [String: TimeInterval] = [:]
        for url in files where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            let path = url.path
            let deadline = waiting[path]
            guard deadline.map({ $0 > now }) ?? (previouslySeen?.contains(path) != true),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .quarantinePropertiesKey, .addedToDirectoryDateKey
                  ]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            let metadata = values.quarantineProperties
            let type = metadata?[kLSQuarantineTypeKey as String] as? String
            if let type, type != "LSQuarantineTypeAirDrop" { continue }
            if type == "LSQuarantineTypeAirDrop", let received = metadata?[kLSQuarantineTimeStampKey as String] as? Date {
                // AirDrop preserves the photo's creation date. Quarantine records
                // the receive time with second-level precision.
                if received.timeIntervalSince1970 >= floor(launchDate.timeIntervalSince1970) {
                    images.append(url)
                }
            } else if deadline != nil || previouslySeen != nil ||
                        (values.addedToDirectoryDate ?? .distantPast) >= launchDate {
                // The directory can report an arrival before its source is set.
                // Retry just this path for a few seconds, without relisting Downloads.
                stillWaiting[path] = deadline ?? now + 5
            }
        }
        return (images, stillWaiting)
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
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
