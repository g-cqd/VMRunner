import Foundation
import Synchronization
import TestKit
import Testing

@testable import VMRunner

// MARK: A host that records only counters, so it allocates nothing itself

final class CountingHost: UserNetHost {
    var frames = 0
    var frameBytes = 0
    var lastSequence: UInt32 = 0
    var token: UInt64 = 0
    var uploaded = 0
    var available = 0
    var datagramToRead = 0
    var datagramWrites = 0

    func sendToGuest(_ frame: ByteView) {
        frames += 1
        frameBytes += frame.count
        if let sequence = try? frame.be32(at: 38), frame[23] == IPProtocol.tcp { lastSequence = sequence }
    }

    func openStream(token: UInt64, address: UInt32, port: UInt16) { self.token = token }

    func writeStream(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        uploaded += bytes.count
        return .transferred(bytes.count)
    }

    func readStream(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        let count = min(available, buffer.count)
        guard count > 0 else { return .wouldBlock }
        buffer.fill(0x5A, from: 0, length: count)
        available -= count
        return .transferred(count)
    }

    func shutdownStreamWrite(token: UInt64) {}
    func closeStream(token: UInt64, abort: Bool) {}
    func setStreamInterest(token: UInt64, read: Bool, write: Bool) {}

    func openDatagram(token: UInt64, kind: DatagramKind, address: UInt32, port: UInt16) -> Bool {
        self.token = token
        return true
    }

    func writeDatagram(token: UInt64, _ bytes: ByteView) -> HostIOResult {
        datagramWrites += 1
        return .transferred(max(bytes.count, 1))
    }

    func readDatagram(token: UInt64, into buffer: MutableByteView) -> HostIOResult {
        guard datagramToRead > 0 else { return .wouldBlock }
        datagramToRead -= 1
        buffer.fill(0x33, from: 0, length: 512)
        return .transferred(512)
    }

    func closeDatagram(token: UInt64) {}
    func resolve(token: UInt64, name: String, recordType: UInt16) {}
    func publish(_ event: FlowEvent) {}
    func publish(vpnState: GuestVPNState) {}
}

private func feed(_ core: UserNetCore<CountingHost, ManualClock>, _ frame: [UInt8]) {
    ByteView.withBytes(of: frame) { core.receiveFrame($0) }
    core.endOfBatch()
}

private let remote = (ipv4("93.184.216.34"), UInt16(443))

/// Per-packet paths, called in a tight loop. After a warm-up round that may allocate (pool misses, dictionary growth),
/// the measured rounds must not allocate at all.
@Suite(.serialized, .enabled(if: allocationCountingAvailable, "needs the malloc_logger hook"))
struct UserNetAllocationTests {
    /// The allocations `body` made on this thread. The suite runs only where counting is available, so -1 never shows.
    private func countAllocations(_ body: () -> Void) -> Int { mallocDelta(body) ?? -1 }

    private func makeCore(_ configure: (inout UserNetConfig) -> Void = { _ in }) -> (UserNetCore<CountingHost, ManualClock>, CountingHost) {
        var config = UserNetConfig()
        config.initialSequenceSeed = 1_000_000
        configure(&config)
        let host = CountingHost()
        return (UserNetCore(config: config, policy: CoreRig.openPolicy, host: host, clock: ManualClock()), host)
    }

