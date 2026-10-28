import Combine
import Foundation
import XCTest
@testable import Tendedero

final class WebLinkTests: XCTestCase {
    func testSingleWebURLTrimsOnlyBoundaryWhitespaceAndKeepsItsDestination() {
        let text = " \n\thttps://example.com/article?q=one%20two&lang=zh#section\r\n "
        XCTAssertEqual(NotesWebLink.url(from: text)?.absoluteString,
                       "https://example.com/article?q=one%20two&lang=zh#section")
        XCTAssertEqual(NotesWebLink.url(from: "http://localhost:8080/page")?.host, "localhost")
        XCTAssertNotNil(NotesWebLink.url(from: "HTTPS://example.com"))
        XCTAssertNotNil(NotesWebLink.url(from: "https://[::1]/path"))
    }

    func testMixedTextMultipleURLsAndIncompleteURLsAreNotSingleWebURLs() {
        for text in ["", " \n ", "example.com", "https://", "https:///missing-host",
                     "See https://example.com", "https://example.com trailing text",
                     "https://one.example https://two.example",
                     "https://one.example\nhttps://two.example",
                     "<https://example.com>", "https://example.com/a\u{0000}b",
                     "https://example.com/a\tb", "https://example.com/a\\b",
                     "https://example.com/bad%escape", "https://example.com/bad%",
                     "https://example.com/bad%2", "https://example.com/bad%GG"] {
            XCTAssertNil(NotesWebLink.url(from: text), "Must leave this clipboard text untouched: \(text.debugDescription)")
        }
    }

    func testUnicodePathsAndInternationalizedDomainsKeepTheirWebDestination() throws {
        let path = try XCTUnwrap(NotesWebLink.url(from: "https://example.com/拾片?标题=你好#章节"))
        XCTAssertEqual(path.host, "example.com")
        XCTAssertEqual(path.path, "/拾片")
        XCTAssertTrue(path.absoluteString.contains("%E6%8B%BE%E7%89%87"))
        let international = try XCTUnwrap(NotesWebLink.url(from: "https://例子.测试/页面"))
        XCTAssertEqual(international.absoluteString, "https://xn--fsqu00a.xn--0zwm56d/%E9%A1%B5%E9%9D%A2")
        XCTAssertEqual(NotesWebLink.destination(from: "https://例子.测试/页面"), international)
    }

    func testUnsafeSchemesAndEmbeddedCredentialsAreRejected() {
        for text in ["file:///tmp/note.txt", "javascript:alert(1)", "data:text/html,test",
                     "mailto:hello@example.com", "ftp://example.com/file",
                     "https://user@example.com", "https://user:password@example.com",
                     "https://@example.com", "https://:password@example.com"] {
            XCTAssertNil(NotesWebLink.url(from: text), text)
        }
    }

    func testAttributedDestinationAcceptsOnlySafeURLAndStringValues() throws {
        let expected = try XCTUnwrap(URL(string: "https://example.com/path?query=one#two"))
        XCTAssertEqual(NotesWebLink.destination(from: expected), expected)
        XCTAssertEqual(NotesWebLink.destination(from: expected.absoluteString), expected)
        XCTAssertNil(NotesWebLink.destination(from: URL(fileURLWithPath: "/tmp/note.txt")))
        XCTAssertNil(NotesWebLink.destination(from: "javascript:alert(1)"))
        XCTAssertNil(NotesWebLink.destination(from: "https://user@example.com"))
        XCTAssertNil(NotesWebLink.destination(from: 42))
        XCTAssertNil(NotesWebLink.destination(from: nil))
    }

    func testTitleWhitespaceAndControlCharactersBecomeReadableSingleSpaces() {
        XCTAssertEqual(NotesWebLink.normalizedTitle(" \nHello\t world\r\n\u{0000}from\u{0007}拾片\u{00A0} "),
                       "Hello world from 拾片")
        XCTAssertEqual(NotesWebLink.normalizedTitle("作品 👩🏽‍💻 与 café"), "作品 👩🏽‍💻 与 café")
        XCTAssertNil(NotesWebLink.normalizedTitle(nil))
        XCTAssertNil(NotesWebLink.normalizedTitle(" \r\n\t\u{0000}\u{0007}"))
    }

    func testTitleLengthUsesCompleteUnicodeCharacters() throws {
        let character = "👨‍👩‍👧‍👦"
        let title = try XCTUnwrap(NotesWebLink.normalizedTitle(String(repeating: character, count: 181)))
        XCTAssertEqual(title, String(repeating: character, count: 180))
        XCTAssertEqual(title.count, 180)
    }

    func testInvisibleJoinersAloneAreNotATitle() {
        XCTAssertNil(NotesWebLink.normalizedTitle("\u{200C}\u{200D}"))
        XCTAssertNil(NotesWebLink.normalizedTitle(" \u{200C}\u{200D} "))
        XCTAssertNil(NotesWebLink.normalizedTitle("\u{200B}\u{202E}"))
    }

    func testDefaultIgnorableScalarsAloneAreNotATitle() {
        for title in ["\u{034F}", "\u{FE0F}", "\u{E0100}", " \u{034F}\u{FE0F}\u{200D} "] {
            XCTAssertNil(NotesWebLink.normalizedTitle(title))
        }
    }

    func testVisibleTitlesKeepCombiningMarksEmojiJoinersAndVariationSelectors() throws {
        let title = "cafe\u{0301} ♥\u{FE0F} 👩\u{200D}💻"
        let result = try XCTUnwrap(NotesWebLink.normalizedTitle(title))
        XCTAssertEqual(Array(result.unicodeScalars), Array(title.unicodeScalars))
    }

    @MainActor func testMetadataRequestExposesCancellableMainActorCompletion() {
        let fetch: @MainActor (URL, @escaping @MainActor (String?) -> Void) -> AnyCancellable = NotesLinkMetadata.fetchTitle
        _ = fetch
    }
}
