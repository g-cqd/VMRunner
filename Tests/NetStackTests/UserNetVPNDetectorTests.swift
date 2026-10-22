import Foundation
import Testing

@testable import NetPolicy
@testable import NetStack

// MARK: Packet crafting

private let peerA = "203.0.113.9"
private let peerB = "198.51.100.7"

/// Deterministic noise standing in for ciphertext.
private func noise(_ count: Int, seed: UInt8 = 0x5A) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ Int(seed)) | 0x01 }
}

private func padded(_ prefix: [UInt8], to length: Int) -> [UInt8] {
    prefix + noise(max(0, length - prefix.count))
}

private func bigEndian(_ value: Int, bytes: Int) -> [UInt8] {
    (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * (bytes - 1 - $0))) }
}

/// An array-backed packet; production code uses non-owning views, so the tests convert at the call.
private struct TestPacket {
    var direction: GuestPacketObservation.Direction
    var peer: IPAddress
    var transport: GuestPacketObservation.Transport
    var payload: [UInt8]
    var wireLength: Int
}

extension GuestVPNDetector {
    fileprivate mutating func observe(_ packet: TestPacket, at now: TimeInterval) -> GuestVPNState? {
        ByteView.withBytes(of: packet.payload) { view in
            observe(
                GuestPacketObservation(
                    direction: packet.direction, peer: packet.peer, transport: packet.transport, payload: view,
                    wireLength: packet.wireLength),
                at: now)
        }
    }
}

private func udp(
    _ payload: [UInt8], to port: UInt16, from source: UInt16 = 41_000, peer: String = peerA,
    direction: GuestPacketObservation.Direction = .fromGuest
) -> TestPacket {
    let ports = direction == .fromGuest ? (source, port) : (port, source)
    return TestPacket(
        direction: direction, peer: host(peer), transport: .udp(sourcePort: ports.0, destinationPort: ports.1),
        payload: payload, wireLength: payload.count + 28)
}

private func tcp(
    _ payload: [UInt8], to port: UInt16, peer: String = peerA, direction: GuestPacketObservation.Direction = .fromGuest
) -> TestPacket {
    let ports = direction == .fromGuest ? (UInt16(50_000), port) : (port, UInt16(50_000))
    return TestPacket(
        direction: direction, peer: host(peer), transport: .tcp(sourcePort: ports.0, destinationPort: ports.1),
        payload: payload, wireLength: payload.count + 40)
}

private func ipProtocol(
    _ number: UInt8, _ payload: [UInt8], peer: String = peerA, direction: GuestPacketObservation.Direction = .fromGuest
) -> TestPacket {
    TestPacket(
        direction: direction, peer: host(peer), transport: .ipProtocol(number), payload: payload,
        wireLength: payload.count + 20)
}

private func host(_ text: String) -> IPAddress {
    IPAddress(strictLiteral: text) ?? .v4(0)
}

private func wireGuard(type: UInt8, length: Int) -> [UInt8] {
    padded([type, 0, 0, 0], to: length)
}

private let openVPNSessionID: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]

private func openVPNClientReset() -> [UInt8] {
    [0x38] + openVPNSessionID + [0] + [0, 0, 0, 0]
}

private func openVPNServerReset() -> [UInt8] {
    [0x40] + openVPNSessionID + [1] + [0, 0, 0, 0] + [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x01, 0x02] + [0, 0, 0, 0]
}

private func ikeHeader(version: UInt8, exchange: UInt8, length: Int, flags: UInt8 = 0x08) -> [UInt8] {
    let message = [UInt8](repeating: 0xA5, count: 8) + [UInt8](repeating: 0, count: 8) + [33, version, exchange, flags] + [0, 0, 0, 0]
    return message + bigEndian(length, bytes: 4)
}

private func ike(version: UInt8 = 0x20, exchange: UInt8 = 34, length: Int = 296, marker: Bool = false) -> [UInt8] {
    (marker ? [0, 0, 0, 0] : []) + padded(ikeHeader(version: version, exchange: exchange, length: length), to: length)
}