    private func guestFrame(_ tcp: [UInt8]) -> [UInt8] {
        Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: remote.0, proto: IPProtocol.tcp, tcp))
    }

    /// Opens a TCP flow and returns the guest's next sequence number and the server's.
    private func establish(_ core: UserNetCore<CountingHost, ManualClock>, _ host: CountingHost) -> (guest: UInt32, server: UInt32) {
        let isn: UInt32 = 7_000
        feed(core, Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
        feed(core, guestFrame(Wire.tcp(from: (Wire.guest, 50_000), to: remote, sequence: isn, flags: .syn, mss: 1_460)))
        core.streamConnected(token: host.token, error: nil)
        let server = host.lastSequence
        feed(
            core, guestFrame(Wire.tcp(from: (Wire.guest, 50_000), to: remote, sequence: isn + 1, acknowledgement: server &+ 1, flags: .ack))
        )
        return (isn + 1, server &+ 1)
    }

    @Test func arpDHCPAndGatewayPingDoNotAllocate() {
        let (core, host) = makeCore()
        let arp = Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway)
        let discover = Wire.ethernet(
            to: .broadcast, from: Wire.guestMAC, type: EtherType.ipv4,
            Wire.ipv4(
                from: 0, to: IPv4.broadcast, proto: IPProtocol.udp, Wire.udp(from: (0, 68), to: (IPv4.broadcast, 67), Wire.dhcp(type: 1))))
        let ping = Wire.guestFrame(
            Wire.ipv4(
                from: Wire.guest, to: Wire.gateway, proto: IPProtocol.icmp, Wire.icmpEcho(identifier: 1, sequence: 1, data: pattern(56))))
        let frames = [arp, discover, ping]
        var warm = 0
        while warm < 3 {
            feed(core, frames[warm])
            warm += 1
        }
        let before = host.frames
        let allocations = countAllocations {
            // `while` loops, not `for ... in`: an unoptimized build boxes the iterator of a generic range.
            var round = 0
            while round < 200 {
                var index = 0
                while index < 3 {
                    feed(core, frames[index])
                    index += 1
                }
                round += 1
            }
        }
        #expect(host.frames - before == 600, "each request produced one reply")
        #expect(allocations == 0, "\(allocations) allocations in 600 packets")
    }

    @Test func guestToHostTCPDataDoesNotAllocate() {
        let (core, host) = makeCore()
        let (guestSequence, serverSequence) = establish(core, host)
        let segments: [[UInt8]] = (0..<300).map { index in
            guestFrame(
                Wire.tcp(
                    from: (Wire.guest, 50_000), to: remote, sequence: guestSequence &+ UInt32(index * 1_000),
                    acknowledgement: serverSequence,
                    flags: [.ack, .psh], payload: pattern(1_000)))
        }
        var warm = 0
        while warm < 20 {
            feed(core, segments[warm])
            warm += 1
        }
        let before = host.uploaded
        let allocations = countAllocations {
            var index = 20
            while index < 300 {
                feed(core, segments[index])
                index += 1
            }
            core.endOfBatch()
        }
        #expect(host.uploaded - before == 280_000)
        #expect(allocations == 0, "\(allocations) allocations in 280 data segments")
    }

    @Test func hostToGuestTCPDataDoesNotAllocate() {
        let (core, host) = makeCore()
        let (guestSequence, serverSequence) = establish(core, host)
        let round = 14_600  // ten full segments
        let acknowledgements: [[UInt8]] = (1...120).map { index in
            guestFrame(
                Wire.tcp(
                    from: (Wire.guest, 50_000), to: remote, sequence: guestSequence,
                    acknowledgement: serverSequence &+ UInt32(index * round),
                    flags: .ack))
        }
        func step(_ index: Int) {
            host.available = round
            core.streamReadable(token: host.token)
            feed(core, acknowledgements[index])
        }
        var warm = 0
        while warm < 10 {  // the first rounds take rings from the pool
            step(warm)
            warm += 1
        }
        let before = host.frameBytes
        let allocations = countAllocations {
            var index = 10
            while index < 120 {
                step(index)
                index += 1
            }
        }
        #expect(host.frameBytes - before > 110 * round, "data and headers went out")
        #expect(allocations == 0, "\(allocations) allocations in 110 rounds of 10 segments")
    }

    @Test func udpFlowsAndTheirRepliesDoNotAllocate() {
        let (core, host) = makeCore()
        let datagram = Wire.guestUDP(to: remote, from: 40_000, pattern(300))
        feed(core, Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
        feed(core, datagram)  // opens the flow (allocates: policy evaluation, socket, event)
        host.datagramToRead = 1
        core.datagramReadable(token: host.token)
        let allocations = countAllocations {
            var round = 0
            while round < 500 {
                feed(core, datagram)
                host.datagramToRead = 1
                core.datagramReadable(token: host.token)
                round += 1
            }
        }
        #expect(host.datagramWrites == 501)
        #expect(allocations == 0, "\(allocations) allocations in 500 round trips")
    }

    @Test func housekeepingWithManyIdleFlowsDoesNotAllocate() {
        let (core, host) = makeCore()
        feed(core, Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
        for port in 0..<50 { feed(core, Wire.guestUDP(to: remote, from: UInt16(40_000 + port), [1])) }
        core.tick()
        let allocations = countAllocations {
            var round = 0
            while round < 200 {
                core.tick()
                round += 1
            }
        }
        #expect(host.datagramWrites == 50)
        #expect(allocations == 0, "\(allocations) allocations in 200 ticks over 50 flows")
    }

    /// The whole shell: kernel queue, guest socket, host UDP socket, bridge and core on the real loop thread. The test
    /// thread runs the loop; a second thread plays the guest and opens the measurement window once the flow is warm.
    @Test func theRealLoopDoesNotAllocatePerPacketForUDPRoundTrips() throws {
        let server = try #require(LoopbackUDPServer())
        defer { server.close() }
        let pair = try #require(SocketCalls.datagramPair(bufferSize: 1 << 20))
        let handle = try #require(KQueueHandle())
        let inbox = UserNetInbox(handle: handle)
        let (flowEvents, flowContinuation) = AsyncStream.makeStream(of: FlowEvent.self, bufferingPolicy: .bufferingNewest(16))
        let (vpnChanges, vpnContinuation) = AsyncStream.makeStream(of: GuestVPNState.self, bufferingPolicy: .bufferingNewest(4))
        _ = (flowEvents, vpnChanges)
        let loop = UserNetLoop(
            config: UserNetConfig(), policy: CoreRig.openPolicy, guestDescriptor: pair.hostSide, handle: handle, inbox: inbox,
            shared: UserNetSharedState(), flowEvents: flowContinuation, vpnChanges: vpnContinuation, resolver: StubResolver())
        let port = server.port
        let guestDescriptor = pair.guestSide
        let roundTrips = Atomic<Int>(0)
        let windowAllocations = Atomic<Int>(0)
        let feeder = Thread {
            let guest = GuestHarness(link: GuestLink(descriptor: guestDescriptor))
            guest.address = Wire.guest
            guest.link.send(Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway))
            _ = guest.link.receive(timeout: 2)
            let payload = pattern(300)
            var done = 0
            while done < 1_500 {
                if done == 200 { AllocationWindow.begin() }
                guest.sendUDP(to: (ipv4("127.0.0.1"), port), from: 40_000, payload)
                if guest.receiveUDP(on: 40_000, timeout: 2) == nil { break }
                done += 1
            }
            roundTrips.store(done, ordering: .relaxed)
            windowAllocations.store(AllocationWindow.end() ?? -1, ordering: .relaxed)  // before teardown, which does allocate
            inbox.post(.stop)
        }
        AllocationWindow.watchCurrentThread()
        feeder.start()
        loop.run()
        let allocations = windowAllocations.load(ordering: .relaxed)
        close(guestDescriptor)
        #expect(roundTrips.load(ordering: .relaxed) == 1_500)
        #expect(allocations == 0, "\(allocations) allocations on the loop thread over 1300 UDP round trips")
    }
}
