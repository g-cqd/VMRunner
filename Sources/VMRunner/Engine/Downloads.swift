import CryptoKit
import Foundation
import RegexBuilder
import Synchronization
import os

enum SetupError: LocalizedError {
    case checksumMismatch(file: String, expected: String, actual: String)
    case badResponse(URL, Int)
    case untrustedURL(URL)
    case unsafeFileName(String)
    case responseTooLarge(URL)
    case invalidMachineModel(String)
    case unsupportedHost(String)
    case missingFile(String)
    /// The OpenPGP signature that should vouch for `file` is missing, malformed or wrong; `reason` completes "because ...".
    case signatureRejected(file: String, reason: String)
    case rosettaUnavailable

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let file, let expected, let actual):
            "Checksum mismatch for \(file): expected \(expected), got \(actual)."
        case .badResponse(let url, let status):
            "HTTP \(status) from \(url.host() ?? url.absoluteString)."
        case .untrustedURL(let url):
            "Refusing to download from \(url.host() ?? url.absoluteString): "
                + "only HTTPS from the hosts of Apple and the offered Linux distributions is allowed."
        case .unsafeFileName(let name):
            "Refusing a download with an unsafe file name: \(name)"
        case .responseTooLarge(let url):
            "The response from \(url.host() ?? url.absoluteString) is larger than expected."
        case .invalidMachineModel(let identifier):
            "“\(identifier)” isn't a Mac model identifier like Mac14,15."
        case .unsupportedHost(let reason):
            reason
        case .missingFile(let path):
            "File not found: \(path)"
        case .signatureRejected(let file, let reason):
            "Refusing \(file): its OpenPGP signature cannot be trusted, because \(reason)."
        case .rosettaUnavailable:
            "Rosetta for Linux isn't installed. Install it from the VM's settings."
        }
    }
}

/// Where downloads may come from and what they may be called on disk. Catalog data (ipsw.me, mirror
/// listings) is remote input: a compromised or spoofed response must not be able to point the app at
/// another host, a plain-HTTP URL, or a path outside the image cache.
enum DownloadPolicy {
    /// Hosts the app downloads from: Apple's CDN, the ipsw.me catalog, and the Linux vendors' own servers. Each Linux
    /// provider's host must be added here before it moves from `LinuxCatalog.candidates` to `images`; Alpine and Ubuntu
    /// are pinned to the one host that serves their ISOs and checksums, not to their whole domains.
    static let allowedHostSuffixes = [
        "apple.com", "cdn-apple.com", "ipsw.me", "centos.org", "debian.org", "dl-cdn.alpinelinux.org", "cdimage.ubuntu.com",
    ]

    static func validate(_ url: URL) throws(SetupError) -> URL {
        guard url.scheme == "https", url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
            let host = url.host()?.lowercased(),
            allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { throw .untrustedURL(url) }
        return url
    }

    /// The last path component, if it is a plain file name: no separators, no leading dot, bounded length.
    static func cacheFileName(for url: URL) throws(SetupError) -> String {
        let name = url.lastPathComponent
        let plainName = Regex {
            CharacterClass.asciiAlphanumeric
            Repeat(0...199) {
                ChoiceOf {
                    CharacterClass.asciiAlphanumeric
                    CharacterClass.anyOf("._-")
                }
            }
        }
        guard name.wholeMatch(of: plainName) != nil else { throw .unsafeFileName(name) }
        return name
    }

    /// Mac model identifiers look like `Mac14,15`; anything else would alter the catalog URL's path.
    static func validateMachineModel(_ identifier: String) throws(SetupError) -> String {
        let modelIdentifier = Regex {
            Repeat(1...24) { .asciiAlphanumeric }
            ","
            Repeat(1...4) { .asciiDigit }
        }
        guard identifier.wholeMatch(of: modelIdentifier) != nil else { throw .invalidMachineModel(identifier) }
        return identifier
    }
}