private func l2tpControl() -> [UInt8] {
    padded([0xC8, 0x02] + bigEndian(20, bytes: 2), to: 20)
}

private func pptpControl() -> [UInt8] {
    padded(bigEndian(156, bytes: 2) + [0, 1, 0x1A, 0x2B, 0x3C, 0x4D, 0, 1], to: 156)
}

private let greEnhanced: [UInt8] = padded([0x30, 0x01, 0x88, 0x0B], to: 40)
private let esp: [UInt8] = padded([0xC1, 0x02, 0x03, 0x04, 0, 0, 0, 1], to: 100)

/// Feeds packets one second apart from `start` and returns the detector's final state.
private func run(
    _ packets: [TestPacket], configuration: GuestVPNDetector.Configuration = .init(), start: TimeInterval = 0
) -> GuestVPNDetector {
    var detector = GuestVPNDetector(configuration: configuration)
    for (index, packet) in packets.enumerated() { _ = detector.observe(packet, at: start + TimeInterval(index)) }
    return detector
}

private func expectSuspected(
    _ detector: GuestVPNDetector, _ kind: GuestVPNKind, atLeast level: GuestVPNConfidence = .low,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(detector.state.kind == kind, sourceLocation: sourceLocation)
    #expect((detector.state.confidence ?? .low) >= level, sourceLocation: sourceLocation)
}

// MARK: Positives

struct VPNDetectorPositiveTests {
    @Test func wireGuardHandshakePairReachesHigh() throws {
        let detector = run([
            udp(wireGuard(type: 1, length: 148), to: 51_820),
            udp(wireGuard(type: 2, length: 92), to: 51_820, direction: .toGuest),
        ])
        expectSuspected(detector, .wireGuard, atLeast: .high)
        let evidence = try #require(detector.state.kind == .wireGuard ? detector.state : nil)
        if case .suspected(_, _, _, let items) = evidence {
            #expect(Set(items.map(\.signature)) == [.wireGuardInitiation, .wireGuardResponse])
            #expect(items.allSatisfy { $0.peer != nil && !$0.reason.isEmpty })
        }
    }

    @Test func wireGuardKeepaliveAndDataStreamIsSuspectedButNotHigh() throws {
        var packets: [TestPacket] = []
        for index in 0..<4 {
            packets.append(udp(wireGuard(type: 4, length: 32), to: 51_820))
            packets.append(udp(wireGuard(type: 4, length: 32 + 16 * (index + 1)), to: 51_820, direction: .toGuest))
        }
        let detector = run(packets)
        expectSuspected(detector, .wireGuard)
        #expect(detector.state.confidence != .high)
    }

    @Test func wireGuardIsRecognizedOnAnyPortIncludingHTTPSAndDNSPorts() throws {
        for port: UInt16 in [443, 53, 12_345] {
            let detector = run([
                udp(wireGuard(type: 1, length: 148), to: port), udp(wireGuard(type: 2, length: 92), to: port, direction: .toGuest),
            ])
            expectSuspected(detector, .wireGuard, atLeast: .high)
        }
    }

    @Test func wireGuardCookieReplyIsAWeakSignature() throws {
        let detector = run([udp(wireGuard(type: 3, length: 64), to: 51_820), udp(wireGuard(type: 3, length: 64), to: 51_820)])
        #expect(detector.state == .none)
    }

    @Test func openVPNUDPHandshakeReachesHigh() throws {
        let detector = run([
            udp(openVPNClientReset(), to: 1_194), udp(openVPNServerReset(), to: 1_194, direction: .toGuest),
        ])
        expectSuspected(detector, .openVPN, atLeast: .high)
    }

    @Test func openVPNOnAnUnusualPortIsStillRecognized() throws {
        let detector = run([
            udp(openVPNClientReset(), to: 8_443), udp(openVPNClientReset(), to: 8_443),
            udp(openVPNServerReset(), to: 8_443, direction: .toGuest),
        ])
        expectSuspected(detector, .openVPN, atLeast: .high)
    }

