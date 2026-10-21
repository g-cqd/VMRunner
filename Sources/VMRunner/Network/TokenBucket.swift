import Foundation

/// Admits a burst, then a steady rate: `burst` events at once, refilled at `perSecond`. Time is the stack's own
/// clock, passed in, so tests move it by hand.
struct TokenBucket {
    private let burst: Double
    private let perSecond: Double
    private var tokens: Double
    private var updated: TimeInterval = 0

    init(burst: Int, perSecond: Double) {
        self.burst = Double(max(burst, 1))
        self.perSecond = max(perSecond, 0)
        tokens = self.burst
    }

    /// Takes one token if there is one.
    mutating func take(now: TimeInterval) -> Bool {
        tokens = min(burst, tokens + max(now - updated, 0) * perSecond)
        updated = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
