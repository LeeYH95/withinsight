import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "local.linenotes.dev", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id: UUID
    var noteID: UUID? = nil
    var noteTitle: String?
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt: Double
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { noteID == nil && Tendedero.isRecording(url) }

    init(url: URL, thumb: NSImage, noteID: UUID? = nil, id: UUID = UUID()) {
        self.id = id; self.url = url; self.thumb = thumb; self.noteID = noteID
        self.tilt = Double.random(in: -2.5...2.5)
    }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

struct ScreenshotClearBatch {
    let id = UUID()
    let items: [Pegged]
    let targets: [Pegged]
    let scroll: CGFloat
    let visibleCount: Int
    var targetIDs: Set<UUID> { Set(targets.map(\.id)) }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    @Published var selectedNoteID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false
    @Published private(set) var screenshotClear: ScreenshotClearBatch?
    @Published private(set) var screenshotClearUndoCount = 0
    let screenshotSweep = ScreenshotSweepMotion()
    var onClearScreenshots: ((ScreenshotClearBatch) -> Void)?
    private var clearedScreenshots: [Pegged] = []
    private var screenshotClearUndo: (items: [Pegged], order: [UUID], scroll: CGFloat)?

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let initialOrder: [String]
    private let defaults: UserDefaults
    private let inboxFolder: URL?

    init(restoring: Bool = true, gusts: Bool = true, defaults: UserDefaults = LaunchOptions.lineDefaults,
         inboxFolder: URL? = nil) {
        self.defaults = defaults
        self.inboxFolder = inboxFolder
        initialOrder = defaults.stringArray(forKey: "mixedLineOrder") ?? []
        if restoring { restore() }
        if gusts { scheduleGust() }
    }

    var onTakeOffNote: ((UUID) -> Bool)?
    @discardableResult
    func hangNote(_ id: UUID, thumbnail: NSImage, title: String? = nil, quietly: Bool = false) -> UUID? {
        if let index = items.firstIndex(where: { $0.noteID == id }) {
            let wasFalling = items[index].falling
            items[index].thumb = thumbnail
            items[index].noteTitle = title
            items[index].falling = false
            if wasFalling { save() }
            return id
        }
        items.append(Pegged(url: URL(string: "linenotes-note://\(id.uuidString)")!,
                            thumb: thumbnail, noteID: id, id: id))
        items[items.count - 1].noteTitle = title
        scroll = 0
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return id
    }

    func updateNote(_ id: UUID, thumbnail: NSImage) {
        guard let index = items.firstIndex(where: { $0.noteID == id && !$0.falling }) else { return }
        items[index].thumb = thumbnail
    }

    var onOpenNote: ((UUID) -> Void)?
    var onCopyNote: ((UUID) -> Void)?
    var onDuplicateNote: ((UUID) -> Void)?
    var onExportNote: ((UUID) -> Void)?
    var onDeleteNote: ((UUID) -> Void)?
    var onNewNote: ((String) -> Void)?
    var onShowNotes: (() -> Void)?
    var noteDragURL: ((UUID) -> URL?)?

    func removeNote(_ id: UUID) { drop(id, quietly: true) }
    var screenshotCount: Int { items.filter { $0.noteID == nil && !$0.falling }.count }
    var clearableScreenshotCount: Int { items.filter { $0.noteID == nil && !$0.isRecording && !$0.falling }.count }

