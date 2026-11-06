import Combine
import Foundation
import XCTest
@testable import Tendedero

final class LinkMetadataResolverTests: XCTestCase {
    func testHTMLMetadataPriorityEntitiesAndChinese() throws {
        let url = URL(string: "https://example.com/article")!
        let html = """
        <html><head><title>普通标题</title>
        <meta property='OG:TITLE' content='  灵感 &amp; 图文 &#x4F60;&#x597D;  '>
        <meta name='twitter:title' content='备用标题'></head></html>
        """
        XCTAssertEqual(try NotesLinkTitleResolver.htmlTitle(in: Data(html.utf8), url: url), "灵感 & 图文 你好")
        XCTAssertEqual(try NotesLinkTitleResolver.htmlTitle(in: Data("<meta property='og:title' content=''><meta name='twitter:title' content='备用'><title>网页</title>".utf8), url: url), "备用")
        XCTAssertEqual(try NotesLinkTitleResolver.htmlTitle(in: Data("<title>独立网页</title>".utf8), url: url), "独立网页")
    }

    func testWeChatArticleHeadingAndVerificationTitles() throws {
        let url = URL(string: "https://mp.weixin.qq.com/s/article")!
        XCTAssertEqual(try NotesLinkTitleResolver.htmlTitle(in: Data("<title>微信公众平台</title><h1 id='activity-name'>真实文章标题</h1>".utf8), url: url), "真实文章标题")
        for title in ["环境异常", "安全验证", "微信公众平台", "YouTube", "Just a moment..."] {
            XCTAssertNil(try NotesLinkTitleResolver.htmlTitle(in: Data("<title>\(title)</title>".utf8), url: url))
        }
    }

    func testYouTubeVideoFormsUseTheSameFirstPartyEndpoint() throws {
        let id = "jNQXAC9IVRw"
        for raw in ["https://www.youtube.com/watch?v=\(id)&t=5", "https://youtu.be/\(id)?si=test", "https://m.youtube.com/watch?v=\(id)", "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/live/\(id)", "https://www.youtube-nocookie.com/embed/\(id)"] {
            let endpoint = try XCTUnwrap(NotesLinkTitleResolver.youtubeEndpoint(for: URL(string: raw)!))
            let parts = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "www.youtube.com")
            XCTAssertEqual(parts.path, "/oembed")
            XCTAssertEqual(parts.queryItems?.first { $0.name == "url" }?.value, "https://www.youtube.com/watch?v=" + id)
        }
        for raw in ["https://www.youtube.com/@jawed", "https://youtube.com.evil.example/watch?v=\(id)", "https://youtu.be/short", "https://example.com/watch?v=\(id)"] {
            XCTAssertNil(NotesLinkTitleResolver.youtubeEndpoint(for: URL(string: raw)!))
        }
    }

    func testOEmbedUsesVideoTitleAndNeverAuthorName() {
        let data = Data(#"{"type":"video","title":"Me at the zoo","author_name":"jawed"}"#.utf8)
        XCTAssertEqual(NotesLinkTitleResolver.oEmbedTitle(in: data), "Me at the zoo")
        XCTAssertNil(NotesLinkTitleResolver.oEmbedTitle(in: Data(#"{"type":"video","author_name":"jawed"}"#.utf8)))
        XCTAssertNil(NotesLinkTitleResolver.oEmbedTitle(in: Data(#"{"type":"error","title":"Sign in"}"#.utf8)))
    }

    @MainActor func testVideoResolutionRequestsOnlyYouTubeOEmbed() async {
        let url = URL(string: "https://youtu.be/jNQXAC9IVRw?t=5")!
        let endpoint = NotesLinkTitleResolver.youtubeEndpoint(for: url)!
        let session = session(replies: [endpoint: .init(body: #"{"type":"video","title":"Me at the zoo","author_name":"jawed"}"#, mime: "application/json")])
        defer { session.invalidateAndCancel() }
        let title = await NotesLinkTitleResolver.title(for: url, session: session)
        XCTAssertEqual(title, "Me at the zoo")
        XCTAssertEqual(MetadataURLProtocol.requests, [endpoint])
    }

    @MainActor func testFailedOEmbedCanUsePageMetadataAndHTTPFailuresReturnNil() async {
        let url = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!
        let endpoint = NotesLinkTitleResolver.youtubeEndpoint(for: url)!
        let session = session(replies: [endpoint: .init(body: "", mime: "application/json", status: 404),
                                        url: .init(body: "<meta property='og:title' content='视频标题'>")])
        defer { session.invalidateAndCancel() }
        let title = await NotesLinkTitleResolver.title(for: url, session: session)
        XCTAssertEqual(title, "视频标题")
        XCTAssertEqual(MetadataURLProtocol.requests, [endpoint, url])
        let failed = URL(string: "https://example.com/missing")!
        let missing = await NotesLinkTitleResolver.title(for: failed, session: session)
        XCTAssertNil(missing)
    }

    @MainActor func testHTMLDownloadCanReadTitleFromBoundedPagePrefix() async {
        let url = URL(string: "https://example.com/large")!
        let session = session(replies: [url: .init(body: "<title>开头的标题</title><body>" + String(repeating: "x", count: 2 * 1024 * 1024))])
        defer { session.invalidateAndCancel() }
        let title = await NotesLinkTitleResolver.title(for: url, session: session)
        XCTAssertEqual(title, "开头的标题")
    }

    @MainActor func testCancelledMetadataRequestDoesNotPublishALateTitle() async throws {
        let url = URL(string: "https://example.com/delayed")!
        let session = session(replies: [url: .init(body: "<title>迟到的标题</title>", delay: 0.15)])
        defer { session.invalidateAndCancel() }
        let callback = expectation(description: "A cancelled request must not deliver")
        callback.isInverted = true
        let request = NotesLinkMetadata.fetchTitle(for: url, session: session) { _ in callback.fulfill() }
        let deadline = Date().addingTimeInterval(1)
        while MetadataURLProtocol.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(MetadataURLProtocol.requests, [url])
        request.cancel()
        await fulfillment(of: [callback], timeout: 0.3)
    }

    private func session(replies: [URL: MetadataURLProtocol.Reply]) -> URLSession {
        MetadataURLProtocol.configure(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class MetadataURLProtocol: URLProtocol {
    struct Reply {
        let body: String
        var mime = "text/html"
        var status = 200
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    private static var replies: [URL: Reply] = [:]
    private static var recorded: [URL] = []
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func configure(_ values: [URL: Reply]) {
        lock.lock(); defer { lock.unlock() }
        replies = values; recorded = []
    }
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.recorded.append(url)
        let reply = Self.replies[url] ?? Reply(body: "", status: 404)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            stateLock.lock()
            let shouldDeliver = !stopped
            stateLock.unlock()
            guard shouldDeliver else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mime + "; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
