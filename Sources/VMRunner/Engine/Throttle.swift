import Foundation
import Synchronization

/// Lets the first event through every `interval` seconds; safe to call from the URLSession queue.
final class Throttle: Sendable {
    private let interval: Duration
    private let last = Mutex(ContinuousClock.Instant?.none)

    init(interval: TimeInterval) { self.interval = .seconds(interval) }

    func allow() -> Bool {
        let now = ContinuousClock.now
        return last.withLock { last in
            if let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
    }
}
