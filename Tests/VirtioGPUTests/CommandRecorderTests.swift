import Testing

@testable import VirtioGPU

struct CommandRecorderTests {
    private func entry(_ sequence: UInt64, _ type: GPUCommandType, _ response: GPUResponseType? = .okNoData) -> CommandLogEntry {
        CommandLogEntry(
            sequence: sequence, queue: .control, commandType: type.rawValue, resourceID: 7, responseType: response, byteCount: 24)
    }

    @Test
    func theFirstRequestOfEachKnownTypeIsReportedOnce() {
        var recorder = CommandRecorder()
        #expect(recorder.record(entry(1, .resourceCreate2D), atMilliseconds: 5) == ["first resourceCreate2D request at 5 ms"])
        #expect(recorder.record(entry(2, .resourceCreate2D), atMilliseconds: 6).isEmpty)
        let unknown = CommandLogEntry(
            sequence: 3, queue: .control, commandType: 0x9999, resourceID: 0, responseType: .errUnspec, byteCount: 24)
        #expect(recorder.record(unknown, atMilliseconds: 7).isEmpty, "an unknown type prints nothing: the output stays bounded")
    }

    @Test
    func theRequestAfterTheFirstDisplayInformationAnswerIsTimed() {
        var recorder = CommandRecorder()
        _ = recorder.record(entry(1, .getDisplayInfo, .okDisplayInfo), atMilliseconds: 100)
        #expect(recorder.displayInfoAnsweredAt == 100)
        #expect(recorder.requestAfterDisplayInfoAt == nil, "the answer itself is not the next request")
        let lines = recorder.record(entry(2, .resourceCreate2D), atMilliseconds: 130)
        #expect(lines.contains("the guest sent a request 30 ms after the display information was given back"))
        #expect(recorder.requestAfterDisplayInfoAt == 130)
        #expect(recorder.record(entry(3, .resourceUnref), atMilliseconds: 140).count == 1, "only the first request after it is timed")
    }

    @Test
    func aDisplayInformationRequestAfterAConfigurationUpdateIsReported() {
        var recorder = CommandRecorder()
        _ = recorder.record(entry(1, .getDisplayInfo, .okDisplayInfo), atMilliseconds: 10)
        _ = recorder.record(entry(2, .resourceFlush), atMilliseconds: 20)
        recorder.noteConfigurationUpdate(atMilliseconds: 1000)
        recorder.noteConfigurationUpdate(atMilliseconds: 2000)
        #expect(recorder.configurationUpdatedAt == 1000, "only the first update is watched")
        #expect(recorder.record(entry(3, .resourceFlush), atMilliseconds: 1100).isEmpty)
        let lines = recorder.record(entry(4, .getDisplayInfo, .okDisplayInfo), atMilliseconds: 1250)
        #expect(lines == ["display info requested again after the configuration update, 250 ms later"])
        #expect(recorder.displayInfoAfterUpdateAt == 1250)
    }

    @Test
    func theReportHasTheCountsTheFindingsAndTheHeldRequestsWithTheirTimes() {
        var recorder = CommandRecorder(capacity: 2)
        _ = recorder.record(entry(1, .getDisplayInfo, .okDisplayInfo), atMilliseconds: 10)
        _ = recorder.record(entry(2, .resourceCreate2D), atMilliseconds: 20)
        _ = recorder.record(
            CommandLogEntry(sequence: 3, queue: .cursor, commandType: 0x0301, resourceID: 0, responseType: nil, byteCount: 56),
            atMilliseconds: 30)
        let report = recorder.report(extra: ["oversized requests: 0"])
        #expect(report.hasPrefix("requests: 3\n"))
        #expect(report.contains("display info answered at: 10 ms\n"))
        #expect(report.contains("first request after that answer at: 20 ms\n"))
        #expect(report.contains("configuration updated at: never\n"))
        #expect(report.contains("oversized requests: 0\nlast 2 requests"))
        #expect(report.hasSuffix("20 #2 control 0x101 7 0x1100 24\n30 #3 cursor 0x301 0 - 56\n"), "the oldest entry left the ring")
    }
}
