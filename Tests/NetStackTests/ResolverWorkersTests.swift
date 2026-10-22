import Foundation
import TestKit
import Testing

@testable import NetStack

struct ResolverQueueTests {
    @Test func workersStartUpToTheLimitThenLookupsWaitThenTheyAreRefused() {
        var queue = ResolverQueue<Int>(maximumWorkers: 2, maximumQueued: 1)
        // `#expect` cannot hold a mutating call, so each result is taken first.
        let admissions = [queue.admit(1), queue.admit(2), queue.admit(3), queue.admit(4)]
        #expect(admissions == [.startWorker, .startWorker, .queued, .refused])
        let next = queue.next()
        let last = queue.next()
        #expect(next == 3, "a worker that finished takes the oldest waiting lookup")
        #expect(last == nil, "and stops when none is left")
        #expect(queue.running == 1)
        let again = queue.admit(5)
        #expect(again == .startWorker, "a stopped worker's place is free again")
    }
}

struct ResolverWorkersTests {
    @Test func everyLookupOfABurstLargerThanThePoolRuns() async throws {
        let start = ContinuousClock.now
        // A clock that never moves: no lookup is ever late.
        let workers = ResolverWorkers(maximumWorkers: 4, maximumQueued: 200, maximumWait: .seconds(5), now: { start })
        let done = AsyncEventProbe<Int>()
        for index in 0..<100 {
            let admitted = workers.submit({ done.record(index) }, late: { done.record(-1) })
            #expect(admitted)
        }
        let events = try await done.wait(forAtLeast: 100)
        #expect(Set(events) == Set(0..<100))
    }

    @Test func aLookupThatWaitedPastItsDeadlineIsAnsweredLateWithoutRunning() async throws {
        let start = ContinuousClock.now
        let clock = TestClock()
        let workers = ResolverWorkers(
            maximumWorkers: 1, maximumQueued: 4, maximumWait: .seconds(5), now: { start.advanced(by: clock.now.offset) })
        let release = DispatchSemaphore(value: 0)
        let done = AsyncEventProbe<String>()
        // The only worker is busy until `release`, so the next two lookups wait in the queue.
        let busy = workers.submit(
            {
                release.wait()
                done.record("busy ran")
            }, late: { done.record("busy late") })
        let waited = workers.submit({ done.record("waited ran") }, late: { done.record("waited late") })
        clock.advance(by: .seconds(6))  // past the first queued lookup's deadline, not past the next one's
        let fresh = workers.submit({ done.record("fresh ran") }, late: { done.record("fresh late") })
        #expect(busy && waited && fresh)
        release.signal()
        let events = try await done.wait(forAtLeast: 3)
        #expect(events == ["busy ran", "waited late", "fresh ran"])
    }
}
