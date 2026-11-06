import Combine
import Foundation
import LinkPresentation

@MainActor
enum NotesLinkMetadata {
    static func fetchTitle(for url: URL, completion: @escaping @MainActor (String?) -> Void) -> AnyCancellable {
        fetchTitle(for: url, session: NotesLinkTitleResolver.session, completion: completion)
    }

    static func fetchTitle(for url: URL, session: URLSession, completion: @escaping @MainActor (String?) -> Void) -> AnyCancellable {
        let request = Request()
        let task = Task {
            let title = await NotesLinkTitleResolver.title(for: url, session: session)
            guard !Task.isCancelled else { return }
            if let title {
                request.deliver(title, completion: completion)
                return
            }
            // A video metadata failure must not replace its URL with a channel
            // name returned by the system provider.
            if NotesLinkTitleResolver.youtubeEndpoint(for: url) != nil {
                request.deliver(nil, completion: completion)
                return
            }
            let provider = LPMetadataProvider()
            provider.timeout = 8
            provider.shouldFetchSubresources = false
            guard request.attach(provider) else { return }
            provider.startFetchingMetadata(for: url) { metadata, error in
                let title = error == nil ? NotesLinkTitleResolver.usableTitle(metadata?.title) : nil
                Task { @MainActor in request.deliver(title, completion: completion) }
            }
        }
        request.attach(task)
        return AnyCancellable { request.cancel() }
    }
}

private final class Request: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: LPMetadataProvider?
    private var task: Task<Void, Never>?
    private var finished = false

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        let stopped = finished
        if !stopped { self.task = task }
        lock.unlock()
        if stopped { task.cancel() }
    }

    func attach(_ provider: LPMetadataProvider) -> Bool {
        lock.lock()
        let stopped = finished
        if !stopped { self.provider = provider }
        lock.unlock()
        return !stopped
    }

    func cancel() {
        lock.lock()
        finished = true
        let provider = provider, task = task
        self.provider = nil; self.task = nil
        lock.unlock()
        task?.cancel()
        provider?.cancel()
    }

    @MainActor func deliver(_ title: String?, completion: @MainActor (String?) -> Void) {
        lock.lock()
        let shouldDeliver = !finished
        finished = true
        provider = nil; task = nil
        lock.unlock()
        if shouldDeliver { completion(title) }
    }
}
