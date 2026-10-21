import Foundation
import Testing

@testable import VMRunner

struct UserNetWireTests {
    @Test(arguments: [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 20, 63, 64, 1_459, 1_460, 1_499, 4_001])
    func checksumMatchesTheReference(length: Int) {
        let bytes = pattern(length, seed: length)
        let production = ByteView.withBytes(of: bytes) { InternetChecksum.checksum($0) }
        #expect(production == Wire.checksum(bytes))
    }

    @Test func checksumOfAHeaderIncludingItsChecksumIsZero() {
        let packet = Wire.ipv4(from: Wire.guest, to: ipv4("93.184.216.34"), proto: IPProtocol.tcp, [1, 2, 3])
        #expect(ByteView.withBytes(of: Array(packet[..<20])) { InternetChecksum.checksum($0) } == 0)
    }

    @Test func ethernetHeaderParses() throws {
        let frame = Wire.ethernet(to: Wire.gatewayMAC, from: Wire.guestMAC, type: EtherType.ipv4, [9, 8, 7])
        try ByteView.withBytes(of: frame) { view throws(PacketError) in
            let header = try EthernetHeader(parsing: view)
            #expect(header.destination == Wire.gatewayMAC)
            #expect(header.source == Wire.guestMAC)
            #expect(header.etherType == EtherType.ipv4)
            #expect(header.payload.array() == [9, 8, 7])
        }
        ByteView.withBytes(of: [1, 2, 3]) { view in
            #expect(throws: PacketError.truncated) { try EthernetHeader(parsing: view) }
        }
    }

    @Test func ipv4RoundTripAndPaddingIsRemoved() throws {
        let payload = pattern(30)
        let packet = Wire.ipv4(from: ipv4("10.1.2.3"), to: ipv4("8.8.4.4"), proto: IPProtocol.udp, payload, identification: 77)
        try ByteView.withBytes(of: packet + [0, 0, 0, 0, 0, 0]) { view throws(PacketError) in
            let header = try IPv4Header(parsing: view)
            #expect(header.source == ipv4("10.1.2.3"))
            #expect(header.destination == ipv4("8.8.4.4"))
            #expect(header.proto == IPProtocol.udp)
            #expect(header.identification == 77)
            #expect(header.dontFragment && !header.isFragment)
            #expect(header.payload.array() == payload)
        }
    }

    @Test func ipv4RejectsBrokenHeaders() {
        let good = Wire.ipv4(from: Wire.guest, to: ipv4("1.1.1.1"), proto: 17, pattern(12))
        func parse(_ bytes: [UInt8]) -> PacketError? {
            ByteView.withBytes(of: bytes) { (view: ByteView) -> PacketError? in
                do throws(PacketError) {
                    _ = try IPv4Header(parsing: view)
                    return nil
                } catch { return error }
            }
        }
        var badVersion = good
        badVersion[0] = 0x65
        var shortHeader = good
        shortHeader[0] = 0x44
        var lyingLength = good
        lyingLength[3] = 200
        var flipped = good
        flipped[15] ^= 0xFF
        #expect(parse(good) == nil)
        #expect(parse(badVersion) == .unsupported)
        #expect(parse(shortHeader) == .malformed)
        #expect(parse(lyingLength) == .truncated)
        #expect(parse(flipped) == .checksum)
        #expect(parse(Array(good.prefix(10))) == .truncated)
    }

