import Foundation
import Synchronization

/// Who runs a blocking lookup, decided under ``ResolverWorkers``'s lock: a new worker while fewer than `maximumWorkers` run, a
/// running worker later while fewer than `maximumQueued` wait, nobody otherwise.
struct ResolverQueue<Job> {
    enum Admission {
        /// Start a worker for this job; it takes queued jobs once it is done with it.
        case startWorker
        /// A running worker takes this job when it is free.
        case queued
        /// Every worker is busy and the queue is full: the job is not run.
        case refused
    }

    let maximumWorkers: Int
    let maximumQueued: Int
    private(set) var running = 0
    private var waiting: [Job] = []

    init(maximumWorkers: Int, maximumQueued: Int) {
        self.maximumWorkers = maximumWorkers
        self.maximumQueued = maximumQueued
    }

    /// Admits `job`. On `.startWorker` the caller hands `job` to the new worker; on `.queued` it is kept here.
    mutating func admit(_ job: Job) -> Admission {
        if running < maximumWorkers {
            running += 1
            return .startWorker
        }
        guard waiting.count < maximumQueued else { return .refused }
        waiting.append(job)
        return .queued
    }

    /// The oldest waiting job, for a worker that finished one; nil when none waits, and the worker then stops.
    mutating func next() -> Job? {
        guard !waiting.isEmpty else {
            running -= 1
            return nil
        }
        return waiting.removeFirst()
    }
}

/// A few threads of their own for lookups that block (`getaddrinfo`, `DNSServiceProcessResult`), so no cooperative-pool thread
/// ever waits on the system resolver. A burst starts at most `maximumWorkers` threads; each runs lookups one after another until
/// none waits, then ends, so a quiet stack holds no thread. A lookup that waited `maximumWait` or longer for a worker runs its
/// `late` job instead: whoever asked has given up on it by then.
final class ResolverWorkers: Sendable {
    typealias Job = @Sendable () -> Void

    /// A lookup, what runs instead when no worker took it before `deadline`, and that deadline.
    private struct Entry {
        let run: Job
        let late: Job
        let deadline: ContinuousClock.Instant
    }

    private let queue: Mutex<ResolverQueue<Entry>>
    private let maximumWait: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// `now` reads the clock; tests pass one they move by hand.
    init(
        maximumWorkers: Int, maximumQueued: Int, maximumWait: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        queue = Mutex(ResolverQueue(maximumWorkers: maximumWorkers, maximumQueued: maximumQueued))
        self.maximumWait = maximumWait
        self.now = now
    }

    /// Runs `job` on a worker thread soon, or `late` instead when the job waited `maximumWait` or longer for a worker. Exactly
    /// one of the two runs. Returns false, and runs neither, when every worker is busy and the queue is full.
    func submit(_ job: @escaping Job, late: @escaping Job) -> Bool {
        let entry = Entry(run: job, late: late, deadline: now().advanced(by: maximumWait))
        switch queue.withLock({ $0.admit(entry) }) {
        case .startWorker:
            Thread.detachNewThread { [self] in
                entry.run()
                drain()
            }
            return true
        case .queued:
            return true
        case .refused:
            return false
        }
    }

    private func drain() {
        while let entry = queue.withLock({ $0.next() }) {
            if now() < entry.deadline { entry.run() } else { entry.late() }
        }
    }
}
