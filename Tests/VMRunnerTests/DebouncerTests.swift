import Foundation
import TestKit
import Testing

@testable import VMRunner

@MainActor
struct DebouncerTests {
    private let quiet = Duration.milliseconds(150)
    private let clock = TestClock()
    private let fired = AsyncEventProbe<Int>()

    private func makeDebouncer() -> Debouncer<Int> {
        Debouncer(quietPeriod: quiet, clock: clock) { [fired] value in fired.record(value) }
    }

    @Test func aValueFiresExactlyWhenTheQuietPeriodEnds() async throws {
        let debouncer = makeDebouncer()
        debouncer.submit(1)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: quiet - .milliseconds(1))
        #expect(fired.events.isEmpty)

        clock.advance(by: .milliseconds(1))
        #expect(try await fired.wait(forAtLeast: 1) == [1])
    }

    @Test func aBurstFiresOnceWithTheNewestValue() async throws {
        let debouncer = makeDebouncer()
        for value in 1...3 { debouncer.submit(value) }
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: quiet)
        #expect(try await fired.wait(forAtLeast: 1) == [3])
        #expect(clock.sleeperCount == 0)
    }

    @Test func eachSubmitRestartsTheQuietPeriod() async throws {
        let debouncer = makeDebouncer()
        debouncer.submit(1)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet - .milliseconds(1))

        debouncer.submit(2)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet - .milliseconds(1))
        #expect(fired.events.isEmpty)

        clock.advance(by: .milliseconds(1))
        #expect(try await fired.wait(forAtLeast: 1) == [2])
    }

    @Test func aSettledValueDoesNotFireAgain() async throws {
        let debouncer = makeDebouncer()
        debouncer.submit(1)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet)
        _ = try await fired.wait(forAtLeast: 1)

        debouncer.submit(2)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet)
        #expect(try await fired.wait(forAtLeast: 2) == [1, 2])
    }

    @Test func droppingTheDebouncerCancelsAPendingValue() async throws {
        var debouncer: Debouncer<Int>? = makeDebouncer()
        debouncer?.submit(1)
        try await clock.waitForSleepers(atLeast: 1)

        debouncer = nil
        #expect(clock.sleeperCount == 0)
        clock.advance(by: quiet)
        #expect(fired.events.isEmpty)
    }
}

@MainActor
struct PollTests {
    private let interval = Duration.milliseconds(100)
    private let clock = TestClock()
    private let finished = AsyncEventProbe<Void>()

    /// Starts a poll whose condition is read from `ready`, and records when the poll returns.
    private func startPolling(attempts: Int, ready: Flag) -> Task<Void, Never> {
        Task { [interval, clock, finished] in
            await poll(every: interval, attempts: attempts, clock: clock) { ready.value }
            finished.record(())
        }
    }

    @MainActor final class Flag {
        var value = false
    }

    @Test func returnsAtOnceWhenTheConditionAlreadyHolds() async throws {
        let ready = Flag()
        ready.value = true
        _ = startPolling(attempts: 20, ready: ready)
        _ = try await finished.wait(forAtLeast: 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func returnsAtTheFirstCheckAfterTheConditionBecomesTrue() async throws {
        let ready = Flag()
        _ = startPolling(attempts: 20, ready: ready)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: interval)
        try await clock.waitForSleepers(atLeast: 1)
        #expect(finished.events.isEmpty)

        ready.value = true
        clock.advance(by: interval)
        _ = try await finished.wait(forAtLeast: 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func givesUpAfterTheLastAttempt() async throws {
        let ready = Flag()
        _ = startPolling(attempts: 3, ready: ready)
        for _ in 0..<3 {
            try await clock.waitForSleepers(atLeast: 1)
            #expect(finished.events.isEmpty)
            clock.advance(by: interval)
        }
        _ = try await finished.wait(forAtLeast: 1)
        #expect(clock.sleeperCount == 0)
    }
}