    @Test func fragmentsAreFlagged() throws {
        for field in [0x2000, 0x0001, 0x20FF] {
            let packet = Wire.ipv4(from: Wire.guest, to: ipv4("1.1.1.1"), proto: 17, pattern(8), fragmentField: field)
            try ByteView.withBytes(of: packet) { view throws(PacketError) in #expect(try IPv4Header(parsing: view).isFragment) }
        }
    }

    @Test func tcpHeaderParsesOptionsAndChecksum() throws {
        let source = (Wire.guest, UInt16(40_000))
        let destination = (ipv4("93.184.216.34"), UInt16(443))
        let segment = Wire.tcp(
            from: source, to: destination, sequence: 0xFFFF_FFF0, acknowledgement: 5, flags: [.syn, .ack], window: 1_000, mss: 1_400,
            windowScale: 9, payload: [1, 2, 3])
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: source.0, destination: destination.0, proto: IPProtocol.tcp, length: segment.count)
        try ByteView.withBytes(of: segment) { view throws(PacketError) in
            let header = try TCPHeader(parsing: view, verifyingWith: pseudo)
            #expect(header.sourcePort == 40_000 && header.destinationPort == 443)
            #expect(header.sequence == 0xFFFF_FFF0 && header.acknowledgement == 5)
            #expect(header.flags == [.syn, .ack])
            #expect(header.window == 1_000)
            #expect(header.mss == 1_400 && header.windowScale == 9)
            #expect(header.payload.array() == [1, 2, 3])
            #expect(header.sequenceLength == 4)
        }
        var corrupted = segment
        corrupted[corrupted.count - 1] ^= 1
        ByteView.withBytes(of: corrupted) { view in
            #expect(throws: PacketError.checksum) { try TCPHeader(parsing: view, verifyingWith: pseudo) }
        }
    }

