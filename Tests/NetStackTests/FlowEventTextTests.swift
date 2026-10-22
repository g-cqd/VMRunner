import Foundation
import Testing

@testable import NetPolicy
@testable import NetStack

/// The words for a flow event, shared by the app's log and the helper's event lines.
struct FlowEventTextTests {
    private func event(
        _ phase: FlowEvent.Phase = .opened, transport: FlowTransport = .tcp, address: String = "93.184.216.34", port: UInt16 = 443,
        name: String? = nil
    ) -> FlowEvent {
        FlowEvent(
            flowID: 1, transport: transport, phase: phase, remote: (ipv4(address), port), name: name, time: 0.5)
    }

    @Test
    func theDestinationIsTheAddressAndPortWithTheNameWhenThereIsOne() {
        #expect(event().destinationText == "93.184.216.34:443")
        #expect(event(name: "example.com").destinationText == "example.com (93.184.216.34:443)")
        #expect(event(port: 0).destinationText == "93.184.216.34")
    }

    @Test
    func aDnsEventIsJustTheNameAsked() {
        #expect(event(.answered(responseCode: 0), transport: .dns, port: 53, name: "example.com").destinationText == "example.com")
    }

    @Test
    func eachAnswerCodeHasItsWords() {
        #expect(FlowEvent.answerText(responseCode: 0) == "Name resolved")
        #expect(FlowEvent.answerText(responseCode: 3) == "No such name")
        #expect(FlowEvent.answerText(responseCode: 5) == "Refused")
        #expect(FlowEvent.answerText(responseCode: 2) == "Answered (code 2)")
    }

    @Test
    func transportsAreLabelledInCapitals() {
        #expect([FlowTransport.tcp, .udp, .icmp, .dns].map(\.label) == ["TCP", "UDP", "ICMP", "DNS"])
    }

    @Test
    func aDenialSaysWhyInAFullSentence() {
        let denials: [FlowDenial] = [
            .policy(.blockedPort(22)), .policy(.notAllowListed), .policy(.unresolved), .gatewayService(port: 80), .flowLimit, .unroutable,
        ]
        for denial in denials { #expect(denial.explanation.hasSuffix("."), "\(denial)") }
        #expect(FlowDenial.policy(.blockedPort(22)).explanation == "Port 22 is blocked.")
        #expect(FlowDenial.gatewayService(port: 80).explanation.contains("80"))
    }

    @Test
    func anEventIsOneLineWithItsOutcomeItsPlaceAndItsReason() throws {
        let blocked = NetworkPolicy.Reason.blockedPort(22)
        let denied = FlowEvent(
            flowID: 2, transport: .tcp, phase: .denied(.policy(blocked)), remote: (ipv4("93.184.216.34"), 22), name: "example.com",
            time: 1, count: 3)
        #expect(denied.outcomeWord == "denied")
        #expect(denied.eventLine == "TCP denied example.com (93.184.216.34:22): Port 22 is blocked. x3")
        #expect(event().eventLine == "TCP allowed 93.184.216.34:443")
        #expect(
            event(.answered(responseCode: 3), transport: .dns, port: 53, name: "nope.example").eventLine
                == "DNS answered nope.example: No such name")
        let revoked = event(.closed(.policyRevoked(blocked)))
        #expect(revoked.outcomeWord == "revoked" && revoked.eventLine.hasPrefix("TCP revoked "))
        #expect(!event().eventLine.contains("\n"))
    }

    @Test
    func aClosedFlowReportsWhyHowMuchAndHowLong() {
        let closed = FlowEvent(
            flowID: 3, transport: .tcp, phase: .closed(.finished), remote: (ipv4("93.184.216.34"), 80), name: nil, time: 4,
            bytesToHost: 120, bytesToGuest: 4_096, duration: 1.234)
        #expect(closed.outcomeWord == "closed")
        #expect(closed.eventLine == "TCP closed 93.184.216.34:80: finished, 120 bytes to the host, 4096 to the guest, 1.23 s")
    }

    @Test
    func theGuestVpnVerdictIsOneLineNamingTheKindAndTheConfidence() {
        #expect(GuestVPNState.none.eventLine == "Guest VPN: not detected")
        let suspected = GuestVPNState.suspected(kind: .wireGuard, confidence: .medium, since: 3, evidence: [])
        #expect(suspected.eventLine == "Guest VPN: WireGuard suspected (medium confidence)")
        #expect(GuestVPNKind.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(GuestVPNConfidence.low.label == "low" && GuestVPNConfidence.high.label == "high")
    }

    @Test
    func theCountersAreOneLineOfNamedValues() {
        var stats = UserNetStats()
        stats.tcpFlowsOpened = 7
        stats.dnsBlocked = 2
        stats.activeTCPFlows = 3
        let line = stats.summaryLine
        #expect(!line.contains("\n"))
        for pair in ["tcpFlowsOpened=7", "dnsBlocked=2", "activeTCPFlows=3", "bytesToGuest=0"] {
            #expect(line.split(separator: " ").contains(Substring(pair)), "\(pair)")
        }
    }

    @Test
    func theFloorIsNamedAsSuchAndAPrivateRangeIsNot() throws {
        let metadata = NetworkPolicy.Reason.reservedRange(.cloudMetadata, address: .v4(ipv4("169.254.169.254")))
        #expect(metadata.explanation.contains("a cloud metadata address") && metadata.explanation.contains("never let reach"))
        let lan = NetworkPolicy.Reason.reservedRange(.privateNetwork, address: .v4(ipv4("10.1.2.3")))
        #expect(lan.explanation.contains("private ranges are blocked"))
    }
}