    @Test func openVPNWithTLSAuthTailIsMediumAtBest() throws {
        let client = padded(Array(openVPNClientReset().prefix(9)), to: 54)
        let detector = run([udp(client, to: 1_194), udp(client, to: 1_194)])
        expectSuspected(detector, .openVPN)
        #expect(detector.state.confidence != .high)
    }

    @Test func openVPNOverTCPUsesTheLengthPrefix() throws {
        let reset = openVPNClientReset()
        let framed = bigEndian(reset.count, bytes: 2) + reset
        let server = openVPNServerReset()
        let detector = run([
            tcp(framed, to: 1_194), tcp(bigEndian(server.count, bytes: 2) + server, to: 1_194, direction: .toGuest),
        ])
        expectSuspected(detector, .openVPN, atLeast: .high)
    }

    @Test func openVPNDataOpcodesCountOnlyOnAKnownPeerOrPort() throws {
        let data = padded([0x48, 0, 0, 1], to: 100)
        #expect(run([udp(data, to: 40_000), udp(data, to: 40_000), udp(data, to: 40_000)]).state == .none)
        // Data-plane shapes are weak by design: even on 1194 they cap out below the entry score.
        #expect(run((0..<6).map { _ in udp(data, to: 1_194) }).state == .none)
        let afterReset = run([udp(openVPNClientReset(), to: 40_000), udp(data, to: 40_000), udp(data, to: 40_000)])
        expectSuspected(afterReset, .openVPN)
    }

    @Test(arguments: [UInt16(500), 4_500])
    func ikeV2OnIKEPortsIsRecognized(port: UInt16) throws {
        let marker = port == 4_500
        let detector = run([
            udp(ike(marker: marker), to: port, from: port),
            udp(ike(exchange: 34, length: 336, marker: marker), to: port, from: port, direction: .toGuest),
        ])
        expectSuspected(detector, .ipsec, atLeast: .high)
    }

    @Test func ikeV1AggressiveModeIsRecognized() throws {
        let packet = ike(version: 0x10, exchange: 4, length: 200)
        expectSuspected(run([udp(packet, to: 500, from: 500), udp(packet, to: 500, from: 500)]), .ipsec)
    }

    @Test func natTKeepalivesAfterIKECountTowardIPsec() throws {
        let detector = run([
            udp(ike(marker: true), to: 4_500, from: 4_500), udp([0xFF], to: 4_500, from: 4_500), udp([0xFF], to: 4_500, from: 4_500),
        ])
        expectSuspected(detector, .ipsec)
    }

    @Test func espPacketsAreRecognizedFromTheSecondOne() throws {
        var detector = GuestVPNDetector()
        #expect(detector.observe(ipProtocol(50, esp), at: 0) == nil)
        let second = detector.observe(ipProtocol(50, esp), at: 1)
        let changed = try #require(second)
        #expect(changed.kind == .ipsec)
        let ah = padded([0x33, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1], to: 60)
        expectSuspected(run([ipProtocol(51, ah), ipProtocol(51, ah)]), .ipsec)
    }

    @Test func espInUDPNeedsAnIKEPeer() throws {
        let natEsp = padded([0xC1, 0x02, 0x03, 0x04, 0, 0, 0, 1], to: 100)
        #expect(run([udp(natEsp, to: 4_500, from: 4_500), udp(natEsp, to: 4_500, from: 4_500)]).state == .none)
    }

    @Test func l2tpControlMessagesAreRecognized() throws {
        let packet = l2tpControl()
        let detector = run([udp(packet, to: 1_701, from: 1_701), udp(packet, to: 1_701, from: 1_701, direction: .toGuest)])
        expectSuspected(detector, .l2tp)
    }

