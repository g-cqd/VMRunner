import Foundation
import Synchronization

/// Serves canned responses to a `URLSession` so download tests run without a network or a socket. A test registers a reply
/// for a URL that no other test uses, then runs the code under test with `StubURLProtocol.configuration()`.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        /// Delivered in order, one `didLoad` each, so a body can arrive in pieces the way a chunked response does.
        var chunks: [Data] = []
    }

    private static let replies = Mutex<[String: Reply]>([:])
    private static let served = Mutex<[String]>([])

    /// Answers requests for `url` with `reply`.
    static func serve(_ reply: Reply, at url: URL) {
        replies.withLock { $0[url.absoluteString] = reply }
    }

    /// Answers requests for `url` with `body` and its Content-Length.
    static func serve(_ body: Data, at url: URL) {
        serve(Reply(headers: ["Content-Length": String(body.count)], chunks: [body]), at: url)
    }

    /// How many requests for `url` reached the stub.
    static func requestCount(for url: URL) -> Int {
        served.withLock { $0.filter { $0 == url.absoluteString }.count }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.served.withLock { $0.append(url.absoluteString) }
        guard let reply = Self.replies.withLock({ $0[url.absoluteString] }),
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
