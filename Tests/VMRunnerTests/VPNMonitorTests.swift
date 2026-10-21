import Foundation
import Observation
import Testing

@testable import VMRunner

private func interface(_ name: String, up: Bool = true, _ addresses: String...) throws -> InterfaceSnapshot {
    InterfaceSnapshot(name: name, isUp: up, addresses: try addresses.map(address))
}

private func unaddressed(_ name: String, up: Bool = true) -> InterfaceSnapshot {
    InterfaceSnapshot(name: name, isUp: up, addresses: nil)
}

struct VPNClassificationTests {
    /// This Mac's real shape without a VPN: Wi-Fi plus five system tunnels that hold only link-local addresses.
    @Test func systemTunnelsAloneAreNotAVPN() throws {
        let snapshot = try [
            interface("lo0", "127.0.0.1", "::1", "fe80::1"), interface("en0", "10.0.0.23", "fe80::1c2a:3b4c:5d6e:7f80"),
            interface("awdl0", "fe80::a4b:1"), interface("bridge0"), interface("llw0", "fe80::2"),
            interface("utun0", "fe80::100"), interface("utun1", "fe80::101"),
            interface("utun2", "fe80::102"), interface("utun3", "fe80::103"),
            interface("utun4", "fe80::104"),
        ]
        #expect(VPNState.classify(snapshot) == .inactive)
    }

    @Test(arguments: [
        ["10.8.0.2"], ["100.101.102.103"], ["fd7a:115c:a1e0::1"], ["2001:db8::1"], ["fe80::1", "10.8.0.2"], ["172.16.5.5", "fe80::1"],
        ["192.168.64.9"],
    ])
    func aTunnelWithARoutableAddressIsAVPN(addresses: [String]) throws {
        let tunnel = InterfaceSnapshot(name: "utun7", isUp: true, addresses: try addresses.map(address))
        #expect(VPNState.classify([tunnel]) == .active)
    }

    @Test(arguments: [["fe80::1"], ["169.254.10.10"], ["169.254.169.254"], ["127.0.0.1"], ["::1"], ["0.0.0.0"], ["ff02::1"], ["224.0.0.1"]])
    func aTunnelWithOnlyNonRoutableAddressesIsNot(addresses: [String]) throws {
        let tunnel = InterfaceSnapshot(name: "utun7", isUp: true, addresses: try addresses.map(address))
        #expect(VPNState.classify([tunnel]) == .inactive)
    }

    @Test func aDownTunnelIsNotAVPN() throws {
        #expect(VPNState.classify([try interface("utun7", up: false, "10.8.0.2")]) == .inactive)
        #expect(VPNState.classify([unaddressed("utun7", up: false)]) == .inactive)
    }

    @Test(arguments: ["utun0", "utun12", "ipsec0", "ipsec3", "ppp0", "tun0", "tap1"])
    func tunnelFamiliesAreRecognized(name: String) throws {
        #expect(VPNState.classify([try interface(name, "10.8.0.2")]) == .active)
        #expect(VPNState.classify([unaddressed(name)]) == .active)
    }

    @Test(arguments: [
        "en0", "lo0", "bridge100", "awdl0", "gif0", "stf0", "anpi0", "vmenet0", "utun", "utunx", "xutun0", "tunnel0", "ppp", "ipsec", "tap",
        "tun-1",
        "UTUN0", "eutun1",
    ])
    func otherInterfacesAreNeverVPNs(name: String) throws {
        #expect(VPNState.classify([try interface(name, "10.8.0.2")]) == .inactive)
        #expect(VPNState.classify([unaddressed(name)]) == .inactive)
    }

    @Test func aSourceThatCannotSeeAddressesTrustsTheListedTunnel() {
        #expect(VPNState.classify([unaddressed("en0"), unaddressed("utun4")]) == .active)
        #expect(VPNState.classify([unaddressed("en0")]) == .inactive)
        #expect(VPNState.classify([]) == .inactive)
    }

    @Test func aTunnelWithNoAddressYetIsUnknownUnlessAnotherIsDefinitelyAVPN() throws {
        let connecting = InterfaceSnapshot(name: "utun9", isUp: true, addresses: [])
        #expect(VPNState.classify([connecting]) == .unknown)
        #expect(VPNState.classify([try interface("en0", "10.0.0.5"), connecting]) == .unknown)
        #expect(VPNState.classify([connecting, try interface("utun10", "10.8.0.2")]) == .active)
        #expect(VPNState.classify([try interface("utun10", "10.8.0.2"), connecting]) == .active)
        // System tunnels with only link-local addresses do not make the answer unknown.
        #expect(VPNState.classify([try interface("utun0", "fe80::1"), try interface("en0", "10.0.0.5")]) == .inactive)
    }
}

struct VPNRequirementTests {
    @Test(arguments: [
        (VPNRequirement.ignore, VPNState.active, true), (.ignore, .inactive, true), (.ignore, .unknown, true),
        (.required, .active, true), (.required, .inactive, false), (.required, .unknown, false),
        (.forbidden, .active, false), (.forbidden, .inactive, true), (.forbidden, .unknown, false),
    ])
    func truthTable(requirement: VPNRequirement, state: VPNState, expected: Bool) {
        #expect(requirement.allowsNetwork(vpn: state) == expected)
    }

    @Test func requirementsRoundTripThroughCodable() throws {
        for requirement in VPNRequirement.allCases {
            let data = try JSONEncoder().encode([requirement])
            #expect(try JSONDecoder().decode([VPNRequirement].self, from: data) == [requirement])
        }
    }
}

@MainActor
struct VPNMonitorLifecycleTests {
    @Test func publishesTheClassificationOfEachSnapshot() async throws {
        let (stream, feed) = AsyncStream.makeStream(of: [InterfaceSnapshot].self)
        let monitor = VPNMonitor(source: { stream })
        var states = Observations { monitor.state }.makeAsyncIterator()
        #expect(await states.next() == .unknown)

        monitor.start()
        monitor.start()  // idempotent
        feed.yield([unaddressed("en0")])
        #expect(await states.next() == .inactive)
        feed.yield([unaddressed("en0"), unaddressed("utun4")])
        #expect(await states.next() == .active)
        feed.yield([unaddressed("en0")])
        #expect(await states.next() == .inactive)
        feed.finish()
    }

    @Test func stopReturnsToUnknownAndIgnoresLaterSnapshots() async throws {
        let (stream, feed) = AsyncStream.makeStream(of: [InterfaceSnapshot].self)
        let monitor = VPNMonitor(source: { stream })
        var states = Observations { monitor.state }.makeAsyncIterator()
        _ = await states.next()
        monitor.start()
        feed.yield([unaddressed("utun4")])
        #expect(await states.next() == .active)
        monitor.stop()
        #expect(await states.next() == .unknown)
        feed.yield([unaddressed("utun4")])
        for _ in 0..<50 { await Task.yield() }
        #expect(monitor.state == .unknown)
        feed.finish()
    }

    @Test func theSystemSourceIsConstructibleAndStoppable() {
        let monitor = VPNMonitor()
        #expect(monitor.state == .unknown)
        monitor.start()
        monitor.stop()
        #expect(monitor.state == .unknown)
    }
}
