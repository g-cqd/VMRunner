import AppKit
import Foundation
import TestKit
import Testing

@testable import VMRunner

private let millisecond: UInt64 = 1_000_000

struct LatencyHistogramTests {
    @Test func anEmptyHistogramReportsZero() {
        let histogram = LatencyHistogram(threshold: millisecond)
        #expect(histogram.samples == 0)
        #expect(histogram.percentile(50) == 0)
        #expect(histogram.maximum == 0)
    }

    @Test func percentilesStayWithinTheBucketResolutionAndNeverPassTheMaximum() {
        var histogram = LatencyHistogram(threshold: millisecond)
        for microseconds in 1...1_000 { histogram.record(UInt64(microseconds) * 1_000) }

        #expect(histogram.samples == 1_000)
        #expect(histogram.maximum == 1_000_000)
        for percent in [50.0, 90, 99] {
            let exact = UInt64(percent * 10) * 1_000
            let reported = histogram.percentile(percent)
            #expect(reported >= exact, "p\(percent) \(reported) is below the exact \(exact)")
            #expect(reported <= exact + exact / 8, "p\(percent) \(reported) is more than 12.5% above \(exact)")
        }
        #expect(histogram.percentile(100) == histogram.maximum)
        #expect(histogram.percentile(0) >= 1_000)
    }

    @Test func smallValuesAreExact() {
        var histogram = LatencyHistogram(threshold: 100)
        for value: UInt64 in [0, 1, 2, 7] { histogram.record(value) }
        #expect(histogram.percentile(25) == 0)
        #expect(histogram.percentile(50) == 1)
        #expect(histogram.percentile(100) == 7)
    }

    @Test func onlyValuesStrictlyAboveTheThresholdAreCountedOver() {
        var histogram = LatencyHistogram(threshold: millisecond)
        for value in [millisecond - 1, millisecond, millisecond + 1, 5 * millisecond] { histogram.record(value) }
        #expect(histogram.overThreshold == 2)
    }

    @Test func hugeValuesLandInTheLastBucketWithoutTrapping() {
        var histogram = LatencyHistogram(threshold: millisecond)
        histogram.record(.max)
        histogram.record(1 << 41)
        #expect(histogram.samples == 2)
        #expect(histogram.maximum == .max)
        #expect(histogram.percentile(50) == (1 << 40) - 1, "the last bucket ends at 2^40 - 1")
        #expect(histogram.percentile(100) == (1 << 40) - 1)
    }
}

struct InputLatencyRecorderTests {
    @Test func anEventsAgeIsTheTimeSinceItHappenedAndNeverNegative() {
        #expect(InputLatencyRecorder.age(timestamp: 100.000, now: 100.0025) == 2_500_000)
        #expect(InputLatencyRecorder.age(timestamp: 100.0, now: 99.0) == 0, "an event from the future")
        #expect(InputLatencyRecorder.age(timestamp: .nan, now: 5) == 0)
        #expect(InputLatencyRecorder.age(timestamp: 0, now: .infinity) == 0)
        #expect(InputLatencyRecorder.age(timestamp: 0, now: 1e12) == 1_000_000_000_000)
    }

    @Test func aBusyStretchRunsFromWakingToSleepingAndSplitsAtTheFirstLookAtSources() {
        var tracker = LoopStallTracker()
        tracker.wake(at: 1_000)
        tracker.beforeSources(at: 1_400)
        tracker.beforeSources(at: 2_000)
        #expect(tracker.beforeWaiting(at: 3_000) == LoopStallTracker.Stretch(duration: 2_000, wake: 400, passes: 2))
        #expect(tracker.beforeWaiting(at: 4_000) == nil, "already asleep")
    }

    @Test func aLoopSeenOnlyMidStretchIsIgnoredUntilItWakes() {
        var tracker = LoopStallTracker()
        tracker.beforeSources(at: 10)
        #expect(tracker.beforeWaiting(at: 20) == nil)
    }

