import TestKit
import Testing

/// Per-packet paths, called in a tight loop. After a warm-up round that may allocate (pool misses, dictionary growth),
/// the measured rounds must not allocate at all. The scenarios are in `UserNetAllocationScenarios`, which the benchmarks
/// also run.
@Suite(.serialized, .enabled(if: allocationCountingAvailable, "needs the malloc_logger hook"))
struct UserNetAllocationTests {
    @Test func arpDHCPAndGatewayPingDoNotAllocate() {
        let outcome = UserNetAllocationScenarios.arpDHCPAndGatewayPing()
        #expect(outcome.work == 600, "each request produced one reply")
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations in 600 packets")
    }

    @Test func guestToHostTCPDataDoesNotAllocate() {
        let outcome = UserNetAllocationScenarios.guestToHostTCPData()
        #expect(outcome.work == 280_000)
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations in 280 data segments")
    }

    @Test func hostToGuestTCPDataDoesNotAllocate() {
        let outcome = UserNetAllocationScenarios.hostToGuestTCPData()
        #expect(outcome.work > 110 * 14_600, "data and headers went out")
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations in 110 rounds of 10 segments")
    }

    @Test func udpFlowsAndTheirRepliesDoNotAllocate() {
        let outcome = UserNetAllocationScenarios.udpRoundTrips()
        #expect(outcome.work == 501)
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations in 500 round trips")
    }

    @Test func housekeepingWithManyIdleFlowsDoesNotAllocate() {
        let outcome = UserNetAllocationScenarios.housekeepingWithIdleFlows()
        #expect(outcome.work == 50)
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations in 200 ticks over 50 flows")
    }

    @Test func theRealLoopDoesNotAllocatePerPacketForUDPRoundTrips() throws {
        let outcome = try UserNetAllocationScenarios.realLoopUDPRoundTrips()
        #expect(outcome.work == 1_500)
        #expect(outcome.allocations == 0, "\(outcome.allocations) allocations on the loop thread over 1300 UDP round trips")
    }
}
