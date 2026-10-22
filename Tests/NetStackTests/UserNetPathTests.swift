import Foundation
import Testing

@testable import NetStack

struct UserNetHostPathTests {
    private func changeCount(_ snapshots: [HostPathSnapshot]) async -> Int {
        let (input, feed) = AsyncStream.makeStream(of: HostPathSnapshot.self)
        let changes = HostPathMonitor.changes(in: input)
        for snapshot in snapshots { feed.yield(snapshot) }
        feed.finish()
        var count = 0
        for await _ in changes { count += 1 }
        return count
    }

    private let wifi = HostPathSnapshot(isSatisfied: true, interfaces: ["en0"], gateways: ["192.168.1.1"])
    private let ethernet = HostPathSnapshot(isSatisfied: true, interfaces: ["en5", "en0"], gateways: ["10.0.0.1"])
    private let offline = HostPathSnapshot(isSatisfied: false, interfaces: [])

    @Test func theFirstPathIsTheBaselineNotAChange() async {
        #expect(await changeCount([wifi]) == 0)
    }

    @Test func repeatedIdenticalPathsAreNotChanges() async {
        #expect(await changeCount([wifi, wifi, wifi]) == 0)
    }

    @Test func switchingNetworkGoingOfflineAndComingBackAreEachAChange() async {
        #expect(await changeCount([wifi, ethernet, offline, ethernet]) == 3)
    }

    @Test func aVPNAppearingOrADifferentGatewayIsAChange() async {
        let vpn = HostPathSnapshot(isSatisfied: true, interfaces: ["utun4", "en0"], gateways: ["192.168.1.1"])
        let reroute = HostPathSnapshot(isSatisfied: true, interfaces: ["en0"], gateways: ["192.168.1.254"])
        #expect(await changeCount([wifi, vpn, wifi, reroute]) == 3)
    }

    @Test func descriptorLimitIsRaisedForManyFlows() {
        let limit = SocketCalls.raiseDescriptorLimit()
        #expect(limit >= 1_024, "one host socket per flow needs more than a GUI process's default of 256")
        #expect(SocketCalls.raiseDescriptorLimit() >= limit, "raising again never lowers it")
    }
}