    @Test func workIsAttributedByNameLongestFirstAndNestedWorkOverlaps() {
        var tracker = LoopStallTracker()
        tracker.wake(at: 0)
        tracker.begin("update", at: 10)
        tracker.begin("layout", at: 20)
        tracker.end(at: 50)
        tracker.end(at: 100)
        tracker.begin("layout", at: 110)
        tracker.end(at: 120)
        tracker.end(at: 130)

        #expect(
            tracker.work == [WorkShare(name: "update", duration: 90, count: 1), WorkShare(name: "layout", duration: 40, count: 2)])
    }

    @Test func aNewStretchForgetsTheLastOnesWorkAndTooManyNamesAreDropped() {
        var tracker = LoopStallTracker()
        tracker.wake(at: 0)
        for index in 0..<(LoopStallTracker.nameLimit + 2) {
            tracker.begin("work\(index)", at: 0)
            tracker.end(at: 1)
        }
        #expect(tracker.work.count == LoopStallTracker.nameLimit)
        tracker.wake(at: 100)
        #expect(tracker.work.isEmpty)
    }

    @Test func aStretchAboveTheThresholdIsReportedWithItsWorkAndOneAtTheThresholdIsNot() {
        var recorder = InputLatencyRecorder(threshold: millisecond)
        recorder.loopWoke(at: 0)
        recorder.workBegan("display update", at: 100)
        recorder.workEnded(at: 900_000)
        #expect(recorder.loopWillSleep(at: millisecond) == nil, "exactly at the threshold is not a stall")

        recorder.loopWoke(at: 5_000_000)
        recorder.loopWillLookAtSources(at: 5_100_000)
        recorder.workBegan("display update", at: 5_200_000)
        recorder.workEnded(at: 6_700_000)
        let stall = recorder.loopWillSleep(at: 7_000_000)

        #expect(
            stall
                == LoopStall(
                    duration: 2_000_000, wake: 100_000, passes: 1, work: [WorkShare(name: "display update", duration: 1_500_000, count: 1)])
        )
        #expect(recorder.total.busy.samples == 2)
        #expect(recorder.total.busy.overThreshold == 1)
    }

    @Test func theWindowRollsOverButTheTotalKeepsEverything() {
        var recorder = InputLatencyRecorder(threshold: millisecond)
        recorder.recordEvent(.key, age: 200_000)
        recorder.recordEvent(.pointer, age: 3 * millisecond)
        let first = recorder.rollWindow()
        recorder.recordEvent(.key, age: 400_000)
        let second = recorder.rollWindow()

        #expect(first.key.samples == 1)
        #expect(first.pointer.overThreshold == 1)
        #expect(second.key.samples == 1)
        #expect(second.pointer.samples == 0)
        #expect(recorder.total.key.samples == 2)
        #expect(recorder.total.events(.pointer).samples == 1)
    }

    @Test func onlyTheWorstFewStallsAreKeptWorstFirst() {
        var recorder = InputLatencyRecorder(threshold: millisecond)
        var clock: UInt64 = 0
        for length in [3, 9, 2, 7, 5] as [UInt64] {
            recorder.loopWoke(at: clock)
            clock += length * millisecond
            recorder.loopWillSleep(at: clock)
            clock += millisecond
        }
        #expect(recorder.total.worstStalls.map(\.duration) == [9, 7, 5].map { $0 * millisecond })
    }
}

struct InputLatencySummaryTests {
    @Test func millisecondsAreRoundedToThreeDecimals() {
        #expect(InputLatencyStats.milliseconds(0) == "0.000ms")
        #expect(InputLatencyStats.milliseconds(499) == "0.000ms")
        #expect(InputLatencyStats.milliseconds(500) == "0.001ms")
        #expect(InputLatencyStats.milliseconds(1_000_000) == "1.000ms")
        #expect(InputLatencyStats.milliseconds(12_345_678) == "12.346ms")
        #expect(InputLatencyStats.milliseconds(1_005_000) == "1.005ms")
    }

    @Test func theSummaryLineNamesEverySeriesAndTheWorstStall() {
        var recorder = InputLatencyRecorder(threshold: millisecond)
        recorder.recordEvent(.key, age: 100_000)
        recorder.recordEvent(.key, age: 300_000)
        recorder.loopWoke(at: 0)
        recorder.workBegan("display layout", at: 0)
        recorder.workEnded(at: 2_000_000)
        recorder.loopWillSleep(at: 4_000_000)

        let line = recorder.total.summaryLine(label: "total")
        #expect(line.hasPrefix("input latency [total, over 1.000ms]: key n=2 p50="))
        #expect(line.contains("pointer n=0; scroll n=0; main busy n=1 p50=4.000ms"))
        #expect(line.contains("over=1"))
        #expect(line.hasSuffix(" | worst: 4.000ms (wake 4.000ms, 0 passes, display layout 2.000ms)"))
    }
}

struct InputLatencyOptionsTests {
    private func parse(_ arguments: [String] = [], _ environment: [String: String] = [:]) -> InputLatencyOptions.Parsed {
        InputLatencyOptions.parse(arguments: ["VMRunner"] + arguments, environment: environment)
    }

