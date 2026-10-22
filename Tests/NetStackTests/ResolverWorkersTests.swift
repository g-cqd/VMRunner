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
        let workers = ResolverWorkers(maximumWorkers: 4, maximumQueued: 200)
        let done = AsyncEventProbe<Int>()
        for index in 0..<100 { #expect(workers.submit { done.record(index) }) }
        let events = try await done.wait(forAtLeast: 100)
        #expect(Set(events) == Set(0..<100))
    }
}
