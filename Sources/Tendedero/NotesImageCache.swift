import AppKit
import ImageIO
import SwiftUI

/// Attachment files are immutable copies with UUID paths. Cache their decoded
/// pixels without touching File Provider or decoding on a view update.
@MainActor final class NotesImageCache: ObservableObject {
    static let shared = NotesImageCache()
    static let thumbnails = NotesImageCache { NotesImageDecoder.read($0, maximumPixelSize: 640) }
    @Published private(set) var revision = 0
    private let loader: @Sendable (URL) -> NSImage?
    private let images = NSCache<NSURL, NSImage>()
    private var pending: Set<URL> = []
    private var failed: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<NSImage?, Never>]] = [:]
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LineNotes.attachment-images"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    init(loader: @escaping @Sendable (URL) -> NSImage? = { NotesImageDecoder.read($0) }) {
        self.loader = loader
        images.totalCostLimit = 64 * 1024 * 1024
        images.countLimit = 32
    }
    func image(at url: URL) -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        guard !pending.contains(url), !failed.contains(url) else { return nil }
        pending.insert(url)
        let loader = loader
        Self.queue.addOperation { [weak self] in
            let image = autoreleasepool { loader(url) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending.remove(url)
                if let image {
                    let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
                    self.images.setObject(image, forKey: url as NSURL, cost: pixels)
                } else { self.failed.insert(url) }
                let waiting = self.waiters.removeValue(forKey: url) ?? []
                waiting.forEach { $0.resume(returning: image) }
                self.revision &+= 1
            }
        }
        return nil
    }
    /// A view keeps its result while visible, so cache eviction cannot cause a
    /// global revision -> render -> reload feedback loop between library cards.
    func loadedImage(at url: URL) async -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if failed.contains(url) { return nil }
        return await withCheckedContinuation { continuation in
            waiters[url, default: []].append(continuation)
            _ = image(at: url)
        }
    }
    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }
    func retry(_ url: URL) {
        failed.remove(url)
        _ = image(at: url)
        revision &+= 1
    }
}

enum NotesImageDecoder {
    static func read(_ url: URL, maximumPixelSize: Int = 2048) -> NSImage? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let representation = NSBitmapImageRep(cgImage: bitmap)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
