import Foundation
import TestKit
import Testing

@testable import VMRunner

struct DownloadResumeTests {
    @Test func resumeKeysDifferForURLsThatShareAFileName() throws {
        let first = try #require(
            URL(string: "https://deb.debian.org/debian/dists/stable/main/installer-arm64/current/images/netboot/mini.iso"))
        let second = try #require(
            URL(string: "https://deb.debian.org/debian/dists/oldstable/main/installer-arm64/current/images/netboot/mini.iso"))

        let keys = [FileDownloader.resumeKey(for: first), FileDownloader.resumeKey(for: second)]

        #expect(keys[0] != keys[1])
        #expect(keys.allSatisfy { $0.utf8.count == 64 && $0.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) } })
        #expect(FileDownloader.resumeKey(for: first) == keys[0], "the key is stable, so a later attempt finds its partial data")
    }

    @Test func partialDataOfAnotherURLIsDiscardedNotResumed() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(URL(string: "https://updates.cdn-apple.com/stub-\(UUID().uuidString)/a/mini.iso"))
        let second = try #require(URL(string: "https://updates.cdn-apple.com/stub-\(UUID().uuidString)/b/mini.iso"))
        StubURLProtocol.serve(
            StubURLProtocol.Reply(
                headers: ["Content-Length": "100000", "ETag": "\"v1\"", "Accept-Ranges": "bytes"],
                chunks: [Data(repeating: 1, count: 20000)], stalls: true),
            at: first)
        StubURLProtocol.serve(Data("the second file".utf8), at: second)

        // An interrupted download of the first URL leaves resume data. Both use one key, as a colliding file name would.
        let progress = AsyncEventProbe<Int64>()
        let record: @Sendable (Int64, Int64) -> Void = { written, _ in progress.record(written) }
        let interrupted = FileDownloader(
            resumeKey: "shared", workDirectory: directory, configuration: StubURLProtocol.configuration(), onProgress: record)
        let running = Task { try await interrupted.download(from: first) }
        _ = try await progress.wait(forAtLeast: 1)
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let resumeFile = directory.appending(path: "shared.resume")
        try #require(FileManager.default.fileExists(atPath: resumeFile.path), "the interrupted download must leave resume data")

        let later = FileDownloader(resumeKey: "shared", workDirectory: directory, configuration: StubURLProtocol.configuration()) { _, _ in
        }
        let file = try await later.download(from: second)

        #expect(try Data(contentsOf: file) == Data("the second file".utf8))
        #expect(StubURLProtocol.requestCount(for: second) == 1)
        #expect(StubURLProtocol.requestCount(for: first) == 1, "the first URL must not be requested again for the second download")
        #expect(!FileManager.default.fileExists(atPath: resumeFile.path))
    }
}
