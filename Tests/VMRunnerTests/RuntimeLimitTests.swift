import Foundation
import TestKit
import Testing

@testable import VMRunner

@MainActor
struct RuntimeLimitTests {
    private let limit = Duration.seconds(60 * 60)
    private let clock = TestClock()
    private let stops = AsyncEventProbe<String>()

    private func start(_ timer: RuntimeLimit) {
        timer.start(
            after: limit,
            requestStop: { [stops] in stops.record("request") },
            forceStop: { [stops] in stops.record("force") }
        )
    }

    @Test func theMachineIsAskedToStopExactlyAtTheDeadlineAndNotBefore() async throws {
        let timer = RuntimeLimit(clock: clock)
        start(timer)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: limit - .milliseconds(1))
        #expect(stops.events.isEmpty)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .milliseconds(1))
        let events = try await stops.wait(forAtLeast: 1)
        #expect(events == ["request"])
    }

    @Test func theMachineIsForceStoppedOnlyAfterTheGracePeriod() async throws {
        let timer = RuntimeLimit(clock: clock)
        start(timer)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: limit)
        _ = try await stops.wait(forAtLeast: 1)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: RuntimeLimit.gracePeriod - .milliseconds(1))
        #expect(stops.events == ["request"])

        clock.advance(by: .milliseconds(1))
        let events = try await stops.wait(forAtLeast: 2)
        #expect(events == ["request", "force"])
    }

    @Test func cancellingBeforeTheDeadlineStopsTheLimit() async throws {
        let timer = RuntimeLimit(clock: clock)
        start(timer)
        try await clock.waitForSleepers(atLeast: 1)

        timer.cancel()
        #expect(clock.sleeperCount == 0)
        clock.advance(by: limit + RuntimeLimit.gracePeriod)
        #expect(stops.events.isEmpty)
    }

    @Test func cancellingDuringTheGracePeriodSkipsTheForceStop() async throws {
        let timer = RuntimeLimit(clock: clock)
        start(timer)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: limit)
        _ = try await stops.wait(forAtLeast: 1)
        try await clock.waitForSleepers(atLeast: 1)

        timer.cancel()
        #expect(clock.sleeperCount == 0)
        clock.advance(by: RuntimeLimit.gracePeriod)
        #expect(stops.events == ["request"])
    }

    @Test func startingAgainReplacesTheRunningLimit() async throws {
        let timer = RuntimeLimit(clock: clock)
        start(timer)
        start(timer)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: limit)
        _ = try await stops.wait(forAtLeast: 1)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: RuntimeLimit.gracePeriod)
        let events = try await stops.wait(forAtLeast: 2)
        #expect(events == ["request", "force"])
    }
}