/// Refuses redirects that leave the download policy.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    /// The request to follow, or nil to stop at the redirect response.
    static func allowed(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, (try? DownloadPolicy.validate(url)) != nil else {
            Log.network.error("Blocked a redirect to a disallowed location")
            return nil
        }
        return request
    }

    // The completion-handler form: the `async` variant crashes the Swift 6.4 compiler's Objective-C thunk
    // emission when NonisolatedNonsendingByDefault is on.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.allowed(request))
    }
}

enum Network {
    /// The size cap of a small document unless the caller asks for less.
    static let smallLimit = 4 << 20

    /// Fetches a small document (catalog JSON, a directory listing) with a hard size cap.
    static func fetchSmall(_ url: URL, limit: Int = smallLimit) async throws -> Data {
        _ = try DownloadPolicy.validate(url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: RedirectPolicy())
        if let final = response.url { _ = try DownloadPolicy.validate(final) }
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

enum Checksums {
    /// Streams the file through the hash so a 26 GB IPSW never sits in memory. Cancelling the caller
    /// stops the read.
    static func hexDigest(of url: URL, algorithm: Checksum.Algorithm) async throws -> String {
        let work = Task.detached(priority: .utility) { try digest(of: url, algorithm: algorithm) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func verify(_ url: URL, against checksum: Checksum) async throws {
        let actual = try await hexDigest(of: url, algorithm: checksum.algorithm)
        guard actual.caseInsensitiveCompare(checksum.value) == .orderedSame else {
            throw SetupError.checksumMismatch(file: url.lastPathComponent, expected: checksum.value, actual: actual)
        }
    }

    /// Streams the file through the hash that `check`'s signature uses and verifies the signature over it, so a signed
    /// installer is proven by its own bytes. Cancelling the caller stops the read.
    /// - Throws: `SetupError.signatureRejected` naming `name` if the signature does not match.
    static func verify(_ url: URL, named name: String, signedBy check: PGP.Check) async throws {
        let work = Task.detached(priority: .utility) { try signedDigest(of: url, using: check) }
        let digest = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        do {
            try check.verify(digest)
        } catch {
            throw SetupError.signatureRejected(file: name, reason: error.localizedDescription)
        }
    }

    private static func signedDigest(of url: URL, using check: PGP.Check) throws -> PGP.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = check.makeDigest()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(chunk)
        }
        return digest
    }

    // 4 MiB chunks measured fastest for FileHandle reads (1 MiB: -16%, 16 MiB: -78% on an M3, 1 GB file).
    private static let chunkSize = 4 << 20

    private static func digest(of url: URL, algorithm: Checksum.Algorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().hexString
        case .sha1:
            var hasher = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().hexString
        }
    }
}

/// Resumable single-file download with progress. Partial data survives cancellation and relaunch.
///
/// All mutable state lives behind one `Mutex`, and the continuation is resumed exactly once.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, any Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
    }

    private let state = Mutex(State())
    private let onProgress: @Sendable (_ written: Int64, _ total: Int64) -> Void
    private let resumeFile: URL
    private let workDirectory: URL

    init(resumeKey: String, workDirectory: URL = AppPaths.partialDownloads, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
        self.workDirectory = workDirectory
        resumeFile = workDirectory.appending(path: "\(resumeKey).resume")
    }

    /// Downloads `url` to a temporary file that the caller must move into place.
    /// - Throws: `CancellationError` if the calling task is cancelled; resume data is kept for the next attempt.
    func download(from url: URL) async throws -> URL {
        _ = try DownloadPolicy.validate(url)
        try AppPaths.createPrivateDirectory(workDirectory)

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = state.withLock { state -> URLSessionDownloadTask? in
                    guard !state.cancelled else { return nil }
                    let task =
                        (try? Data(contentsOf: resumeFile)).map(session.downloadTask(withResumeData:))
                        ?? session.downloadTask(with: url)
                    state.continuation = continuation
                    state.task = task
                    return task
                }
                if let task {
                    task.resume()
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = state.withLock { state -> URLSessionDownloadTask? in
                state.cancelled = true
                return state.task
            }
            task?.cancel { [resumeFile] data in
                if let data { try? data.write(to: resumeFile) }
            }
        }
    }

    private func finish(with result: Result<URL, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<URL, any Error>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: resumeFile)
            finish(with: .failure(SetupError.badResponse(downloadTask.originalRequest?.url ?? location, http.statusCode)))
            return
        }
        // The system deletes `location` when this method returns, so move it out now.
        let kept = workDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            try? FileManager.default.removeItem(at: resumeFile)
            finish(with: .success(kept))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(RedirectPolicy.allowed(request))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile)
        } else if nsError.code != NSURLErrorCancelled {
            // Stale resume data would fail the same way forever.
            try? FileManager.default.removeItem(at: resumeFile)
        }
        finish(with: .failure(nsError.code == NSURLErrorCancelled ? CancellationError() : error))
    }
}

