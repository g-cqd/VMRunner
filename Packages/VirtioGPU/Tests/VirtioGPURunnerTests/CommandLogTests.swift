import Testing

@testable import VirtioGPURunnerCore

/// The bounded log of requests and its counts.
struct CommandLogTests {
    private static func entry(_ sequence: UInt64, type: UInt32 = 0x0100, response: GPUResponseType? = .okNoData) -> CommandLogEntry {
        CommandLogEntry(sequence: sequence, queue: .control, commandType: type, resourceID: 0, responseType: response, byteCount: 24)
    }

    @Test
    func theRingKeepsTheLastEntriesOldestFirst() {
        var log = CommandLog(capacity: 3)
        for sequence in 1...2 { log.append(Self.entry(UInt64(sequence))) }
        #expect(log.entries.map(\.sequence) == [1, 2])
        for sequence in 3...7 { log.append(Self.entry(UInt64(sequence))) }
        #expect(log.entries.map(\.sequence) == [5, 6, 7])
        #expect(log.total == 7)
        #expect(CommandLog(capacity: 0).capacity == 1)
    }

    @Test
    func theSummaryCountsEveryRequestAndAnswerSinceTheStart() {
        var log = CommandLog(capacity: 2)
        log.append(Self.entry(1, type: 0x0101))
        log.append(Self.entry(2, type: 0x0101, response: .errOutOfMemory))
        log.append(Self.entry(3, type: 0x0300, response: nil))
        #expect(
            log.summary() == [
                "requests: 3", "command 0x101: 2", "command 0x300: 1", "response 0x1100: 1", "response 0x1201: 1",
            ])
    }

    @Test
    func aGuestCannotGrowTheCountsWithEndlessNewTypes() {
        var log = CommandLog(capacity: 4)
        for type in 0..<10_000 { log.append(Self.entry(UInt64(type), type: UInt32(type) | 0x8000_0000)) }
        let summary = log.summary()
        #expect(summary.count <= 1 + 65 + 1)
        #expect(summary.contains("command 0xffffffff: \(10_000 - 64)"))
        #expect(log.entries.count == 4)
    }
}
