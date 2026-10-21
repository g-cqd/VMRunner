import CryptoKit
import Foundation
import TestKit
import Testing

@testable import VMRunner

/// The throughput of the checksum digests behind `Checksums.hexDigest(of:algorithm:)`, over a fixed 64 MiB file that is
/// already in the page cache after the first round. Run by `swift run vmr check bench`.
@Suite(.serialized, .tags(.bench), .benchmarksRequested)
struct ChecksumBenchmarks {
    private static let size = 64 << 20

    @Test(arguments: [("sha256", Checksum.Algorithm.sha256), ("sha1", .sha1)])
    func digestThroughput(name: String, algorithm: Checksum.Algorithm) async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(pattern(Self.size))
        let file = directory.appending(path: "buffer.bin")
        try bytes.write(to: file)
        let expected =
            switch algorithm {
            case .sha256: SHA256.hash(data: bytes).hexString
            case .sha1: Insecure.SHA1.hash(data: bytes).hexString
            }

        var digest = ""
        let rate = try await measureRate(units: Double(Self.size / (1 << 20))) {
            digest = try await Checksums.hexDigest(of: file, algorithm: algorithm)
        }
        #expect(digest == expected, "the benchmark must hash the whole buffer")
        // Wall-clock rates are reported only: ten runs on a shared machine spread by 60-80%. Retired instructions spread by under 1%.
        recordBenchmark(
            BenchmarkResult(
                name: "checksum.\(name).throughput", unit: "MiB/s", direction: .higher, value: rate.perSecond, tolerance: 0.3,
                enforced: false))
        if let instructions = rate.instructionsPerUnit {
            recordBenchmark(
                BenchmarkResult(
                    name: "checksum.\(name).instructionsPerMiB", unit: "instructions/MiB", direction: .lower, value: instructions,
                    tolerance: 0.03))
        }
    }
}
