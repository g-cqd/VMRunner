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
    func theFloorIsNamedAsSuchAndAPrivateRangeIsNot() throws {
        let metadata = NetworkPolicy.Reason.reservedRange(.cloudMetadata, address: .v4(ipv4("169.254.169.254")))
        #expect(metadata.explanation.contains("a cloud metadata address") && metadata.explanation.contains("never let reach"))
        let lan = NetworkPolicy.Reason.reservedRange(.privateNetwork, address: .v4(ipv4("10.1.2.3")))
        #expect(lan.explanation.contains("private ranges are blocked"))
    }
}