    @Test func itIsOffUnlessAskedFor() {
        #expect(parse().options == nil)
        #expect(parse(["--start", "Machine"]).options == nil)
        #expect(parse(["--input-latency-threshold-ms", "2"]).options == nil, "a setting alone does not turn it on")
        for off in ["", "0", "false", "No"] { #expect(parse([], ["VMR_INPUT_LATENCY": off]).options == nil) }
    }

    @Test func theFlagOrTheEnvironmentTurnsItOnWithDefaults() {
        let expected = InputLatencyOptions()
        #expect(parse(["--input-latency"]) == InputLatencyOptions.Parsed(options: expected))
        #expect(parse([], ["VMR_INPUT_LATENCY": "1"]).options == expected)
        #expect(expected.threshold == 1_000_000)
        #expect(expected.interval == 10)
        #expect(expected.file == nil)
    }

    @Test func valuesComeFromArgumentsThenTheEnvironment() {
        let parsed = parse(
            ["--input-latency", "--input-latency-threshold-ms", "0.5", "--input-latency-file", "/tmp/latency.txt"],
            ["VMR_INPUT_LATENCY_THRESHOLD_MS": "9", "VMR_INPUT_LATENCY_INTERVAL": "30"])
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.options?.threshold == 500_000, "the argument beats the environment")
        #expect(parsed.options?.interval == 30)
        #expect(parsed.options?.file == URL(filePath: "/tmp/latency.txt"))
    }

    @Test func aHomeRelativeFileIsExpanded() {
        let file = parse(["--input-latency", "--input-latency-file", "~/latency.txt"]).options?.file
        #expect(file?.path == NSHomeDirectory() + "/latency.txt")
    }

    @Test(arguments: [
        ["--input-latency-threshold-ms", "0"], ["--input-latency-threshold-ms", "fast"], ["--input-latency-threshold-ms", "5000"],
        ["--input-latency-interval", "0"], ["--input-latency-interval", "2.5"], ["--input-latency-interval", "99999"],
        ["--input-latency-file", "relative.txt"], ["--input-latency-file", "/tmp/directory/"], ["--input-latency-file"],
    ])
    func anUnusableValueKeepsTheDefaultAndWarns(extra: [String]) {
        let parsed = parse(["--input-latency"] + extra)
        #expect(parsed.options == InputLatencyOptions())
        #expect(parsed.warnings.count == 1)
        #expect(parsed.warnings.allSatisfy { !$0.contains("/tmp") && !$0.contains("relative") }, "a warning never repeats a path")
    }
}

struct InputKindTests {
    @Test func eventTypesMapToTheirKind() {
        #expect(InputLatencyMonitor.kind(of: .keyDown) == .key)
        #expect(InputLatencyMonitor.kind(of: .flagsChanged) == .key)
        #expect(InputLatencyMonitor.kind(of: .mouseMoved) == .pointer)
        #expect(InputLatencyMonitor.kind(of: .otherMouseDragged) == .pointer)
        #expect(InputLatencyMonitor.kind(of: .scrollWheel) == .scroll)
        #expect(InputLatencyMonitor.kind(of: .magnify) == .scroll)
        #expect(InputLatencyMonitor.kind(of: .appKitDefined) == nil)
    }
}

@MainActor
struct InputLatencyCollectorTests {
    private let clock = TestClock()
    private let lines = AsyncEventProbe<String>()

    private func makeCollector() -> InputLatencyCollector {
        InputLatencyCollector(threshold: millisecond) { [lines] line in lines.record(line) }
    }

    @Test func eachReportCoversOnlyTheTimeSinceTheLastOne() async throws {
        let collector = makeCollector()
        collector.startReporting(every: .seconds(10), clock: clock)
        try await clock.waitForSleepers(atLeast: 1)

        collector.recordEvent(.key, age: 200_000)
        clock.advance(by: .seconds(9))
        #expect(lines.events.isEmpty, "nothing before the interval has passed")
        clock.advance(by: .seconds(1))
        let first = try await lines.wait(forAtLeast: 1)
        #expect(first[0].contains("key n=1"))

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(10))
        let both = try await lines.wait(forAtLeast: 2)
        #expect(both[1].contains("key n=0"), "the second window starts empty")
        #expect(collector.totalLine().contains("key n=1"), "the total keeps the whole run")
        collector.stopReporting()
    }

    @Test func stoppingEndsTheReporting() async throws {
        let collector = makeCollector()
        collector.startReporting(every: .seconds(10), clock: clock)
        try await clock.waitForSleepers(atLeast: 1)
        collector.stopReporting()
        clock.advance(by: .seconds(60))
        for _ in 0..<50 { await Task.yield() }
        #expect(lines.events.isEmpty)
        #expect(clock.sleeperCount == 0)
    }
}

@MainActor
struct MeasuredWindowTests {
    @Test func anEventWithoutAWindowIsMeasuredAgainstTheKeyWindow() throws {
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0))
        #expect(event.window == nil, "a pointer event without a window number has no window")
        let key = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(InputLatencyMonitor.measuredWindow(of: event, keyWindow: key) === key)
        #expect(InputLatencyMonitor.measuredWindow(of: event, keyWindow: nil) == nil)
    }
}
