import Foundation
import XCTest

@testable import MaskoPlayer

/// Serves a few bytes for any URL, 404 for paths with "missing", and counts
/// the requests.
final class StubServer: URLProtocol {
    private static let lock = NSLock()
    private static var _hits: [String] = []

    static var hits: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _hits
    }

    static func reset() {
        lock.lock()
        _hits = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self._hits.append(url.absoluteString)
        Self.lock.unlock()
        let status = url.path.contains("missing") ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("bytes of \(url.path)".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class FileCacheTests: XCTestCase {
    func makeCache(capacity: Int = 12) -> FileCache {
        StubServer.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return FileCache(session: URLSession(configuration: config), capacity: capacity)
    }

    func fetch(_ cache: FileCache, _ url: String, key: String) async -> URL? {
        await withCheckedContinuation { done in
            cache.file(URL(string: url)!, key: key) { done.resume(returning: $0) }
        }
    }

    func testAFileIsDownloadedOnceAndOutlivesItsLink() async throws {
        let cache = makeCache()
        defer { cache.clear() }
        let first = await fetch(cache, "https://cdn.test/a.mov?sig=1", key: "a")
        let file = try XCTUnwrap(first)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bytes of /a.mov")
        // A refreshed link to the same file: the cached copy plays.
        let again = await fetch(cache, "https://cdn.test/a.mov?sig=2", key: "a")
        XCTAssertEqual(again, file)
        XCTAssertEqual(StubServer.hits, ["https://cdn.test/a.mov?sig=1"])
    }

    func testRequestsForTheSameFileShareOneDownload() async throws {
        let cache = makeCache()
        defer { cache.clear() }
        async let one = fetch(cache, "https://cdn.test/b.mov", key: "b")
        async let two = fetch(cache, "https://cdn.test/b.mov", key: "b")
        let (x, y) = await (one, two)
        XCTAssertNotNil(x)
        XCTAssertEqual(x, y)
        XCTAssertEqual(StubServer.hits.count, 1)
    }

    func testAFailedDownloadGivesNoFile() async {
        let cache = makeCache()
        defer { cache.clear() }
        let file = await fetch(cache, "https://cdn.test/missing.mov", key: "m")
        XCTAssertNil(file)
    }

    func testOnlyTheMostRecentFilesAreKept() async throws {
        let cache = makeCache(capacity: 2)
        defer { cache.clear() }
        let fetched = await fetch(cache, "https://cdn.test/a.mov", key: "a")
        let a = try XCTUnwrap(fetched)
        _ = await fetch(cache, "https://cdn.test/b.mov", key: "b")
        _ = await fetch(cache, "https://cdn.test/a.mov", key: "a")  // a is recent again
        _ = await fetch(cache, "https://cdn.test/c.mov", key: "c")  // b goes
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        _ = await fetch(cache, "https://cdn.test/b.mov", key: "b")
        XCTAssertEqual(StubServer.hits.filter { $0.hasSuffix("b.mov") }.count, 2)
    }

    func testLocalFilesAreUsedWhereTheyAre() async throws {
        let cache = makeCache()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("masko-local-\(UUID()).mov")
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let got = await withCheckedContinuation { done in
            cache.file(local, key: "l") { done.resume(returning: $0) }
        }
        XCTAssertEqual(got, local)
        XCTAssertTrue(StubServer.hits.isEmpty)
    }
}
