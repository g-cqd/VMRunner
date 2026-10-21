import Foundation
import Testing

@testable import DevTools

/// The archive downloader's limits. The `https:` transfer itself needs a network, so its pieces are tested apart: the
/// redirect rule, and the size limit through the `file:` path, which shares it.
struct DownloaderTests {
    @Test
    func aRedirectIsFollowedOnlyWhenItStaysOnHTTPS() {
        #expect(TransferGuard.allowsRedirect(to: URL(string: "https://objects.example/releases/a.zip")))
        #expect(!TransferGuard.allowsRedirect(to: URL(string: "http://objects.example/releases/a.zip")))
        #expect(!TransferGuard.allowsRedirect(to: URL(string: "file:///etc/passwd")))
        #expect(!TransferGuard.allowsRedirect(to: nil))
    }

    @Test
    func anArchiveLargerThanTheLimitIsRefusedAndNotCopied() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "big.zip")
            try Data(count: 64).write(to: source)
            let destination = directory.appending(path: "copy.zip")

            let tooSmall = URLArchiveDownloader(maximumBytes: 63)
            let error = await #expect(throws: ToolError.self) { try await tooSmall.download(from: source, to: destination) }
            #expect(error?.message.contains("is larger than 63 bytes; refusing it") == true, "\(error?.message ?? "no error")")
            #expect(!FileManager.default.fileExists(atPath: destination.path))

            let enough = URLArchiveDownloader(maximumBytes: 64)
            try await enough.download(from: source, to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test
    func theDefaultLimitLeavesRoomForTheRealReleases() {
        #expect(URLArchiveDownloader().maximumBytes == 256 << 20)
    }
}
