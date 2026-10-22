import TestKit
import Testing

/// The heap allocations of the user-mode stack's per-packet paths, recorded as they are in this build (the guards assert
/// ceilings in a debug build; the benchmarks run optimized).
@Suite(.serialized, .tags(.bench), .benchmarksRequested, .enabled(if: allocationCountingAvailable, "needs the malloc_logger hook"))
struct UserNetAllocationBenchmarks {
    private func record(_ name: String, _ count: Int) {
        recordBenchmark(BenchmarkResult(name: "allocations.\(name)", unit: "allocations", direction: .lower, value: Double(count)))
    }

    @Test func userNetStackPaths() throws {
        record("usernet.arpDHCPAndGatewayPing", UserNetAllocationScenarios.arpDHCPAndGatewayPing().allocations)
        record("usernet.guestToHostTCPData", UserNetAllocationScenarios.guestToHostTCPData().allocations)
        record("usernet.hostToGuestTCPData", UserNetAllocationScenarios.hostToGuestTCPData().allocations)
        record("usernet.udpRoundTrips", UserNetAllocationScenarios.udpRoundTrips().allocations)
        record("usernet.housekeepingWithIdleFlows", UserNetAllocationScenarios.housekeepingWithIdleFlows().allocations)
        record("usernet.realLoopUDPRoundTrips", try UserNetAllocationScenarios.realLoopUDPRoundTrips().allocations)
    }
}
