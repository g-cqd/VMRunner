import CryptoKit
import Foundation
import os

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
            let claim = checksum.map { "\($0.algorithm.name):\($0.value.lowercased())" } ?? remote.absoluteString
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
        // Refuse before downloading what cannot be verified afterwards.
        if let checksum, checksum.algorithm != .sha256 { throw SetupError.weakChecksum(name) }
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

    /// A copy-on-write clone of the verified `file` beside it, under a name no other setup uses, for one install to read
    /// (ADR-0003, ADR-0031): the shared file may be replaced or removed while the install runs, the clone may not. The name
    /// keeps the file's own name at its end, so the extension is unchanged. The caller deletes the clone.
    /// - Throws: `SetupError.notARegularFile` for a link or another kind of entry, `SetupError.missingFile` when nothing is there.
    static func installCopy(of file: URL) throws -> URL {
        guard try regularFileExists(at: file) else { throw SetupError.missingFile(file.path) }
        let copy = file.deletingLastPathComponent().appending(path: ".install-\(UUID().uuidString)-\(file.lastPathComponent)")
        try APFS.clone(file, to: copy)
        return copy
    }

    /// Whether `path` names a file directly in `imagesDirectory`, where the cache kept downloads before it filed them by
    /// checksum (`Images/<name>`, not `Images/<sha256>/<name>`, ADR-0031).
    static func isInFlatCache(_ path: String, imagesDirectory: URL = AppPaths.images) -> Bool {
        let parent = URL(filePath: path).deletingLastPathComponent().standardizedFileURL.pathComponents
        return parent == imagesDirectory.standardizedFileURL.pathComponents
    }
}
