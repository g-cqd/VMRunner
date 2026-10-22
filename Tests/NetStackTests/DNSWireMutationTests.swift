import Foundation
import Testing

@testable import NetStack

/// Seeded mutation of the DNS messages a guest sends and the record data a resolver returns (roadmap 0034, item 6). Every
/// property holds for every mutant; a failure names its index, and the seed reproduces it.
struct DNSWireMutationTests {
    private static let seed: UInt64 = 0xD45_F022_5EED

    private static let queries: [[UInt8]] = [
        Wire.dnsQuery(id: 1, name: "example.com"),
        Wire.dnsQuery(id: 2, name: "a.b.c.d.e.example.test", type: 28),
        Wire.dnsQuery(id: 3, name: "4.3.2.1.in-addr.arpa", type: 12),
        Wire.dnsQuery(id: 4, name: String(repeating: "x", count: 63) + ".test", type: 5),
    ]

    /// `bytes` with one to three edits: bit flips, new bytes, removals, insertions, truncation, and the bytes DNS gives a meaning
    /// to (the root label, the longest label, the compression marks).
    private static func mutate(_ bytes: [UInt8], _ random: inout XorShift) -> [UInt8] {
        var result = bytes
        for _ in 0...random.below(3) {
            guard !result.isEmpty else { return [UInt8(truncatingIfNeeded: random.next())] }
            let position = random.below(result.count)
            switch random.below(6) {
            case 0: result[position] ^= UInt8(1 << random.below(8))
            case 1: result[position] = UInt8(truncatingIfNeeded: random.next())
            case 2: result.remove(at: position)
            case 3: result.insert(UInt8(truncatingIfNeeded: random.next()), at: position)
            case 4: result.removeSubrange(position...)
            default: result[position] = [0x00, 0x3F, 0x40, 0xC0, 0xFF][random.below(5)]
            }
        }
        return result
    }

    @Test func aMutatedQueryEitherFailsToParseOrGetsAWellFormedResponseWithinItsRouteLimit() {
        var random = XorShift(state: Self.seed)
        var parsed = 0
        for index in 0..<20_000 {
            let message = Self.mutate(Self.queries[random.below(Self.queries.count)], &random)
            guard let query = try? ByteView.withBytes(of: message, { view throws(PacketError) in try DNSWire.parseQuery(view) }) else {
                continue
            }
            parsed += 1
            let record = DNSRecord(name: query.name, type: DNSCode.typeA, ttl: 60, data: [192, 0, 2, 1])
            let overUDP = DNSWire.response(to: query, code: DNSCode.noError, records: [record], truncateOverUDP: true)
            let overTCP = DNSWire.response(to: query, code: DNSCode.noError, records: [record])
            #expect(overUDP.count <= DNSWire.maximumUDPResponse, "index \(index)")
            #expect(overTCP.count <= DNSWire.maximumMessage, "index \(index)")
            #expect(Array(overUDP.prefix(2)) == Array(message.prefix(2)), "index \(index): the id is echoed")
            #expect(overUDP[2] & 0x80 != 0, "index \(index): it is a response")
        }
        #expect(parsed > 500, "enough mutants still parse for the properties to mean something")
    }

    @Test func recordDataIsANameOnlyWhenItRoundTrips() throws {
        var random = XorShift(state: Self.seed ^ 0xFFFF)
        let names = ["example.com", "a.b", "", String(repeating: "x", count: 63) + ".test"]
        let encoded = try names.map { try #require(DNSWire.encodeName($0)) }
        var accepted = 0
        for index in 0..<20_000 {
            let data =
                index.isMultiple(of: 4)
                ? (0..<random.below(300)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
                : Self.mutate(encoded[random.below(encoded.count)], &random)
            guard let name = DNSWire.decodeName(data) else { continue }
            accepted += 1
            let again = DNSWire.encodeName(name)
            #expect(again?.count == data.count, "index \(index): the name takes the bytes it came from")
            #expect(again.flatMap(DNSWire.decodeName) == name, "index \(index): it decodes to itself")
        }
        #expect(accepted > 500, "\(accepted) mutants were still names: enough for the round trip to mean something")
    }
}
