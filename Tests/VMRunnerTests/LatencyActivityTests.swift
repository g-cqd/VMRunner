import Foundation
import Testing

@testable import VMRunner

/// Stands in for the process: records which activities began and ended instead of telling the system.
private final class RecordingHost: ActivityHost {
    private(set) var begun: [(options: ProcessInfo.ActivityOptions, reason: String)] = []
    private(set) var ended = 0

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        begun.append((options, reason))
        return NSObject()
    }

    func endActivity(_ activity: any NSObjectProtocol) { ended += 1 }
}

@MainActor
struct LatencyActivityTests {
    private let host = RecordingHost()
    private let owners = [NSObject(), NSObject()]
    private var first: ObjectIdentifier { ObjectIdentifier(owners[0]) }
    private var second: ObjectIdentifier { ObjectIdentifier(owners[1]) }

    private func makeActivity(enabled: Bool = true) -> LatencyActivity {
        LatencyActivity(host: host, isEnabled: enabled)
    }

    @Test func itAsksForLatencyCriticalWithoutKeepingTheMacAwake() {
        let options = LatencyActivity.options
        #expect(options.contains(.latencyCritical))
        #expect(options.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(!options.contains(.idleSystemSleepDisabled), "a running guest is no reason to stop an idle Mac sleeping")
    }

    @Test func theFirstMachineBeginsOneActivityAndTheLastEndsIt() {
        let activity = makeActivity()
        #expect(!activity.isHeld)

        activity.hold(for: first)
        activity.hold(for: second)
        #expect(activity.isHeld)
        #expect(host.begun.count == 1, "two machines share one activity")
        #expect(host.begun.first?.options == LatencyActivity.options)

        activity.release(for: first)
        #expect(activity.isHeld && host.ended == 0, "one machine still runs")
        activity.release(for: second)
        #expect(!activity.isHeld)
        #expect(host.ended == 1)
    }

    @Test func holdingTwiceForTheSameMachineCountsOnceAndReleasingAStrangerDoesNothing() {
        let activity = makeActivity()
        activity.hold(for: first)
        activity.hold(for: first)
        activity.release(for: second)
        #expect(activity.isHeld)

        activity.release(for: first)
        #expect(!activity.isHeld)
        #expect(host.begun.count == 1 && host.ended == 1)
    }

    @Test func aDisabledSettingHoldsNothingAndTurningItOnPicksUpRunningMachines() {
        let activity = makeActivity(enabled: false)
        activity.hold(for: first)
        #expect(!activity.isHeld)
        #expect(host.begun.isEmpty)

        activity.isEnabled = true
        #expect(activity.isHeld)
        #expect(host.begun.count == 1)
    }

    @Test func turningTheSettingOffEndsTheActivityAndBackOnBeginsANewOne() {
        let activity = makeActivity()
        activity.hold(for: first)

        activity.isEnabled = false
        #expect(!activity.isHeld)
        #expect(host.ended == 1)

        activity.isEnabled = true
        #expect(activity.isHeld)
        #expect(host.begun.count == 2)
    }

    @Test func theSettingIsOnUntilTheUserTurnsItOff() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let defaults = scratch.defaults

        #expect(LatencyActivity.isSettingOn(in: defaults))
        defaults.set(false, forKey: LatencyActivity.settingKey)
        #expect(!LatencyActivity.isSettingOn(in: defaults))
        defaults.set(true, forKey: LatencyActivity.settingKey)
        #expect(LatencyActivity.isSettingOn(in: defaults))
    }

    @Test func theHelpTopicStatesTheEnergyCost() {
        let entry = HelpTopic.inputResponsiveness.entry
        let text = ([entry.summary] + entry.paragraphs).joined(separator: " ").lowercased()
        #expect(text.contains("battery"))
        #expect(entry.area == .display)
    }
}
