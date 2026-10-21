import Foundation
import TestKit
import Testing

@testable import VMRunner

private func endpoint(_ transport: FlowTransport = .udp, _ port: UInt16 = 9_999, name: String? = nil) -> DenialSuppression.Endpoint {
    DenialSuppression.Endpoint(transport: transport, address: ipv4("93.184.216.34"), port: port, name: name)
}

private let reason = FlowDenial.gatewayService(port: 9_999)

struct DenialSuppressionTests {
    /// `#expect` cannot hold a mutating call, so the table is driven through this.
    private func admit(
        _ table: inout DenialSuppression, _ target: DenialSuppression.Endpoint = endpoint(), _ denial: FlowDenial = reason,
        name: String? = nil, at now: TimeInterval
    ) -> DenialSuppression.Admission {
        table.admit(target, denial, name: name, now: now)
    }

    @Test func aRefusalIsPublishedOnceAndTheRepeatsAreCounted() {
        var table = DenialSuppression()
        #expect(admit(&table, at: 0) == .publish(held: nil))
        for second in 1...4 { #expect(admit(&table, at: TimeInterval(second)) == .suppress) }
        let expected = DenialSuppression.Held(endpoint: endpoint(), denial: reason, name: nil, count: 4)
        #expect(admit(&table, at: 6) == .publish(held: expected), "the next one carries the count")
        #expect(admit(&table, at: 7) == .suppress)
    }

    @Test func aDifferentReasonForTheSameDestinationIsNewsAtOnce() {
        var table = DenialSuppression()
        _ = admit(&table, at: 0)
        #expect(admit(&table, endpoint(), .flowLimit, at: 1) == .publish(held: nil))
    }

    @Test func destinationsAreToldApartByTransportPortAndDNSName() {
        var table = DenialSuppression()
        let all = [
            endpoint(.udp), endpoint(.tcp), endpoint(.udp, 53), endpoint(.dns, 53, name: "a.test"), endpoint(.dns, 53, name: "b.test"),
        ]
        for candidate in all { #expect(admit(&table, candidate, at: 0) == .publish(held: nil)) }
        #expect(table.count == 5)
    }

    @Test func whatWasHeldBackIsHandedOverWhenTheIntervalEnds() {
        var table = DenialSuppression()
        _ = admit(&table, endpoint(.udp, 1), at: 0)
        _ = admit(&table, endpoint(.udp, 2), name: "named", at: 0)
        for _ in 0..<3 { _ = admit(&table, endpoint(.udp, 2), name: "named", at: 1) }
        let early = table.expire(now: 4)
        #expect(early.isEmpty, "inside the interval nothing is due")
        let due = table.expire(now: 5)
        #expect(due == [DenialSuppression.Held(endpoint: endpoint(.udp, 2), denial: reason, name: "named", count: 3)])
        #expect(table.count < 1, "and the table is empty again")
    }

    @Test func theTableIsBoundedAndFreesItselfAsIntervalsEnd() {
        var table = DenialSuppression()
        var published = 0
        for port in 1...1_000 {
            if case .publish = admit(&table, endpoint(.tcp, UInt16(port)), at: 0) { published += 1 }
        }
        #expect(published == DenialSuppression.capacity && table.count == DenialSuppression.capacity)
        #expect(admit(&table, endpoint(.tcp, 5_000), at: 6) == .publish(held: nil), "old entries make room")
    }

    @Test func absorbingOnlyHappensInsideTheIntervalAndIsCounted() {
        var table = DenialSuppression()
        let before = table.absorbs(endpoint(), now: 0)
        #expect(!before, "nothing was refused yet")
        _ = admit(&table, at: 0)
        let inside = [table.absorbs(endpoint(), now: 1), table.absorbs(endpoint(), now: 2)]
        let after = table.absorbs(endpoint(), now: 5)
        #expect(inside == [true, true] && !after)
        let drained = table.drain()
        #expect(drained.map(\.count) == [2])
        #expect(table.count < 1)
    }
}

/// Floods through the core: what the guest can make the stack publish.
struct UserNetDenialFloodTests {
    private static let denied = ipv4("10.0.0.5")

    private func start(_ policy: NetworkPolicy = NetworkPolicy()) -> CoreRig {
        let rig = CoreRig(policy: policy)
        rig.learnGuest()
        return rig
    }

    private func syn(_ rig: CoreRig, to target: (UInt32, UInt16), from port: UInt16) {
        let segment = Wire.tcp(from: (Wire.guest, port), to: target, sequence: 1, flags: .syn, mss: 1_460)
        ByteView.withBytes(of: Wire.guestFrame(Wire.ipv4(from: Wire.guest, to: target.0, proto: IPProtocol.tcp, segment))) {
            rig.core.receiveFrame($0)
        }
    }

    private func attempts(_ rig: CoreRig, _ matches: (FlowEvent) -> Bool) -> Int {
        rig.host.events.filter(matches).reduce(0) { $0 + $1.count }
    }

    @Test func tenThousandDatagramsToAClosedGatewayPortAreOneEventAndOneSummary() {
        let rig = start()
        for index in 0..<10_000 {
            rig.send(Wire.guestUDP(to: (Wire.gateway, 123), from: UInt16(10_000 + index % 50_000), [1]))
        }
        let before = rig.host.events.filter { $0.phase == .denied(.gatewayService(port: 123)) }
        #expect(before.count == 1, "a guest rotating its source ports still gets one event")
        rig.advance(6)
        let all = rig.host.events.filter { $0.phase == .denied(.gatewayService(port: 123)) }
        #expect(all.count == 2, "plus one that says how many were folded in")
        #expect(all.reduce(0) { $0 + $1.count } == 10_000, "and nothing is lost but the repetition")
        #expect(rig.core.stats.deniedEventsSuppressed == 9_999)
    }

    @Test func tenThousandSynsToADeniedDestinationAreStillResetButReportedOnce() {
        let rig = start()
        for index in 0..<10_000 { syn(rig, to: (Self.denied, 22), from: UInt16(10_000 + index % 50_000)) }
        rig.core.endOfBatch()
        #expect(rig.core.stats.tcpFlowsDenied == 10_000, "every attempt is counted")
        #expect(rig.core.stats.framesToGuest >= 10_000, "and every one is answered with a reset, as before")
        let policyDenials: (FlowEvent) -> Bool = { if case .denied(.policy) = $0.phase { true } else { false } }
        #expect(rig.host.events.filter(policyDenials).count == 1)
        rig.advance(6)
        #expect(rig.host.events.filter(policyDenials).count == 2)
        #expect(attempts(rig, policyDenials) == 10_000)
    }

    @Test func aSweepOfDestinationsIsBoundedByTheTableNotByTheGuest() {
        let rig = start()
        for port in 1_000..<11_000 { syn(rig, to: (Self.denied, UInt16(port)), from: 50_000) }  // not 53: that one is DNS
        let published = rig.host.events.count
        #expect(published == DenialSuppression.capacity, "\(published) events for 10,000 probes")
        #expect(rig.core.stats.deniedEventsSuppressed == UInt64(10_000 - DenialSuppression.capacity))
        rig.advance(6)
        syn(rig, to: (Self.denied, 22), from: 50_001)
        #expect(rig.host.events.count > published, "once the intervals are over, news is news again")
    }

    @Test func tenThousandRefusedDNSQuestionsAreAnsweredEachButReportedOnce() throws {
        var policy = NetworkPolicy()
        policy.blockedDomains = [try DomainRule("blocked.test")]
        let rig = start(policy)
        for index in 0..<10_000 {
            rig.send(
                Wire.guestUDP(to: (Wire.gateway, 53), from: UInt16(10_000 + index % 50_000), Wire.dnsQuery(id: index, name: "blocked.test"))
            )
        }
        #expect(rig.host.resolutions.isEmpty)
        #expect(rig.core.stats.framesToGuest >= 10_000, "the guest still gets its NXDOMAIN every time")
        let refusals: (FlowEvent) -> Bool = { if case .denied = $0.phase { true } else { false } }
        #expect(rig.host.events.filter(refusals).count == 1)
        rig.advance(6)
        #expect(attempts(rig, refusals) == 10_000)
    }

    @Test func aChangedPolicyForgetsEarlierRefusalsAndReportsWhatWasHeld() throws {
        var strict = CoreRig.openPolicy
        strict.blockedAddresses = [try AddressRule("10.0.0.0/8")]
        let rig = start(strict)
        for _ in 0..<5 { rig.send(Wire.guestUDP(to: (Self.denied, 9_000), [1])) }
        #expect(rig.host.datagrams.isEmpty)
        rig.core.updatePolicy(CoreRig.openPolicy, existingFlows: .keep)
        let held = rig.host.events.filter { $0.count > 1 }
        #expect(held.map(\.count) == [4], "the four held back went out when the policy changed")
        rig.send(Wire.guestUDP(to: (Self.denied, 9_000), [1]))
        #expect(rig.host.datagrams.count == 1, "the new policy applies to the very next datagram, not after the interval")
    }

    @Test func aRefusalThatGoesAwayAndComesBackIsReportedAgain() {
        let rig = start()
        syn(rig, to: (Self.denied, 22), from: 50_000)
        rig.advance(6)
        syn(rig, to: (Self.denied, 22), from: 50_000)
        #expect(rig.host.events.count == 2)
    }
}

/// A stand-in for the stack's clock that tests move by hand: log lines are timed by the events' own time.
private func seconds(_ clock: TestClock) -> TimeInterval {
    let parts = clock.now.offset.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
}

struct FlowLogThrottleTests {
    private let clock = TestClock()

    private func denied(
        _ reason: FlowDenial = .flowLimit, port: UInt16 = 22, transport: FlowTransport = .tcp, count: Int = 1
    ) -> FlowEvent {
        FlowEvent(
            flowID: 1, transport: transport, phase: .denied(reason), remote: (ipv4("10.0.0.5"), port), name: "secret.test",
            time: seconds(clock), count: count)
    }

    @Test func tenThousandDenialsMakeOneLineAndTheNextIntervalSaysHowManyWereHeld() {
        var throttle = FlowLogThrottle()
        let first = throttle.line(for: denied())
        #expect(
            first
                == FlowLogThrottle.Line(
                    kind: "tcp", outcome: "denied", reason: "flow limit", destination: "10.0.0.5:22 secret.test", held: 0))
        for _ in 0..<9_999 {
            #expect(throttle.line(for: denied()) == nil)
        }
        clock.advance(by: .seconds(5))
        #expect(throttle.line(for: denied())?.held == 9_999)
        #expect(throttle.line(for: denied()) == nil)
    }

    @Test func anotherDestinationReasonOrTransportIsItsOwnLine() {
        var throttle = FlowLogThrottle()
        #expect(throttle.line(for: denied()) != nil)
        #expect(throttle.line(for: denied(port: 23)) != nil)
        #expect(throttle.line(for: denied(.unroutable)) != nil)
        #expect(throttle.line(for: denied(transport: .udp)) != nil)
        #expect(throttle.line(for: denied()) == nil)
    }

    @Test func aSummaryEventAddsItsWholeCountToTheHeldBackLines() {
        var throttle = FlowLogThrottle()
        _ = throttle.line(for: denied())
        #expect(throttle.line(for: denied(count: 40)) == nil)
        clock.advance(by: .seconds(5))
        #expect(throttle.line(for: denied())?.held == 40)
    }

    @Test func onlyDenialsAndFailuresAreWorthALine() {
        var throttle = FlowLogThrottle()
        func event(_ phase: FlowEvent.Phase) -> FlowEvent {
            FlowEvent(flowID: 1, transport: .tcp, phase: phase, remote: (ipv4("93.184.216.34"), 443), name: nil, time: seconds(clock))
        }
        #expect(throttle.line(for: event(.opened)) == nil)
        #expect(throttle.line(for: event(.closed(.finished))) == nil)
        #expect(throttle.line(for: event(.answered(responseCode: 0))) == nil)
        #expect(throttle.line(for: event(.closed(.connectFailed(61))))?.outcome == "failed")
    }

    @Test func aSweepOfDestinationsGetsAtMostTheTableSizeInLines() {
        var throttle = FlowLogThrottle()
        let lines = (1...10_000).filter { throttle.line(for: denied(port: UInt16($0))) != nil }
        #expect(lines.count == FlowLogThrottle.capacity)
        clock.advance(by: .seconds(6))
        #expect(throttle.line(for: denied(port: 40_000)) != nil, "and room again after the interval")
    }
}

struct FlowEventStreamTests {
    /// A reader that falls behind loses the oldest events; the loop's stats say how many.
    @Test func eventsTheReaderHadNoRoomForAreCounted() throws {
        let (stream, continuation) = AsyncStream.makeStream(of: FlowEvent.self, bufferingPolicy: .bufferingNewest(3))
        let pair = try #require(SocketCalls.datagramPair(bufferSize: 1 << 16))
        defer {
            SocketCalls.close(pair.guestSide)
            SocketCalls.close(pair.hostSide)
        }
        let handle = try #require(KQueueHandle())
        let bridge = UserNetBridge(
            guestDescriptor: pair.hostSide, mtu: 1_500, flowEvents: continuation, vpnSink: { _ in }, resolver: StubResolver(),
            inbox: UserNetInbox(handle: handle))
        withExtendedLifetime(stream) {  // a finished stream would report .terminated, not .dropped
            for index in 0..<10 {
                let event = FlowEvent(
                    flowID: UInt64(index), transport: .tcp, phase: .opened, remote: (ipv4("93.184.216.34"), 443), name: nil, time: 0)
                bridge.publish(event)
            }
        }
        #expect(bridge.flowEventsDropped == 7)
    }
}
