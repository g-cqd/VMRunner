import Foundation
import Testing

@testable import ContainerSpikeCore

struct LoopbackTests {
    /// "who has 198.18.0.1, tell 198.18.0.2", as a guest sends it: broadcast destination, the guest's own hardware address.
    private static let arpRequest: [UInt8] =
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0xC6, 0x12, 0x00, 0x02, 0x08, 0x06]
        + [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01]
        + [0x02, 0x00, 0xC6, 0x12, 0x00, 0x02, 198, 18, 0, 2]
        + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 198, 18, 0, 1]

    private static func ipv4Frame(protocolNumber: UInt8, destination: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 14 + 20)
        frame[12] = 0x08
        frame[23] = protocolNumber
        frame.replaceSubrange(30..<34, with: destination)
        return frame
    }

    @Test
    func anArpRequestIsReadAsWhoHasAndTellsWhoAsked() throws {
        let frame = try #require(FrameSummary.parse(Self.arpRequest))
        #expect(frame.kind == .arpRequest(sender: "198.18.0.2", target: "198.18.0.1"))
        #expect(frame.source == "02:00:c6:12:00:02")
        #expect(frame.destination == "ff:ff:ff:ff:ff:ff")
        #expect(frame.description == "02:00:c6:12:00:02 -> ff:ff:ff:ff:ff:ff, 42 bytes, ARP who-has 198.18.0.1 tell 198.18.0.2")
    }

    @Test
    func otherFramesAreClassifiedByEtherTypeAndProtocol() throws {
        var reply = Self.arpRequest
        reply[21] = 2
        #expect(try #require(FrameSummary.parse(reply)).kind == .arpReply(sender: "198.18.0.2"))
        let ping = Self.ipv4Frame(protocolNumber: 1, destination: [198, 18, 0, 1])
        #expect(try #require(FrameSummary.parse(ping)).kind == .ipv4(protocolNumber: 1, destination: "198.18.0.1"))
        var ipv6 = [UInt8](repeating: 0, count: 60)
        (ipv6[12], ipv6[13]) = (0x86, 0xDD)
        #expect(try #require(FrameSummary.parse(ipv6)).kind == .ipv6)
        var unknown = [UInt8](repeating: 0, count: 60)
        (unknown[12], unknown[13]) = (0x88, 0xCC)
        #expect(try #require(FrameSummary.parse(unknown)).kind == .other(etherType: 0x88CC))
    }

    @Test
    func aFrameShorterThanItsHeaderOrItsPacketIsNotAFrame() {
        #expect(FrameSummary.parse([]) == nil)
        #expect(FrameSummary.parse(Array(Self.arpRequest.prefix(13))) == nil)
        #expect(FrameSummary.parse(Array(Self.arpRequest.prefix(41))) == nil, "an ARP packet is 28 bytes after the header")
        #expect(FrameSummary.parse(Array(Self.ipv4Frame(protocolNumber: 6, destination: [1, 2, 3, 4]).prefix(33))) == nil)
    }

    @Test
    func theNetworkVerdictNeedsAnArpRequestForTheGateway() throws {
        let asked = try #require(FrameSummary.parse(Self.arpRequest))
        var elsewhere = Self.arpRequest
        elsewhere[41] = 9
        let askedElsewhere = try #require(FrameSummary.parse(elsewhere))
        let ping = try #require(FrameSummary.parse(Self.ipv4Frame(protocolNumber: 1, destination: [198, 18, 0, 1])))
        #expect(NetworkVerdict.evaluate(frames: []) == .noFrames)
        #expect(NetworkVerdict.evaluate(frames: [askedElsewhere, ping]) == .noRequestForGateway)
        #expect(NetworkVerdict.evaluate(frames: [askedElsewhere, asked]) == .passed)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFrameWrittenToTheGuestEndArrivesWholeOnTheHostEndAndStopFinishesTheStream() async throws {
        let link = try LoopbackLink()
        // Bigger than the 2 KiB a local datagram socket takes by default: the link must raise its buffers.
        let large = [UInt8](repeating: 0xAB, count: 9_000)
        try link.guestHandle.write(contentsOf: Data(Self.arpRequest))
        try link.guestHandle.write(contentsOf: Data(large))
        var received: [[UInt8]] = []
        for await frame in link.frames {
            received.append(frame)
            if received.count == 2 { link.stop() }
        }
        #expect(received == [Self.arpRequest, large])
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingTheLinkEndsTheReaderWithoutAnExplicitStop() async throws {
        var link: LoopbackLink? = try LoopbackLink()
        let frames = try #require(link?.frames)
        link = nil
        var count = 0
        for await _ in frames {
            count += 1
        }
        #expect(count == 0)
    }
}