    @Test func pptpControlAndGREReachHigh() throws {
        let detector = run([
            tcp(pptpControl(), to: 1_723), ipProtocol(47, greEnhanced), ipProtocol(47, greEnhanced, direction: .toGuest),
        ])
        expectSuspected(detector, .pptp, atLeast: .high)
    }
}

// MARK: Negatives

struct VPNDetectorNegativeTests {
    private func expectNone(_ packets: [TestPacket], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run(packets).state == .none, sourceLocation: sourceLocation)
    }

    @Test func dnsQueriesAndResponsesAreNotVPN() throws {
        let query = padded([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0], to: 33)
        let response = padded([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0], to: 96)
        expectNone((0..<20).flatMap { _ in [udp(query, to: 53), udp(response, to: 53, direction: .toGuest)] })
    }

    @Test func ntpAndMDNSAreNotVPN() throws {
        let ntp = padded([0x23], to: 48)
        let mdns = padded([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0], to: 40)
        expectNone((0..<20).flatMap { _ in [udp(ntp, to: 123, from: 123), udp(mdns, to: 5_353, from: 5_353)] })
    }

    @Test func stunBindingRequestsAreNotVPN() throws {
        let stun = padded([0, 1, 0, 0x08, 0x21, 0x12, 0xA4, 0x42], to: 28)
        expectNone((0..<20).map { _ in udp(stun, to: 3_478) })
    }

    @Test func sustainedHighVolumeQUICOnPort443IsNotVPN() throws {
        var packets: [TestPacket] = []
        for index in 0..<400 {
            let long = padded([0xC3, 0, 0, 0, 1, 8], to: 1_200)
            let short = padded([0x40 | UInt8(index & 0x3F)], to: 1_232 - (index % 4) * 16)
            packets.append(udp(index == 0 ? long : short, to: 443))
            packets.append(udp(padded([0x41], to: 1_200 + (index % 3) * 16), to: 443, direction: .toGuest))
        }
        expectNone(packets)
    }

    @Test func tlsClientHelloHTTPAndSSHOnTCPAreNotVPN() throws {
        let hello = padded([0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xFC, 0x03, 0x03], to: 517)
        let http = Array("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n".utf8)
        let ssh = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)
        expectNone((0..<10).flatMap { _ in [tcp(hello, to: 443), tcp(http, to: 80), tcp(ssh, to: 22)] })
    }

    @Test func tlsOnPPTPPortOrOpenVPNPortIsNotVPN() throws {
        let hello = padded([0x16, 0x03, 0x01, 0x02, 0x00, 0x01], to: 517)
        expectNone((0..<10).flatMap { _ in [tcp(hello, to: 1_723), tcp(hello, to: 1_194)] })
    }

    @Test func aLoneWeakMatchDoesNotTrigger() throws {
        var detector = GuestVPNDetector()
        let lone = udp(wireGuard(type: 4, length: 32), to: 40_000)
        #expect(detector.observe(lone, at: 0) == nil)
        #expect(detector.state == .none)
        let single = udp(wireGuard(type: 1, length: 148), to: 40_000, peer: peerB)
        #expect(detector.observe(single, at: 1) == nil)
        #expect(detector.state == .none)
        #expect(detector.observe(ipProtocol(50, esp), at: 2) == nil)
    }

    @Test func nearMissesOfEachSignatureDoNotMatch() throws {
        let cases: [TestPacket] = [
            udp(wireGuard(type: 1, length: 147), to: 40_000), udp(wireGuard(type: 2, length: 93), to: 40_000),
            udp(wireGuard(type: 4, length: 33), to: 40_000), udp([1, 0, 0, 1] + noise(144), to: 40_000),
            udp(ike(length: 296) + [0], to: 500, from: 500), udp(ike(version: 0x30), to: 500, from: 500),
            udp(ike(exchange: 99), to: 500, from: 500), udp(ike(), to: 40_000),
            udp(padded([0xC8, 0x03] + bigEndian(20, bytes: 2), to: 20), to: 1_701),
            udp(padded([0xC8, 0x02] + bigEndian(21, bytes: 2), to: 20), to: 1_701),
            udp([0x38] + [UInt8](repeating: 0, count: 8) + [0, 0, 0, 0, 0], to: 1_194),
            tcp(bigEndian(99, bytes: 2) + openVPNClientReset(), to: 1_194),
            tcp(padded(bigEndian(156, bytes: 2) + [0, 1, 0xDE, 0xAD, 0xBE, 0xEF], to: 156), to: 1_723),
            ipProtocol(47, padded([0, 0, 0x08, 0x00], to: 40)), ipProtocol(50, padded([0, 0, 0, 0], to: 40)),
        ]
        for packet in cases { expectNone([packet, packet, packet, packet]) }
    }
}

