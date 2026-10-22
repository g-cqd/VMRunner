import Foundation

/// Small remote documents (catalog JSON, directory listings), and the session configuration every request of the app shares.
enum Fetch {
    /// The size cap of a small document unless the caller asks for less.
    static let smallLimit = 4 << 20

    /// The session configuration of every request the app makes for catalogs and downloads: nothing is cached on disk, no
    /// cookies are kept or sent, no credentials are stored, and TLS is 1.2 or later.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    /// Fetches a small document (catalog JSON, a directory listing) with a hard size cap.
    @concurrent
    static func fetchSmall(_ url: URL, limit: Int = smallLimit, configuration: URLSessionConfiguration = makeConfiguration()) async throws
        -> Data
    {
        _ = try DownloadPolicy.validateMetadata(url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectPolicy(metadata: true))
        if let final = response.url { _ = try DownloadPolicy.validateMetadata(final) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SetupError.badResponse(url, http.statusCode)
        }
        guard response.expectedContentLength <= limit else { throw SetupError.responseTooLarge(url) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw SetupError.responseTooLarge(url) }
        }
        return data
    }
}