    func acceptsPointer(at point: CGPoint) -> Bool {
        if hitRects.values.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) { return true }
        guard items.count > visibleCount else { return false }
        // Only cards define the scrolling strip. Controls and the undo banner
        // remain individually clickable without blocking the desktop beside them.
        let band = items.filter { !$0.falling }.compactMap { hitRects[$0.id] }.reduce(CGRect.null) { $0.union($1) }
        return !band.isNull && point.y >= band.minY - 4 && point.y <= band.maxY + 4
    }

    /// Both the view and screen-space falling renderer use the same frozen slots.
    func hangingX(for id: UUID, width: CGFloat) -> CGFloat {
        let original = screenshotClear?.items ?? items
        let newcomers = items.filter { candidate in !original.contains { $0.id == candidate.id } }
        guard let index = original.firstIndex(where: { $0.id == id })
            ?? newcomers.firstIndex(where: { $0.id == id }).map({ original.count + $0 }) else { return width / 2 }
        return Layout.x(index: index, count: original.count, width: max(300, width - Layout.controlsWidth),
                        visible: screenshotClear?.visibleCount ?? visibleCount,
                        scroll: screenshotClear?.scroll ?? scroll)
    }

    func move(_ id: UUID, before destination: UUID) {
        move(id, relativeTo: destination, after: false)
    }

    func move(_ id: UUID, after destination: UUID) {
        move(id, relativeTo: destination, after: true)
    }

    private func move(_ id: UUID, relativeTo destination: UUID, after: Bool) {
        guard screenshotClear == nil, id != destination, let from = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == destination }) else { return }
        let item = items.remove(at: from)
        let target = items.firstIndex(where: { $0.id == destination })!
        items.insert(item, at: target + (after ? 1 : 0))
        save()
    }

    func restoreOrdering() {
        let saved = initialOrder
        let order = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let original = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        items.sort { (order[orderKey($0)] ?? (saved.count + original[$0.id, default: 0]))
            < (order[orderKey($1)] ?? (saved.count + original[$1.id, default: 0])) }
        save()
    }

    private func orderKey(_ item: Pegged) -> String {
        item.noteID.map { "note:\($0.uuidString)" } ?? "image:\(item.url.path)"
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if screenshotClear == nil, screenshotCount > maxItems, let oldest = items.first(where: { $0.noteID == nil && !$0.falling }) {
            letGo(oldest.id)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false, animated: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        if animated { onFall?(items[i]) }
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.screenshotClear?.targetIDs.contains(id) != true else { return }
            self.items.removeAll { $0.id == id && $0.falling }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// This operation only changes rope membership, including inbox images.
    /// Commit the whole snapshot before animation so interruption is deterministic.
    @discardableResult
    func beginScreenshotClear() -> ScreenshotClearBatch? {
        guard screenshotClear == nil else { return nil }
        let targets = items.filter { $0.noteID == nil && !$0.isRecording && !$0.falling }
        guard !targets.isEmpty else { return nil }
        let batch = ScreenshotClearBatch(items: items, targets: targets, scroll: scroll, visibleCount: visibleCount)
        screenshotClearUndo = nil
        screenshotClearUndoCount = 0
        clearedScreenshots = []
        screenshotClear = batch
        save()
        return batch
    }

    func requestScreenshotClear() {
        guard let batch = beginScreenshotClear() else { return }
        if let onClearScreenshots { onClearScreenshots(batch) }
        else { finishScreenshotClear(batch.id) }
    }

    func releaseScreenshot(_ id: UUID, in batchID: UUID, animated: Bool = true) {
        guard let batch = screenshotClear, batch.id == batchID, batch.targetIDs.contains(id),
              let item = items.first(where: { $0.id == id && !$0.falling && $0.noteID == nil }) else { return }
        clearedScreenshots.append(item)
        drop(id, quietly: true, animated: animated)
    }

    func finishScreenshotClear(_ id: UUID) {
        guard let batch = screenshotClear, batch.id == id else { return }
        for target in batch.targets { releaseScreenshot(target.id, in: id, animated: false) }
        items.removeAll { batch.targetIDs.contains($0.id) }
        screenshotClearUndo = (clearedScreenshots, batch.items.map(\.id), batch.scroll)
        screenshotClearUndoCount = clearedScreenshots.count
        clearedScreenshots = []
        screenshotClear = nil
        scroll = min(scroll, CGFloat(max(0, items.count - visibleCount)) * Layout.spacing)
        save()
    }

    @discardableResult
    func undoScreenshotClear() -> Int {
        guard screenshotClear == nil, let undo = screenshotClearUndo else { return 0 }
        let order = Dictionary(uniqueKeysWithValues: undo.order.enumerated().map { ($1, $0) })
        var restored = 0
        for var item in undo.items.sorted(by: { order[$0.id, default: 0] < order[$1.id, default: 0] }) {
            guard FileManager.default.fileExists(atPath: item.url.path),
                  !items.contains(where: { !$0.falling && ($0.id == item.id || $0.url == item.url) }) else { continue }
            items.removeAll { $0.id == item.id && $0.falling }
            item.falling = false; item.flying = false
            let rank = order[item.id, default: 0]
            if let after = items.firstIndex(where: { order[$0.id].map { $0 > rank } ?? false }) {
                items.insert(item, at: after)
            } else if let before = items.lastIndex(where: { order[$0.id].map { $0 < rank } ?? false }) {
                items.insert(item, at: before + 1)
            } else { items.insert(item, at: 0) }
            restored += 1
        }
        screenshotClearUndo = nil
        screenshotClearUndoCount = 0
        scroll = min(undo.scroll, CGFloat(max(0, items.count - visibleCount)) * Layout.spacing)
        save()
        return restored
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from Tendedero's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound.
    private func takeDown(_ live: [Pegged]) {
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where item.noteID == nil && !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onCopyNote?(noteID); return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onOpenNote?(noteID); return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onDeleteNote?(noteID); return false }
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.noteID == nil else { return false }
        return item.url.standardizedFileURL.path.hasPrefix((inboxFolder ?? Inbox.folder).standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        if let noteID = items.first(where: { $0.id == id })?.noteID {
            guard onTakeOffNote?(noteID) ?? true else { return }
            drop(id, quietly: quietly)
            return
        }
        if isInInbox(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Tendedero's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        guard screenshotClear == nil else { return }
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        guard screenshotClear == nil else { return }
        while screenshotCount > maxItems, let oldest = items.first(where: { $0.noteID == nil && !$0.falling }) {
            letGo(oldest.id)
        }
        scroll = 0
    }

    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true) { return }
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard items.first(where: { $0.id == id })?.noteID == nil else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onOpenNote?(noteID); return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onOpenNote?(noteID); return }
        let live = items.filter { $0.noteID == nil && !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where items[i].noteID == nil && !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        if let noteID = items.first(where: { $0.id == id })?.noteID { onOpenNote?(noteID); return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let excluded = screenshotClear?.targetIDs ?? []
        let saved = items.filter { !$0.falling && !excluded.contains($0.id) }
        defaults.set(saved.map(orderKey), forKey: "mixedLineOrder")
        defaults.set(saved.filter { $0.noteID == nil }.map(\.url.path), forKey: storeKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    func restorePhotos(paths: [String]? = nil,
                       loader: @escaping @Sendable (URL) -> NSImage? = { makeThumbnail($0) }) async {
        let saved = paths ?? defaults.stringArray(forKey: storeKey) ?? []
        // File Provider and recording thumbnails may take an arbitrary amount
        // of time. The startup window must still be able to repaint or cancel.
        let photos = await Task.detached(priority: .userInitiated) {
            var seen: Set<String> = []
            return saved.compactMap { path -> RestoredLinePhoto? in
                guard seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                guard let image = autoreleasepool(invoking: { loader(url) }) else { return nil }
                return RestoredLinePhoto(url: url, image: image)
            }
        }.value
        for photo in photos where !items.contains(where: { $0.url == photo.url }) {
            items.append(Pegged(url: photo.url, thumb: photo.image))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// The worker exclusively builds each image before handing it to the main
// actor. No image is read or mutated concurrently after this handoff.
private struct RestoredLinePhoto: @unchecked Sendable {
    let url: URL
    let image: NSImage
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
