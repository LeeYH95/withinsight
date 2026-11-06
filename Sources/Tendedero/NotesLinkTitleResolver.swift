import Foundation
import SwiftSoup

/// Downloads stay under the app's timeout/size limits. SwiftSoup only parses
/// the received HTML; no page script or remote parsing service is involved.
enum NotesLinkTitleResolver {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func title(for url: URL, session: URLSession = session) async -> String? {
        guard NotesWebLink.url(from: url.absoluteString) != nil else { return nil }
        if let endpoint = youtubeEndpoint(for: url),
           let data = try? await download(endpoint, session: session, limit: 64 * 1024, json: true),
           let title = oEmbedTitle(in: data) { return title }
        guard !Task.isCancelled,
              let data = try? await download(url, session: session, limit: 1024 * 1024, json: false),
              !Task.isCancelled else { return nil }
        return try? htmlTitle(in: data, url: url)
    }

    static func youtubeEndpoint(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let id: String?
        switch host {
        case "youtu.be", "www.youtu.be": id = parts.first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com":
            if url.path == "/watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count == 2, ["shorts", "embed", "live"].contains(parts[0]) {
                id = parts[1]
            } else { id = nil }
        default: return nil
        }
        guard let id, id.utf8.count == 11,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var endpoint = URLComponents(string: "https://www.youtube.com/oembed")!
        endpoint.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + id),
                               URLQueryItem(name: "format", value: "json")]
        return endpoint.url
    }

    static func oEmbedTitle(in data: Data) -> String? {
        struct Video: Decodable { let title: String; let type: String }
        guard let video = try? JSONDecoder().decode(Video.self, from: data), video.type == "video" else { return nil }
        return usableTitle(video.title)
    }

    static func htmlTitle(in data: Data, url: URL) throws -> String? {
        let document = try SwiftSoup.parseHTML(data, url.absoluteString)
        let metadata = try document.select("meta[property], meta[name]").array()
        for key in ["og:title", "twitter:title"] {
            for element in metadata {
                let property = try element.attr("property")
                let name = try property.isEmpty ? element.attr("name") : property
                if name.lowercased() == key, let title = usableTitle(try element.attr("content")) { return title }
            }
        }
        if let title = usableTitle(try document.title()) { return title }
        // WeChat article pages also expose the visible article heading here.
        if url.host?.lowercased() == "mp.weixin.qq.com",
           let element = try document.select("#activity-name").first() {
            return usableTitle(try element.text())
        }
        return nil
    }

    static func usableTitle(_ value: String?) -> String? {
        guard let title = NotesWebLink.normalizedTitle(value) else { return nil }
        let generic = Set(["youtube", "微信公众平台", "环境异常", "安全验证", "访问过于频繁", "请完成安全验证",
                           "登录", "sign in", "sign in - google accounts", "just a moment...", "attention required! | cloudflare"])
        return generic.contains(title.lowercased()) ? nil : title
    }

    private static func download(_ url: URL, session: URLSession, limit: Int, json: Bool) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(json ? "application/json" : "text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let destination = response.url, NotesWebLink.url(from: destination.absoluteString) != nil else { throw URLError(.badServerResponse) }
        if let mime = response.mimeType?.lowercased() {
            let valid = json ? mime == "application/json" : ["text/html", "application/xhtml+xml"].contains(mime)
            guard valid else { throw URLError(.cannotDecodeContentData) }
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count == limit { break }
        }
        return data
    }
}
