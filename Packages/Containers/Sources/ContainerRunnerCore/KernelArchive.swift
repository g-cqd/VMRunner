import CryptoKit
public import Foundation

/// Why a kernel archive or image was refused.
public enum KernelArchiveError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(path: String)
    case checksumMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read \(path)"
        case .checksumMismatch(let expected, let actual): "SHA-256 mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// The pinned guest kernel: a release tarball of a Linux kernel built for containers, its SHA-256, and the one file in it
/// that is used. The pins were computed from a download made for the runner, not copied from a web page.
public enum KernelArchive {
    public static let urlString =
        "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
    public static let fileName = "kata-static-3.17.0-arm64.tar.xz"
    /// SHA-256 of the whole archive (290581648 bytes).
    public static let archiveSHA256 = "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"
    /// The kernel inside the archive: the regular file the archive's `vmlinux.container` link points to (Linux 6.12.28).
    public static let memberPath = "./opt/kata/share/kata-containers/vmlinux-6.12.28-153"
    /// SHA-256 of the extracted kernel image.
    public static let imageSHA256 = "67bac9f416af4cdc9b151e4ba4962d6515e0ad7acc53816761cf964aa6af6ea0"

    /// The `tar` arguments that unpack only ``memberPath`` of `archive` into `directory`.
    public static func extractionArguments(archive: URL, directory: URL) -> [String] {
        ["-x", "-J", "-f", archive.path, "-C", directory.path, memberPath]
    }

    /// Where ``memberPath`` lands under the directory it was extracted into.
    public static func extractedMember(in directory: URL) -> URL {
        directory.appending(path: memberPath, directoryHint: .notDirectory).standardizedFileURL
    }

    /// The lowercase hexadecimal SHA-256 of a file, read in chunks so a large file is never held in memory.
    ///
    /// - Throws: ``KernelArchiveError/unreadable(path:)``.
    public static func sha256(ofFileAt url: URL) throws(KernelArchiveError) -> String {
        let unreadable = KernelArchiveError.unreadable(path: url.path(percentEncoded: false))
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw unreadable
        }
        return hasher.finalize().hexString
    }

    /// Checks a file against an expected SHA-256 (any letter case).
    ///
    /// - Throws: ``KernelArchiveError``.
    public static func verify(fileAt url: URL, expectedSHA256: String) throws(KernelArchiveError) {
        let actual = try sha256(ofFileAt: url)
        let expected = expectedSHA256.lowercased()
        guard actual == expected else { throw .checksumMismatch(expected: expected, actual: actual) }
    }
}

extension Sequence<UInt8> {
    /// Lowercase hexadecimal, two characters per byte.
    fileprivate var hexString: String {
        map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}
