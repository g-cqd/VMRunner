import Foundation
import TestKit
import Testing

@testable import VMRunner

/// The publisher: the files are written at once, again after each interval, and at a change of the network path; what is
/// not shared has no file.
@MainActor
struct HostInfoPublisherTests {
    /// Facts a test changes between two writes.
    private final class FactsBox {
        var facts = HostFacts(timeZone: "Zone/One")
    }

    private func text(_ name: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    @Test func itWritesAtOnceThenEveryIntervalAndRemovesWhatIsNotShared() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("stale".utf8).write(to: directory.appending(path: "battery"))
        let clock = TestClock()
        let box = FactsBox()
        let (paths, feed) = AsyncStream.makeStream(of: HostNetworkPath.self)
        let publisher = HostInfoPublisher(
            directory: directory, sharing: HostInfoSharing(timeZone: true), clock: clock, paths: { paths },
            read: { _ in box.facts })
        publisher.start()
        #expect(text("timezone", in: directory) == "identifier=Zone/One\n")
        #expect(text("battery", in: directory) == nil, "a category that is off has no file")

        try await clock.waitForSleepers(atLeast: 1)
        box.facts.timeZone = "Zone/Two"
        clock.advance(by: HostInfoPublisher.interval)
        try await clock.waitForSleepers(atLeast: 1)
        #expect(text("timezone", in: directory) == "identifier=Zone/Two\n")
        feed.finish()
    }

    @Test func aRewriteKeepsTheSameFileSoAGuestNeverFindsItMissing() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let box = FactsBox()
        box.facts.timeZone = "America/Argentina/Buenos_Aires"
        let (paths, feed) = AsyncStream.makeStream(of: HostNetworkPath.self)
        let publisher = HostInfoPublisher(
            directory: directory, sharing: HostInfoSharing(timeZone: true), clock: clock, paths: { paths },
            read: { _ in box.facts })
        publisher.start()
        let file = directory.appending(path: "timezone").path
        let before = try #require(FileManager.default.attributesOfItem(atPath: file)[.systemFileNumber] as? NSNumber)

        try await clock.waitForSleepers(atLeast: 1)
        box.facts.timeZone = "UTC"
        clock.advance(by: HostInfoPublisher.interval)
        try await clock.waitForSleepers(atLeast: 1)
        #expect(text("timezone", in: directory) == "identifier=UTC\n", "a shorter text leaves nothing of the longer one")
        let after = try #require(FileManager.default.attributesOfItem(atPath: file)[.systemFileNumber] as? NSNumber)
        #expect(after == before, "the file is written in place, not replaced by another one")
        feed.finish()
    }

    @Test func aNetworkChangeIsWrittenAtOnce() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (paths, feed) = AsyncStream.makeStream(of: HostNetworkPath.self)
        let reads = AsyncEventProbe<String>()
        let publisher = HostInfoPublisher(
            directory: directory, sharing: HostInfoSharing(networkPath: true), clock: TestClock(), paths: { paths },
            read: { path in
                reads.record(path?.interface.rawValue ?? "no sample")
                return HostFacts(network: path)
            })
        publisher.start()
        #expect(text("network", in: directory) == "status=unknown\n")
        feed.yield(HostNetworkPath(isSatisfied: true, interface: .ethernet))
        _ = try await reads.wait(forAtLeast: 2)
        #expect(text("network", in: directory) == "status=satisfied\ninterface=ethernet\nexpensive=0\nconstrained=0\n")
        feed.finish()
    }
}
