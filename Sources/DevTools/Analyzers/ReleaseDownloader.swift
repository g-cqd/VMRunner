import Foundation
import Synchronization

/// Where release archives (the analyzers and SwiftLint) come from.
enum ReleaseLocation: Sendable {
    /// `https://github.com/<owner>/<repository>/releases/download/<tag>/<archive>`
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
            let release = pin.release
            let address =
                "https://github.com/\(release.owner)/\(release.repository)/releases/download/\(release.tagPrefix)\(pin.version)/\(pin.archiveName)"
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

/// `file:` URLs are cloned; `https:` URLs are fetched with TLS 1.2 or later and up to three attempts. A transfer past
/// `maximumBytes` is refused, and a redirect to anything but `https:` is not followed.
struct URLArchiveDownloader: ArchiveDownloader {
    private static let attempts = 3
    /// The releases are tens of megabytes; a response far beyond that is not one of them.
    static let defaultMaximumBytes = 256 << 20

    var maximumBytes = Self.defaultMaximumBytes

    func download(from source: URL, to destination: URL) async throws {
        if source.isFileURL {
            try checkSize(ofFileAt: source, named: source.absoluteString)
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
            let transfer = TransferGuard(maximumBytes: maximumBytes)
            do {
                let (temporary, response) = try await session.download(from: source, delegate: transfer)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ToolError("\(source.absoluteString): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                try checkSize(ofFileAt: temporary, named: source.absoluteString)
                try FileManager.default.moveItem(at: temporary, to: destination)
                return
            } catch {
                if transfer.exceededLimit { throw sizeError(source.absoluteString) }
                if error is ToolError { throw error }
                lastError = error
            }
        }
        throw ToolError("download of \(source.absoluteString) failed: \(lastError.map { "\($0)" } ?? "unknown error")")
    }

    private func checkSize(ofFileAt file: URL, named name: String) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > maximumBytes { throw sizeError(name) }
    }

    private func sizeError(_ name: String) -> ToolError {
        ToolError("\(name) is larger than \(maximumBytes) bytes; refusing it")
    }
}

/// Watches one transfer: it refuses a redirect away from `https:` and cancels the download as soon as it grows past the limit.
final class TransferGuard: NSObject, URLSessionDownloadDelegate, Sendable {
    private let maximumBytes: Int
    private let exceeded = Mutex(false)

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var exceededLimit: Bool { exceeded.withLock { $0 } }

    /// A redirect is followed only when it stays on `https:`.
    static func allowsRedirect(to url: URL?) -> Bool {
        url?.scheme == "https"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowsRedirect(to: request.url) ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(maximumBytes) || totalBytesExpectedToWrite > Int64(maximumBytes) {
            exceeded.withLock { $0 = true }
            downloadTask.cancel()
        }
    }

    /// The file is handed to the caller of the async download API, which moves it; there is nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