// MARK: Debounce, hysteresis, decay

struct VPNDetectorDebounceTests {
    private func handshake() -> [TestPacket] {
        [
            udp(wireGuard(type: 1, length: 148), to: 51_820), udp(wireGuard(type: 2, length: 92), to: 51_820, direction: .toGuest),
        ]
    }

    @Test func onlyTransitionsAreReportedAndASinglePacketNeverFlaps() throws {
        var detector = GuestVPNDetector()
        let pair = handshake()
        #expect(detector.observe(pair[0], at: 0) == nil)
        let enteredState = detector.observe(pair[1], at: 1)
        let entered = try #require(enteredState)
        #expect(entered.confidence == .high)
        let keepalive = udp(wireGuard(type: 4, length: 32), to: 51_820)
        for second in 2..<50 { #expect(detector.observe(keepalive, at: TimeInterval(second)) == nil) }
        let unrelated = udp(padded([0x12, 0x34, 0x01, 0x00], to: 40), to: 53, peer: peerB)
        for second in 50..<60 { #expect(detector.observe(unrelated, at: TimeInterval(second)) == nil) }
        #expect(detector.state.confidence == .high)
    }

    @Test func confidenceRisesWhileSinceIsKept() throws {
        var detector = GuestVPNDetector()
        let initiation = udp(wireGuard(type: 1, length: 148), to: 51_820)
        #expect(detector.observe(initiation, at: 10) == nil)
        let mediumState = detector.observe(initiation, at: 15)
        let medium = try #require(mediumState)
        #expect(medium.confidence == .medium)
        let highState = detector.observe(udp(wireGuard(type: 2, length: 92), to: 51_820, direction: .toGuest), at: 16)
        let high = try #require(highState)
        #expect(high.confidence == .high)
        if case .suspected(_, _, let since, _) = high {
            #expect(since == 15)
        } else {
            Issue.record("expected a suspected state")
        }
    }

    @Test func stateHoldsDuringTheQuietPeriodAndDecaysAfterIt() throws {
        var detector = run(handshake(), start: 0)
        #expect(detector.state.kind == .wireGuard)
        #expect(detector.tick(at: 200) == nil)
        #expect(detector.state.confidence == .high)
        // Refreshing the initiation at t=250 keeps it alive; the response (t=1) expires at 301 and confidence drops.
        _ = detector.observe(handshake()[0], at: 250)
        let downgraded = detector.tick(at: 520)
        #expect(downgraded?.kind == .wireGuard)
        #expect(downgraded?.confidence != .high)
        let cleared = detector.tick(at: 600)
        #expect(cleared == GuestVPNState.none)
        #expect(detector.state == .none)
        #expect(detector.tick(at: 700) == nil)
    }

    @Test func confidenceDowngradesOnlyAsEvidenceExpires() throws {
        var configuration = GuestVPNDetector.Configuration()
        configuration.evidenceLifetime = 100
        var detector = GuestVPNDetector(configuration: configuration)
        let pair = handshake()
        _ = detector.observe(pair[0], at: 0)
        _ = detector.observe(pair[1], at: 1)
        _ = detector.observe(pair[0], at: 80)
        // The response (last seen at 1) expires at 101; the initiation (80) survives and still counts twice.
        let downgradedState = detector.tick(at: 120)
        let downgraded = try #require(downgradedState)
        #expect(downgraded.kind == .wireGuard)
        #expect(downgraded.confidence == .medium)
        #expect(detector.tick(at: 200) == GuestVPNState.none)
    }

    @Test func aStrongerKindReplacesTheHeldOneOnlyPastTheMargin() throws {
        var detector = GuestVPNDetector()
        let wg = handshake()
        for packet in wg { _ = detector.observe(packet, at: 0) }
        #expect(detector.state.kind == .wireGuard)
        // A PPTP pair scores the same (8): not enough to displace WireGuard.
        for packet in [tcp(pptpControl(), to: 1_723, peer: peerB), ipProtocol(47, greEnhanced, peer: peerB)] {
            _ = detector.observe(packet, at: 1)
        }
        #expect(detector.state.kind == .wireGuard)
        // More PPTP data pushes it 2+ points ahead.
        let switched = detector.observe(ipProtocol(47, greEnhanced, peer: peerB, direction: .toGuest), at: 2)
        #expect(switched?.kind == .pptp)
        #expect(detector.state.kind == .pptp)
    }

    @Test func evidenceIsBoundedAndPayloadsAreNotRetained() throws {
        var detector = GuestVPNDetector()
        for index in 0..<500 {
            let peer = "10.\(index / 250).\((index % 250) + 1).1"
            _ = detector.observe(udp(wireGuard(type: 1, length: 148), to: 40_000, peer: peer), at: TimeInterval(index) * 0.001)
        }
        if case .suspected(_, _, _, let evidence) = detector.state { #expect(evidence.count <= 8) }
    }
}

// MARK: DNS hints

struct VPNDetectorHintTests {
    @Test func theDefaultHintListIsEmptyAndHasNoEffect() {
        let configuration = GuestVPNDetector.Configuration()
        #expect(configuration.hintDomains.isEmpty)
        var detector = GuestVPNDetector(configuration: configuration)
        for second in 0..<10 { #expect(detector.observeDNSQuery(name: "vpn.example.test", at: TimeInterval(second)) == nil) }
        #expect(detector.state == .none)
    }

    @Test func aConfiguredHintGivesLowConfidenceAtMost() throws {
        var configuration = GuestVPNDetector.Configuration()
        configuration.hintDomains = [try DomainRule("*.vpn.example.test"), try DomainRule("tunnel.example.test")]
        var detector = GuestVPNDetector(configuration: configuration)
        #expect(detector.observeDNSQuery(name: "gw.vpn.example.test", at: 0) == nil)
        let changed = detector.observeDNSQuery(name: "TUNNEL.example.test.", at: 1)
        let state = try #require(changed)
        #expect(state.kind == .dnsHint)
        #expect(state.confidence == .low)
        for second in 2..<100 { _ = detector.observeDNSQuery(name: "gw.vpn.example.test", at: TimeInterval(second)) }
        #expect(detector.state.confidence == .low)
        #expect(detector.observeDNSQuery(name: "unrelated.example.org", at: 120) == nil)
    }

    @Test func aRealSignatureOutranksAHint() throws {
        var configuration = GuestVPNDetector.Configuration()
        configuration.hintDomains = [try DomainRule("tunnel.example.test")]
        var detector = GuestVPNDetector(configuration: configuration)
        _ = detector.observeDNSQuery(name: "tunnel.example.test", at: 0)
        _ = detector.observeDNSQuery(name: "tunnel.example.test", at: 1)
        #expect(detector.state.kind == .dnsHint)
        _ = detector.observe(udp(wireGuard(type: 1, length: 148), to: 51_820), at: 2)
        _ = detector.observe(udp(wireGuard(type: 2, length: 92), to: 51_820, direction: .toGuest), at: 3)
        #expect(detector.state.kind == .wireGuard)
        #expect(detector.state.confidence == .high)
    }
}
