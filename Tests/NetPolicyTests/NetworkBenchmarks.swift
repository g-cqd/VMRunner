import Foundation
import TestKit
import Testing

@testable import NetPolicy

/// A fixed rule set and a fixed mix of decisions: the allow-list mode, which has the most rules to walk.
private enum DecisionWorkload {
    static func policy() throws -> NetworkPolicy {
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        policy.blockedDomains = try (0..<40).map { index in
            try DomainRule(index.isMultiple(of: 2) ? "blocked\(index).example" : "*.tracker\(index).example")
        }
        policy.blockedAddresses = try (0..<8).map { index in try AddressRule("203.0.\(index * 8).0/21") }
        policy.blockedPorts = [22, 23, 3389, try PortRule("8000-8100")]
        policy.blockedConnections = [try ConnectionRule("198.51.100.0/24:25,465,587")]
        policy.allowedDomains = try (0..<30).map { try DomainRule("*.allowed\($0).example") } + [try DomainRule("*.github.com")]
        policy.allowedPorts = [80, 443]
        return policy
    }

    /// The decisions of one pass: allowed by a late rule, blocked by a wildcard, blocked by an exact name, a name nobody
    /// listed, a blocked port, an address literal.
    struct Decision {
        let name: String
        let port: UInt16
        let allowed: Bool

        init(_ name: String, _ port: UInt16, allowed: Bool = false) {
            self.name = name
            self.port = port
            self.allowed = allowed
        }
    }

    static let hosts = [
        Decision("www.github.com", 443, allowed: true), Decision("x.tracker37.example", 443), Decision("blocked30.example", 443),
        Decision("unlisted.example", 443), Decision("www.github.com", 22), Decision("93.184.216.34", 443),
    ]
}

/// The throughput of the policy decision (`NetworkPolicy.evaluate`) over a fixed rule set.
@Suite(.serialized, .tags(.bench), .benchmarksRequested)
struct NetworkPolicyBenchmarks {
    @Test func decisionThroughput() async throws {
        let policy = try DecisionWorkload.policy()
        let resolved = try addresses("93.184.216.34")
        let passes = 20_000
        var allowed = 0
        let rate = await measureRate(units: Double(passes * DecisionWorkload.hosts.count)) {
            allowed = 0
            for _ in 0..<passes {
                for decision in DecisionWorkload.hosts
                where policy.evaluate(host: decision.name, port: decision.port, resolvedAddresses: resolved).isAllowed {
                    allowed += 1
                }
            }
        }
        #expect(allowed == passes * DecisionWorkload.hosts.count(where: \.allowed), "every decision came out as expected")
        // Wall-clock rates are reported only: ten runs on a shared machine spread by 60-80%. Retired instructions spread by under 1%.
        recordBenchmark(
            BenchmarkResult(
                name: "network.policy.decisionsPerSecond", unit: "decisions/s", direction: .higher, value: rate.perSecond, tolerance: 0.3,
                enforced: false))
        if let instructions = rate.instructionsPerUnit {
            recordBenchmark(
                BenchmarkResult(
                    name: "network.policy.instructionsPerDecision", unit: "instructions", direction: .lower, value: instructions,
                    tolerance: 0.03))
        }
    }
}

/// The heap allocations of the policy's decisions, recorded as they are in this build (the guards assert ceilings in a
/// debug build; the benchmarks run optimized).
@Suite(.serialized, .tags(.bench), .benchmarksRequested, .enabled(if: allocationCountingAvailable, "needs the malloc_logger hook"))
struct AllocationBenchmarks {
    private func record(_ name: String, _ count: Int) {
        recordBenchmark(BenchmarkResult(name: "allocations.\(name)", unit: "allocations", direction: .lower, value: Double(count)))
    }

    @Test func policyDecisions() throws {
        let policy = try PolicyAllocationFixture.policy()
        let resolved = try addresses("93.184.216.34")
        for (host, _) in PolicyAllocationFixture.hostCeilings {
            let decide = { _ = policy.evaluate(host: host, port: 443, resolvedAddresses: resolved) }
            decide()  // warm up lazy statics
            record("policy.\(host)", (0..<5).compactMap { _ in mallocDelta(decide) }.min() ?? -1)
        }
        let url = try #require(URL(string: PolicyAllocationFixture.urlText))
        let decide = { _ = policy.evaluate(url: url, resolvedAddresses: resolved) }
        decide()
        record("policy.url", (0..<5).compactMap { _ in mallocDelta(decide) }.min() ?? -1)
    }
}
