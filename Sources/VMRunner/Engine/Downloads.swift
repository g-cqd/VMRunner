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
    /// A cached or attached file is a link or another kind of entry where a regular file must be.
    case notARegularFile(String)
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
        case .notARegularFile(let name):
            "Refusing \(name): it is a link or another kind of entry, not a regular file."
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
    /// The hosts that serve installers, listings, checksums and signatures, each named exactly. A suffix such as
    /// `debian.org` would also admit hosts that serve user content (`salsa.debian.org`, `people.debian.org`) and any
    /// subdomain Apple or a vendor hands to a third party, so no entry here covers its subdomains. Each Linux provider's
    /// host must be added here before it moves from `LinuxCatalog.candidates` to `images`.
    static let allowedHosts: Set<String> = [
        restoreImageHost, "mirror.stream.centos.org", "deb.debian.org", "cdimage.debian.org", "dl-cdn.alpinelinux.org",
        "cdimage.ubuntu.com",
    ]

    /// The one host that serves macOS restore images, for `.latestMac` and for every ipsw.me entry.
    static let restoreImageHost = "updates.cdn-apple.com"

    /// The ipsw.me catalog API: asked for metadata only, never for a file to download.
    static let catalogHost = "api.ipsw.me"

    /// Whether `url` may be an installer, a listing, a checksum file or a signature: HTTPS, an exactly named host, the
    /// default port and no credentials.
    static func validate(_ url: URL) throws(SetupError) -> URL {
        try check(url, hosts: allowedHosts)
    }

    /// Whether `url` may be fetched as a small document: everything `validate` accepts, and the ipsw.me catalog.
    static func validateMetadata(_ url: URL) throws(SetupError) -> URL {
        try check(url, hosts: allowedHosts.union([catalogHost]))
    }

    /// Whether `url`, taken from the ipsw.me catalog, may be downloaded as a restore image: Apple's update server only,
    /// and a file named `*.ipsw`.
    static func validateRestoreImage(_ url: URL) throws(SetupError) -> URL {
        _ = try check(url, hosts: [restoreImageHost])
        guard try cacheFileName(for: url).hasSuffix(".ipsw") else { throw .untrustedURL(url) }
        return url
    }

    private static func check(_ url: URL, hosts: Set<String>) throws(SetupError) -> URL {
        guard url.scheme == "https", url.user() == nil, url.password() == nil, url.port == nil || url.port == 443,
            let host = url.host()?.lowercased(), hosts.contains(host)
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
    /// Whether the ipsw.me catalog host is acceptable, as for a small document but not for a download.
    private let metadata: Bool

    init(metadata: Bool = false) { self.metadata = metadata }

    /// The request to follow, or nil to stop at the redirect response.
    static func allowed(_ request: URLRequest, metadata: Bool = false) -> URLRequest? {
        let validate = metadata ? DownloadPolicy.validateMetadata : DownloadPolicy.validate
        guard let url = request.url, (try? validate(url)) != nil else {
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
        completionHandler(Self.allowed(request, metadata: metadata))
    }
}

enum Network {
    /// The size cap of a small document unless the caller asks for less.
    static let smallLimit = 4 << 20

    /// Fetches a small document (catalog JSON, a directory listing) with a hard size cap.
    @concurrent
    static func fetchSmall(_ url: URL, limit: Int = smallLimit) async throws -> Data {
        _ = try DownloadPolicy.validateMetadata(url)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: RedirectPolicy(metadata: true))
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

    /// Opens `url` for reading if it is a regular file, and never through a symbolic link: the image cache is shared, so a
    /// planted link must not turn the verification of one file into the reading of another.
    /// - Throws: `SetupError.notARegularFile` for a link, a directory or a device; the POSIX error for anything else.
    static func openRegularFile(_ url: URL) throws -> FileHandle {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_NOFOLLOW makes it fail with ELOOP on a link.
        let descriptor = unsafe open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP ? SetupError.notARegularFile(url.lastPathComponent) : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        // `status` is a local that outlives the call, which fills it.
        guard unsafe fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw SetupError.notARegularFile(url.lastPathComponent)
        }
        return handle
    }

    private static func signedDigest(of url: URL, using check: PGP.Check) throws -> PGP.Digest {
        let handle = try openRegularFile(url)
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
        let handle = try openRegularFile(url)
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
        /// Where the transfer comes from, for the error.
        var source: URL?
        /// Set once the body is known to be, or has become, larger than `maximumBytes`; the task is cancelled then.
        var exceeded = false
    }

    private let state = Mutex(State())
    private let onProgress: @Sendable (_ written: Int64, _ total: Int64) -> Void
    private let resumeFile: URL
    private let workDirectory: URL

    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64

    /// The most any single download may be unless the caller knows better: far above the largest restore image, far below
    /// a disk that fills the volume.
    static let defaultMaximumBytes: Int64 = 64 << 30

    /// - Parameters:
    ///   - resumeKey: Names the file that keeps partial data between attempts.
    ///   - workDirectory: Where partial data and finished downloads are written.
    ///   - maximumBytes: The most the body may have, whether the server announces it or just keeps sending.
    ///   - configuration: How the transfer runs; tests pass one that serves canned responses.
    ///   - onProgress: Called with the bytes written and the bytes expected (-1 when unknown).
    init(
        resumeKey: String, workDirectory: URL = AppPaths.partialDownloads, maximumBytes: Int64 = defaultMaximumBytes,
        configuration: URLSessionConfiguration = makeConfiguration(),
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.onProgress = onProgress
        self.workDirectory = workDirectory
        self.maximumBytes = maximumBytes
        self.configuration = configuration
        resumeFile = workDirectory.appending(path: "\(resumeKey).resume")
    }

    /// The session configuration of a download: no cache, no cookies, TLS 1.2 or later.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    /// The name of the resume file for `url`: a hash of the whole URL. A file name is not enough: Debian's `mini.iso` and a
    /// vendor's next build share one, and partial data of one must never be offered to the other.
    static func resumeKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).hexString
    }

    /// The task that fetches `url`: a continuation of the saved partial data if it is for exactly this URL, otherwise a new
    /// one. Resume data that names another URL (left under a colliding key, or damaged) is deleted, not followed.
    private func makeTask(in session: URLSession, for url: URL) -> URLSessionDownloadTask {
        guard let data = try? Data(contentsOf: resumeFile) else { return session.downloadTask(with: url) }
        let resumed = session.downloadTask(withResumeData: data)
        if resumed.originalRequest?.url == url { return resumed }
        Log.network.notice("Discarding saved partial data that is not for this download")
        try? FileManager.default.removeItem(at: resumeFile)
        // Its cancellation is reported to the delegate, which ignores any task but the current one.
        resumed.cancel()
        return session.downloadTask(with: url)
    }

    private func isCurrent(_ task: URLSessionTask) -> Bool {
        state.withLock { $0.task === task }
    }

    /// Downloads `url` to a temporary file that the caller must move into place.
    /// - Throws: `CancellationError` if the calling task is cancelled; resume data is kept for the next attempt.
    func download(from url: URL) async throws -> URL {
        _ = try DownloadPolicy.validate(url)
        try AppPaths.createPrivateDirectory(workDirectory)

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = state.withLock { state -> URLSessionDownloadTask? in
                    guard !state.cancelled else { return nil }
                    let task = makeTask(in: session, for: url)
                    state.continuation = continuation
                    state.task = task
                    state.source = url
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

    /// Stops a transfer whose announced size, or whose size so far, is over the cap. `totalBytesExpectedToWrite` is -1 when
    /// the server announces nothing, so a chunked body is caught by the bytes written.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard isCurrent(downloadTask) else { return }
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            let first = state.withLock { state -> Bool in
                defer { state.exceeded = true }
                return !state.exceeded
            }
            if first { downloadTask.cancel() }
            return
        }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Fails the download as too large if it went over the cap; returns whether it did.
    private func failIfTooLarge(fileSize: Int64? = nil) -> Bool {
        let source = state.withLock { state -> URL? in
            if let fileSize, fileSize > maximumBytes { state.exceeded = true }
            return state.exceeded ? state.source : nil
        }
        guard let source else { return false }
        // The partial data is over the cap too; resuming it would only fail again.
        try? FileManager.default.removeItem(at: resumeFile)
        finish(with: .failure(SetupError.responseTooLarge(source)))
        return true
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard isCurrent(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: resumeFile)
            finish(with: .failure(SetupError.badResponse(downloadTask.originalRequest?.url ?? location, http.statusCode)))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
        guard !failIfTooLarge(fileSize: size) else { return }
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
        guard let error, isCurrent(task) else { return }
        guard !failIfTooLarge() else { return }
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

/// The shared download cache and the copy of an installer each machine keeps.
///
/// The cache is never a live attachment target: a machine gets its own copy-on-write clone of the verified file in its
/// bundle, so nothing that happens to the cache afterwards (another download, a damaged or replaced file, clearing the
/// images) can change what a machine boots from.
enum ImageStore {
    /// The folder of the cache that holds the file `remote` downloads to, inside `imagesDirectory`.
    ///
    /// A file is filed under the SHA-256 it must have, so two machines that ask for one file name with different
    /// checksums (a file whose content changes under a fixed name) never share, overwrite or delete each other's file. A
    /// download without a usable SHA-256 is filed under a hash of what it claims instead, or of its URL if it claims
    /// nothing. The checksum comes from remote data or a configuration file, so it never becomes a path as it is.
    static func cacheDirectory(for remote: URL, checksum: Checksum?, in imagesDirectory: URL) -> URL {
        let key: String
        if let checksum, checksum.algorithm == .sha256, checksum.value.lowercased().isLowercaseHexadecimal(digits: 64) {
            key = checksum.value.lowercased()
        } else {
            let claim = checksum.map { "\($0.algorithm.rawValue):\($0.value.lowercased())" } ?? remote.absoluteString
            key = "claim-" + SHA256.hash(data: Data(claim.utf8)).hexString
        }
        return imagesDirectory.appending(path: key, directoryHint: .isDirectory)
    }

    /// Whether a regular file is at `url`. A link or any other kind of entry is refused, never followed.
    static func regularFileExists(at url: URL) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SetupError.notARegularFile(url.lastPathComponent) }
        return true
    }

    /// The cached file at `destination` if it is still good, or nil if there is none or it no longer matches `checksum`.
    ///
    /// A cached file is reused only after its checksum and, when the vendor signs the installer, its signature are checked
    /// again: a corrupted or replaced file must never reach an installer. The cache keys a file by its checksum, so one that
    /// fails is damaged, belongs to no other machine, and is deleted so the caller downloads a fresh one. Without a checksum
    /// or a signature there is nothing to verify against and the file is reused as it is.
    /// - Throws: `SetupError.notARegularFile` if a link or another kind of entry is at `destination`.
    @MainActor
    static func validCachedFile(at destination: URL, checksum: Checksum?, signature: PGP.Check? = nil, job: SetupJob) async throws -> URL? {
        guard try regularFileExists(at: destination) else { return nil }
        guard checksum != nil || signature != nil else { return destination }
        job.title = "Checking \(destination.lastPathComponent)"
        job.fraction = nil
        do {
            try await verify(destination, named: destination.lastPathComponent, checksum: checksum, signature: signature)
            return destination
        } catch SetupError.checksumMismatch {
            Log.storage.notice("Cached \(destination.lastPathComponent, privacy: .public) is damaged; downloading again")
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

    /// Puts `file`, which the caller has verified, at `destination`. A file that got there meanwhile (another setup that
    /// finished the same download, or one planted) is replaced by the verified one, not trusted and not left in the way.
    static func install(_ file: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if try regularFileExists(at: destination) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
            return
        }
        do {
            try fileManager.moveItem(at: file, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Another setup won the race between the check and the move.
            _ = try fileManager.replaceItemAt(destination, withItemAt: file)
        }
    }

    /// The most a macOS restore image may be: about twice the largest one so far.
    static let restoreImageMaximumBytes: Int64 = 48 << 30

    /// Downloads `remote` into the shared image cache (or reuses it), verifying the checksum and the signature when known.
    ///
    /// The download is cancelled and `SetupError.responseTooLarge` thrown as soon as the server announces more than
    /// `maximumBytes`, or sends more.
    ///
    /// The result is a file this call verified, or found already verified, in the cache. A machine must not attach it;
    /// `keepInstaller(_:in:)` gives the machine a copy.
    @MainActor
    static func fetch(
        _ remote: URL, checksum: Checksum?, signature: PGP.Check? = nil, maximumBytes: Int64 = FileDownloader.defaultMaximumBytes,
        job: SetupJob, imagesDirectory: URL = AppPaths.images, configuration: URLSessionConfiguration = FileDownloader.makeConfiguration()
    ) async throws -> URL {
        _ = try DownloadPolicy.validate(remote)
        let name = try DownloadPolicy.cacheFileName(for: remote)
        let directory = cacheDirectory(for: remote, checksum: checksum, in: imagesDirectory)
        let destination = directory.appending(path: name)
        try AppPaths.createPrivateDirectory(directory)
        if let cached = try await validCachedFile(at: destination, checksum: checksum, signature: signature, job: job) { return cached }

        job.title = "Downloading \(name)"
        job.fraction = 0
        let throttle = Throttle(interval: 0.25)
        let downloader = FileDownloader(
            resumeKey: FileDownloader.resumeKey(for: remote),
            workDirectory: imagesDirectory.appending(path: ".partial", directoryHint: .isDirectory),
            maximumBytes: maximumBytes, configuration: configuration
        ) { written, total in
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
        try install(temporary, at: destination)
        return destination
    }

    /// Gives a machine its own copy of the installer in `cached`: a copy-on-write clone in the bundle (ADR-0003), made under
    /// a temporary name and renamed into place so a crash never leaves half a file. Cloning shares the blocks, so the copy
    /// costs no space until the cache is cleared.
    /// - Returns: The path the machine's configuration stores.
    static func keepInstaller(_ cached: URL, in bundle: VMBundle) throws -> URL {
        guard try regularFileExists(at: cached) else { throw SetupError.missingFile(cached.path) }
        let staging = bundle.url.appending(path: ".Installer-\(UUID().uuidString).partial")
        try APFS.clone(cached, to: staging)
        do {
            try install(staging, at: bundle.installer)
        } catch {
            bundle.remove(staging)
            throw error
        }
        return bundle.installer
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
