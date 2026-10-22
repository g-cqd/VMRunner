import Foundation
import TestKit
import Testing

@testable import NetPolicy

/// The rule set and the decisions whose allocations are guarded here and recorded by the benchmarks.
enum PolicyAllocationFixture {
    /// Each decided host with its allocation ceiling in a debug build.
    /// Measured: example.com 53, tracker.example 12, x.ads.example 18, 127.0.0.1 54, 93.184.216.34 115, 2130706433 8.
    static let hostCeilings: [(String, Int)] = [
        ("example.com", 58), ("tracker.example", 14), ("x.ads.example", 20), ("127.0.0.1", 60),
        ("93.184.216.34", 127), ("2130706433", 10),
    ]
    static let urlText = "https://example.com/a/b?c=d"
    /// Measured: 85.
    static let urlCeiling = 94

    static func policy() throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.blockedDomains = [try DomainRule("tracker.example"), try DomainRule("*.ads.example")]
        return policy
    }
}

/// Regression ceilings for the heap allocations of one policy decision, measured in a debug build (the count is exact,
/// so a margin of about 10% only absorbs a different Foundation, and a real regression trips the ceiling). They are not
/// targets: tighten them as the evaluator gets leaner. Where allocation counting is unavailable (sanitizer runs) the guard
/// records nothing.
struct NetworkAllocationTests {
    /// Only this thread is counted, so a reading is exact; the minimum over several attempts still absorbs a one-off lazy
    /// initialization that the warm-up missed.
    private func lowestAllocationCount(attempts: Int = 40, _ body: () -> Void) -> Int? {
        var lowest: Int?
        for _ in 0..<attempts {
            guard let count = mallocDelta(body) else { return nil }
            lowest = min(lowest ?? count, count)
        }
        return lowest
    }

    private func expectDecision(within ceiling: Int, sourceLocation: SourceLocation = #_sourceLocation, _ body: () -> Void) {
        body()  // warm up lazy statics
        guard let count = lowestAllocationCount(body) else { return }
        #expect(count <= ceiling, "expected at most \(ceiling) allocation(s), measured \(count)", sourceLocation: sourceLocation)
    }

    @Test(arguments: PolicyAllocationFixture.hostCeilings)
    func hostDecisionStaysWithinItsAllocationCeiling(host: String, ceiling: Int) throws {
        let policy = try PolicyAllocationFixture.policy()
        let resolved = try addresses("93.184.216.34")
        expectDecision(within: ceiling) {
            _ = policy.evaluate(host: host, port: 443, resolvedAddresses: resolved)
        }
    }

    @Test func urlDecisionStaysWithinItsAllocationCeiling() throws {
        let policy = try PolicyAllocationFixture.policy()
        let resolved = try addresses("93.184.216.34")
        let url = try #require(URL(string: PolicyAllocationFixture.urlText))
        expectDecision(within: PolicyAllocationFixture.urlCeiling) {
            _ = policy.evaluate(url: url, resolvedAddresses: resolved)
        }
    }
}
