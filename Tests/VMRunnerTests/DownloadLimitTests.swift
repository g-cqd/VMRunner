import Foundation
import Testing

@testable import VMRunner

struct DownloadSizeLimitTests {
    private let cap: Int64 = 1000

    private func download(_ reply: StubURLProtocol.Reply, in directory: URL) async throws -> URL {
        let url = try #require(URL(string: "https://updates.cdn-apple.com/stub-\(UUID().uuidString)/image.iso"))
        StubURLProtocol.serve(reply, at: url)
        let downloader = FileDownloader(
            resumeKey: "image.iso", workDirectory: directory, maximumBytes: cap, configuration: StubURLProtocol.configuration()
        ) { _, _ in }
        return try await downloader.download(from: url)
    }

    /// Runs the download of `reply` and expects `responseTooLarge`, with nothing left in the work directory.
    private func expectRefused(_ reply: StubURLProtocol.Reply) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await download(reply, in: directory)
            Issue.record("the download should have been refused")
        } catch SetupError.responseTooLarge {
            // expected
        } catch {
            Issue.record("expected responseTooLarge, got \(error)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty, "an oversized download must leave no partial file or resume data behind: \(leftovers)")
    }

    @Test func aContentLengthAboveTheCapIsRefused() async throws {
        try await expectRefused(
            StubURLProtocol.Reply(headers: ["Content-Length": "5000000000"], chunks: [Data(repeating: 1, count: 200)]))
    }

    @Test func aChunkedBodyAboveTheCapIsRefused() async throws {
        // No Content-Length: the server just keeps sending.
        try await expectRefused(StubURLProtocol.Reply(chunks: Array(repeating: Data(repeating: 2, count: 400), count: 50)))
    }

    @Test func aBodyThatLiesAboutItsLengthIsStoppedByTheBytesWritten() async throws {
        try await expectRefused(StubURLProtocol.Reply(headers: ["Content-Length": "100"], chunks: [Data(repeating: 3, count: 5000)]))
    }

    @Test func aBodyWithinTheCapIsDownloaded() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = Data(repeating: 4, count: Int(cap))

        let file = try await download(
            StubURLProtocol.Reply(headers: ["Content-Length": String(body.count)], chunks: [body]), in: directory)

        #expect(try Data(contentsOf: file) == body)
    }

    @Test func everyCatalogImageHasACeilingAboveItsSizeAndNotFarAboveIt() throws {
        let units: [Character: Double] = ["M": 1_048_576, "G": 1_073_741_824]
        for image in LinuxCatalog.images + LinuxCatalog.candidates {
            let parts = image.approximateSize.dropFirst().split(separator: " ")
            let size = try #require(parts.first.flatMap { Double($0) })
            let unit = try #require(parts.last?.first.flatMap { units[$0] })
            let bytes = Int64(size * unit)
            #expect(image.maximumBytes > bytes, "\(image.id) must fit under its own ceiling")
            #expect(image.maximumBytes <= 4 * bytes + (1 << 30), "\(image.id) ceiling is too loose to bound anything")
        }
    }
}
