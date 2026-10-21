import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Regression ceilings for the heap allocations of one policy decision, measured in a debug build (about 25% above
/// the measured value, so only a real regression trips them). They are not targets: tighten them as the evaluator
/// gets leaner. Where allocation counting is unavailable (sanitizer runs) the guard records nothing.
struct NetworkAllocationTests {
    /// The allocation counter is process-wide and other suites run concurrently, so a single reading can include
    /// their allocations. Noise only ever adds, so the minimum over several attempts is the decision's own count.
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

    private func policy() throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.blockedDomains = [try DomainRule("tracker.example"), try DomainRule("*.ads.example")]
        return policy
    }

    /// Measured: example.com 53, tracker.example 12, x.ads.example 18, 127.0.0.1 54, 93.184.216.34 115, 2130706433 8.
    @Test(arguments: [
        ("example.com", 66), ("tracker.example", 16), ("x.ads.example", 24), ("127.0.0.1", 68),
        ("93.184.216.34", 144), ("2130706433", 12),
    ])
    func hostDecisionStaysWithinItsAllocationCeiling(host: String, ceiling: Int) throws {
        let policy = try policy()
        let resolved = try addresses("93.184.216.34")
        expectDecision(within: ceiling) {
            _ = policy.evaluate(host: host, port: 443, resolvedAddresses: resolved)
        }
    }

    /// Measured: 85.
    @Test func urlDecisionStaysWithinItsAllocationCeiling() throws {
        let policy = try policy()
        let resolved = try addresses("93.184.216.34")
        let url = try #require(URL(string: "https://example.com/a/b?c=d"))
        expectDecision(within: 106) {
            _ = policy.evaluate(url: url, resolvedAddresses: resolved)
        }
    }
}
