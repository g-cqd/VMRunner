import Foundation
import TestKit
import Testing

@testable import VMRunner

@MainActor
struct ConfigPersistenceTests {
    private let quiet = Duration.milliseconds(400)
    private let clock = TestClock()
    private let written = AsyncEventProbe<VMConfig>()

    private func makePersistence() -> ConfigPersistence {
        ConfigPersistence(quietPeriod: quiet, clock: clock) { [written] config in written.record(config) }
    }

    private func named(_ name: String, id: UUID) -> VMConfig {
        var config = VMConfig.new(name: name, guest: .linux)
        config.id = id
        return config
    }

    @Test func aBurstOfEditsIsWrittenOnceWithTheNewestValueAfterTheyPause() async throws {
        let persistence = makePersistence()
        let id = UUID()
        for name in ["a", "ab", "abc"] { persistence.schedule(named(name, id: id)) }
        try await clock.waitForSleepers(atLeast: 1)
        #expect(written.events.isEmpty)
        #expect(persistence.hasPendingWrites)

        clock.advance(by: quiet)
        let events = try await written.wait(forAtLeast: 1)
        #expect(events.map(\.name) == ["abc"])
        #expect(!persistence.hasPendingWrites)
    }

    @Test func nothingIsWrittenBeforeTheQuietPeriodHasPassed() async throws {
        let persistence = makePersistence()
        persistence.schedule(named("held", id: UUID()))
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: quiet / 2)
        await Task.yield()
        #expect(written.events.isEmpty)
        #expect(persistence.hasPendingWrites)
    }

    @Test func eachMachineKeepsItsOwnNewestConfig() async throws {
        let persistence = makePersistence()
        let first = UUID()
        let second = UUID()
        persistence.schedule(named("one", id: first))
        persistence.schedule(named("two", id: second))
        persistence.schedule(named("one!", id: first))
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: quiet)
        let events = try await written.wait(forAtLeast: 2)
        #expect(Set(events.map(\.name)) == ["one!", "two"])
    }

    @Test func flushWritesImmediatelyWithoutWaitingForTheClock() {
        let persistence = makePersistence()
        persistence.schedule(named("now", id: UUID()))
        persistence.flush()
        #expect(written.events.map(\.name) == ["now"])
        #expect(!persistence.hasPendingWrites)
    }

    @Test func aDiscardedMachineIsNeverWritten() {
        let persistence = makePersistence()
        let id = UUID()
        persistence.schedule(named("gone", id: id))
        persistence.discard(id)
        persistence.flush()
        #expect(written.events.isEmpty)
    }

    @Test func aFailedWriteIsReportedWithTheConfigThatFailed() {
        struct Boom: Error {}
        let persistence = ConfigPersistence(quietPeriod: quiet, clock: clock) { _ in throw Boom() }
        var failures: [String] = []
        persistence.onFailure = { config, error in failures.append("\(config.name): \(error is Boom)") }
        persistence.schedule(named("broken", id: UUID()))
        persistence.flush()
        #expect(failures == ["broken: true"])
    }
}