enum ImageStore {
    /// The cached file at `destination` if it is still good, or nil if there is none or it no longer matches `checksum`.
    ///
    /// A cached file is reused only after its checksum and, when the vendor signs the installer, its signature are checked
    /// again: some images (Debian's `mini.iso`) keep one file name while their content changes, and a corrupted or replaced
    /// file must never reach an installer. A file that fails is deleted so the caller downloads a fresh one. Without a
    /// checksum or a signature there is nothing to verify against.
    @MainActor
    static func validCachedFile(at destination: URL, checksum: Checksum?, signature: PGP.Check? = nil, job: SetupJob) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        guard checksum != nil || signature != nil else { return destination }
        job.title = "Checking \(destination.lastPathComponent)"
        job.fraction = nil
        do {
            try await verify(destination, named: destination.lastPathComponent, checksum: checksum, signature: signature)
            return destination
        } catch SetupError.checksumMismatch {
            Log.storage.notice("Cached \(destination.lastPathComponent, privacy: .public) is stale or damaged; downloading again")
            try FileManager.default.removeItem(at: destination)
            return nil
        } catch SetupError.signatureRejected {
            Log.storage.notice("Cached \(destination.lastPathComponent, privacy: .public) fails its signature; downloading again")
            try FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    /// Checks `file` against the published checksum and the vendor's signature, whichever there are. Both must pass.
    static func verify(_ file: URL, named name: String, checksum: Checksum?, signature: PGP.Check?) async throws {
        if let checksum { try await Checksums.verify(file, against: checksum) }
        if let signature { try await Checksums.verify(file, named: name, signedBy: signature) }
    }

    /// Downloads `remote` into the shared image cache (or reuses it), verifying the checksum and the signature when known.
    @MainActor
    static func fetch(
        _ remote: URL, checksum: Checksum?, signature: PGP.Check? = nil, job: SetupJob, imagesDirectory: URL = AppPaths.images
    ) async throws -> URL {
        _ = try DownloadPolicy.validate(remote)
        let name = try DownloadPolicy.cacheFileName(for: remote)
        let destination = imagesDirectory.appending(path: name)
        try AppPaths.createPrivateDirectory(imagesDirectory)
        if let cached = try await validCachedFile(at: destination, checksum: checksum, signature: signature, job: job) { return cached }

        job.title = "Downloading \(name)"
        job.fraction = 0
        let throttle = Throttle(interval: 0.25)
        let downloader = FileDownloader(resumeKey: name) { written, total in
            guard total > 0, throttle.allow() else { return }
            let fraction = Double(written) / Double(total)
            Task { @MainActor in job.fraction = fraction }
        }
        let temporary = try await downloader.download(from: remote)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()

        if checksum != nil || signature != nil {
            job.title = "Verifying \(name)"
            job.fraction = nil
            try await verify(temporary, named: name, checksum: checksum, signature: signature)
        }
        // Another setup may have finished the same download meanwhile; keep its file.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}

/// Lets the first event through every `interval` seconds; safe to call from the URLSession queue.
final class Throttle: Sendable {
    private let interval: Duration
    private let last = Mutex(ContinuousClock.Instant?.none)

    init(interval: TimeInterval) { self.interval = .seconds(interval) }

    func allow() -> Bool {
        let now = ContinuousClock.now
        return last.withLock { last in
            if let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
    }
}

extension Sequence<UInt8> {
    /// Lowercase hexadecimal, two digits per byte.
    var hexString: String {
        map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}
