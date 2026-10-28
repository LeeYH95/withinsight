import Combine
import Foundation
import LinkPresentation

@MainActor
enum NotesLinkMetadata {
    static func fetchTitle(for url: URL, completion: @escaping @MainActor (String?) -> Void) -> AnyCancellable {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.shouldFetchSubresources = false
        let request = Request(provider: provider)
        provider.startFetchingMetadata(for: url) { metadata, error in
            let title = error == nil ? NotesWebLink.normalizedTitle(metadata?.title) : nil
            Task { @MainActor in
                request.deliver(title, completion: completion)
            }
        }
        return AnyCancellable { request.cancel() }
    }
}

private final class Request: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: LPMetadataProvider?
    private var finished = false

    init(provider: LPMetadataProvider) {
        self.provider = provider
    }

    func cancel() {
        lock.lock()
        finished = true
        let provider = self.provider
        self.provider = nil
        lock.unlock()
        // LPMetadataProvider may invoke its completion when cancelled.
        provider?.cancel()
    }

    @MainActor func deliver(_ title: String?, completion: @MainActor (String?) -> Void) {
        lock.lock()
        let shouldDeliver = !finished
        finished = true
        provider = nil
        lock.unlock()
        if shouldDeliver { completion(title) }
    }
}
