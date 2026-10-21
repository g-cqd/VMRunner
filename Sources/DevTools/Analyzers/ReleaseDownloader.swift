import Foundation

/// Where analyzer release archives come from.
enum ReleaseLocation: Sendable {
    /// The GitHub account that publishes the analyzer releases: the one place its name is written.
    static let owner = "g-cqd"

    /// `https://github.com/<owner>/<tool>/releases/download/v<version>/<archive>`
    case github
    /// A directory (a `file:` or `https:` URL) that holds the archives, for a mirror or a local test release.
    case directory(URL)

    /// `VMR_ANALYZERS_BASE_URL` selects `.directory`. The archive is verified against the pinned SHA-256 whatever
    /// its origin, so this widens where bytes may come from, not what is trusted.
    init(environment: [String: String]) throws {
        guard let raw = environment["VMR_ANALYZERS_BASE_URL"], !raw.isEmpty else {
            self = .github
            return
        }
        guard let url = URL(string: raw), let scheme = url.scheme, ["file", "https"].contains(scheme) else {
            throw ToolError("VMR_ANALYZERS_BASE_URL must be a file: or https: URL")
        }
        self = .directory(url)
    }

    func archiveURL(for pin: AnalyzerPin) throws -> URL {
        switch self {
        case .github:
            let address = "https://github.com/\(Self.owner)/\(pin.tool.rawValue)/releases/download/v\(pin.version)/\(pin.archiveName)"
            guard let url = URL(string: address) else { throw ToolError("invalid release URL \(address)") }
            return url
        case .directory(let base):
            return base.appending(path: pin.archiveName)
        }
    }
}

/// Fetches one archive to a local file. Injected into the installer so tests can substitute the transfer.
protocol ArchiveDownloader: Sendable {
    func download(from source: URL, to destination: URL) async throws
}

/// `file:` URLs are cloned; `https:` URLs are fetched with TLS 1.2 or later and up to three attempts.
struct URLArchiveDownloader: ArchiveDownloader {
    private static let attempts = 3

    func download(from source: URL, to destination: URL) async throws {
        if source.isFileURL {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard source.scheme == "https" else { throw ToolError("refusing to download over \(source.scheme ?? "an unknown scheme")") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var lastError: (any Error)?
        for _ in 0..<Self.attempts {
            do {
                let (temporary, response) = try await session.download(from: source)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ToolError("\(source.absoluteString): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return
            } catch {
                lastError = error
            }
        }
        throw ToolError("download of \(source.absoluteString) failed: \(lastError.map { "\($0)" } ?? "unknown error")")
    }
}