    @Test func tcpHeaderRejectsBadOptions() {
        var segment = Wire.tcp(from: (1, 1), to: (2, 2), sequence: 0, flags: .syn, mss: 1_460)
        segment[21] = 0  // option length 0 would loop forever in a naive parser
        ByteView.withBytes(of: segment) { view in #expect(throws: PacketError.malformed) { try TCPHeader(parsing: view) } }
        var shortOffset = Wire.tcp(from: (1, 1), to: (2, 2), sequence: 0, flags: .syn)
        shortOffset[12] = 0x40
        ByteView.withBytes(of: shortOffset) { view in #expect(throws: PacketError.malformed) { try TCPHeader(parsing: view) } }
    }

    @Test func windowScaleIsClampedToFourteen() throws {
        let segment = Wire.tcp(from: (1, 1), to: (2, 2), sequence: 0, flags: .syn, windowScale: 30)
        try ByteView.withBytes(of: segment) { view throws(PacketError) in #expect(try TCPHeader(parsing: view).windowScale == 14) }
    }

    @Test func udpHeaderParsesAndZeroChecksumPasses() throws {
        let datagram = Wire.udp(from: (Wire.guest, 5_000), to: (ipv4("9.9.9.9"), 53), [1, 2, 3, 4, 5])
        let pseudo = InternetChecksum.pseudoHeaderSum(
            source: Wire.guest, destination: ipv4("9.9.9.9"), proto: IPProtocol.udp, length: datagram.count)
        try ByteView.withBytes(of: datagram) { view throws(PacketError) in
            let header = try UDPHeader(parsing: view, verifyingWith: pseudo)
            #expect(header.payload.array() == [1, 2, 3, 4, 5])
        }
        var unchecked = datagram
        unchecked[6] = 0
        unchecked[7] = 0
        unchecked[8] ^= 0xFF
        try ByteView.withBytes(of: unchecked) { view throws(PacketError) in
            #expect(try UDPHeader(parsing: view, verifyingWith: pseudo).payload.count == 5)
        }
        var lying = datagram
        lying[5] = 200
        ByteView.withBytes(of: lying) { view in #expect(throws: PacketError.malformed) { try UDPHeader(parsing: view) } }
    }

    @Test func icmpEchoParses() throws {
        let message = Wire.icmpEcho(identifier: 0x1234, sequence: 9, data: [7, 7])
        try ByteView.withBytes(of: message) { view throws(PacketError) in
            let echo = try ICMPHeader(parsing: view)
            #expect(echo.type == 8 && echo.identifier == 0x1234 && echo.sequence == 9)
            #expect(echo.payload.array() == [7, 7])
        }
    }

    @Test func arpParsesAndOnlyEthernetIPv4IsAccepted() throws {
        let frame = Wire.arpRequest(senderMAC: Wire.guestMAC, senderIP: Wire.guest, targetIP: Wire.gateway)
        try ByteView.withBytes(of: Array(frame[14...])) { view throws(PacketError) in
            let arp = try ARPPacket(parsing: view)
            #expect(arp.operation == ARPPacket.request)
            #expect(arp.senderIP == Wire.guest && arp.targetIP == Wire.gateway)
            #expect(arp.senderMAC == Wire.guestMAC)
        }
        var other = Array(frame[14...])
        other[1] = 6  // hardware type 6 (IEEE 802)
        ByteView.withBytes(of: other) { view in #expect(throws: PacketError.unsupported) { try ARPPacket(parsing: view) } }
    }

    @Test func viewBoundsAreEnforced() {
        ByteView.withBytes(of: [1, 2, 3, 4]) { view in
            #expect(view.slice(from: 2, length: 2)?.array() == [3, 4])
            #expect(view.slice(from: 3, length: 2) == nil)
            #expect(view.slice(from: -1, length: 1) == nil)
            #expect(view.suffix(from: 5) == nil)
            #expect(view[4] == nil)
            #expect(throws: PacketError.truncated) { try view.be32(at: 1) }
            #expect(view.prefix(100).count == 4)
        }
    }

    @Test func ringKeepsOrderAcrossWraparound() {
        let ring = ByteRing(capacity: 8)
        #expect(ByteView.withBytes(of: [1, 2, 3, 4, 5, 6]) { ring.append($0) })
        ring.discard(4)
        #expect(ByteView.withBytes(of: [7, 8, 9, 10, 11, 12]) { ring.append($0) })
        #expect(ring.count == 8 && ring.freeSpace == 0)
        #expect(!ByteView.withBytes(of: [0]) { ring.append($0) })
        let first = ring.contiguous(from: 0, limit: 8)
        let second = ring.contiguous(from: first.count, limit: 8 - first.count)
        #expect(first.array() + second.array() == [5, 6, 7, 8, 9, 10, 11, 12])
        ring.discard(8)
        #expect(ring.isEmpty)
    }

    @Test func dnsQueryParsingRejectsCompressionAndResponses() throws {
        let query = Wire.dnsQuery(id: 7, name: "Example.COM", type: 1)
        try ByteView.withBytes(of: query) { view throws(PacketError) in
            let parsed = try DNSWire.parseQuery(view)
            #expect(parsed.name == "example.com" && parsed.id == 7 && parsed.type == 1)
        }
        var response = query
        response[2] |= 0x80
        ByteView.withBytes(of: response) { view in #expect(throws: PacketError.malformed) { try DNSWire.parseQuery(view) } }
        var pointer = query
        pointer[12] = 0xC0
        ByteView.withBytes(of: pointer) { view in #expect(throws: PacketError.malformed) { try DNSWire.parseQuery(view) } }
    }

    @Test func dnsResponseEchoesTheQuestionAndCompressesTheOwner() throws {
        let query = Wire.dnsQuery(id: 0x4242, name: "a.test")
        let parsed = try ByteView.withBytes(of: query) { view throws(PacketError) in try DNSWire.parseQuery(view) }
        let answer = DNSRecord(name: "a.test", type: 1, ttl: 60, data: [10, 0, 0, 1])
        let response = DNSWire.response(to: parsed, code: 0, records: [answer])
        #expect(Array(response[0..<2]) == [0x42, 0x42])
        #expect(response[2] & 0x80 != 0 && response[3] & 0x0F == 0)
        #expect(Array(response[12..<(12 + parsed.rawQuestion.count)]) == parsed.rawQuestion)
        #expect(Array(response.suffix(16).prefix(2)) == [0xC0, 0x0C])
        #expect(Array(response.suffix(4)) == [10, 0, 0, 1])
    }

    @Test func oversizedUDPAnswersAreTruncated() throws {
        let query = Wire.dnsQuery(id: 1, name: "big.test", type: 16)
        let parsed = try ByteView.withBytes(of: query) { view throws(PacketError) in try DNSWire.parseQuery(view) }
        let records = (0..<10).map { _ in DNSRecord(name: "big.test", type: 16, ttl: 1, data: [UInt8](repeating: 65, count: 100)) }
        let response = DNSWire.response(to: parsed, code: 0, records: records, truncateOverUDP: true)
        #expect(response[2] & 0x02 != 0)  // TC
        // The records that fit are kept and counted (12 + 14 + 4 x 112 = 474; a fifth would pass 512), not all dropped.
        #expect(response[6] == 0 && response[7] == 4)
        #expect(response.count == 474)
        #expect(DNSWire.response(to: parsed, code: 0, records: records).count > 1_000)
    }
}
