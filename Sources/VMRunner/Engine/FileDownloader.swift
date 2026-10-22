import CryptoKit
import Foundation
import Synchronization
import os

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

    /// The session configuration of a download: the app's cookieless, cacheless one, which waits for connectivity.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = Fetch.makeConfiguration()
        configuration.waitsForConnectivity = true
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
