import Testing

@testable import VMRunner

struct WindowsDisplayTimingTests {
    @Test func metadataIsPolledOncePerSecondAndOnlyPersistentLossTimesOut() {
        var timing = WindowsDisplayTiming()
        #expect(timing.needsMetadata(at: .zero))
        timing.readMetadata(at: .zero)
        #expect(!timing.needsMetadata(at: .milliseconds(999)))
        #expect(timing.needsMetadata(at: .seconds(1)))
        #expect(!timing.timedOut(at: .seconds(59)))
        #expect(timing.timedOut(at: .seconds(60)))
        timing.mappedFrame(at: .seconds(60))
        timing.readMetadata(at: .seconds(61))
        #expect(!timing.timedOut(at: .seconds(62)), "a transient metadata read failure after startup is not a boot failure")
        #expect(!timing.timedOut(at: .seconds(119)))
        #expect(timing.timedOut(at: .seconds(120)))
        timing.mappedFrame(at: .seconds(121))
        #expect(!timing.timedOut(at: .seconds(121)))
    }
}
