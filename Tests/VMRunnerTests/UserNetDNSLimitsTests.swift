import Foundation
import Testing

@testable import VMRunner

/// An independent reader of a DNS response. It walks every section by RFC 1035's rules and gives up (`nil`) unless
/// the counts in the header describe the bytes exactly, so a miscounted or overrun message fails to parse.
struct DNSResponseReader {
    let flags: Int
    let answerCount: Int
    let answers: [(type: Int, dataLength: Int)]

    var isTruncated: Bool { flags & 0x0200 != 0 }

    init?(_ bytes: [UInt8]) {
        func word(_ at: Int) -> Int? { at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func skipName(_ start: Int) -> Int? {
            var at = start
            while at < bytes.count {
                let length = Int(bytes[at])
                if length == 0 { return at + 1 }
                if length & 0xC0 == 0xC0 { return at + 2 <= bytes.count ? at + 2 : nil }
                guard length <= 63 else { return nil }
                at += 1 + length
            }
            return nil
        }
        guard let flags = word(2), let questions = word(4), let answerCount = word(6), word(8) == 0, word(10) == 0 else { return nil }
        var offset = 12
        for _ in 0..<questions {
            guard let end = skipName(offset), end + 4 <= bytes.count else { return nil }
            offset = end + 4
        }
        var answers: [(type: Int, dataLength: Int)] = []
        for _ in 0..<answerCount {
            guard let end = skipName(offset), let type = word(end), let length = word(end + 8), end + 10 + length <= bytes.count
            else { return nil }
            answers.append((type, length))
            offset = end + 10 + length
        }
        guard offset == bytes.count else { return nil }
        self.flags = flags
        self.answerCount = answerCount
        self.answers = answers
    }
}

private func records(count: Int, dataLength: Int, type: UInt16 = 1) -> [DNSRecord] {
    let data = [UInt8](repeating: 7, count: dataLength)
    return [DNSRecord](repeating: DNSRecord(name: "host.test", type: type, ttl: 60, data: data), count: count)
}

private func parsedQuery(_ name: String = "host.test") throws -> DNSQuery {
    try ByteView.withBytes(of: Wire.dnsQuery(id: 0x5150, name: name)) { view throws(PacketError) in try DNSWire.parseQuery(view) }
}

/// Large answers a hostile resolver (or a hostile name server behind it) can produce, as PTR records whose data is a
/// well-formed name of that many bytes (the root name, or the longest name there is): the proxy passes those on.
private let oversizedAnswers: [(count: Int, dataLength: Int)] = [(300, 255), (70_000, 1)]

private let reverseName = "4.3.2.1.in-addr.arpa"

/// A well-formed encoded name of exactly 1 byte (the root) or 255 bytes (three 63-byte labels and one of 61).
private func nameData(length: Int) -> [UInt8] {
    length == 1
        ? [0] : (0..<3).flatMap { _ in [63] + [UInt8](repeating: 0x61, count: 63) } + [61] + [UInt8](repeating: 0x62, count: 61) + [0]
}

private func pointerRecords(count: Int, dataLength: Int) -> [DNSRecord] {
    [DNSRecord](
        repeating: DNSRecord(name: reverseName, type: DNSCode.typePTR, ttl: 60, data: nameData(length: dataLength)), count: count)
}

struct UserNetDNSLimitsTests {
    private func start() -> CoreRig {
        let rig = CoreRig()
        rig.learnGuest()
        return rig
    }

    @Test(arguments: oversizedAnswers)
    func anOversizedAnswerOverTCPIsAWellFormedTruncatedMessage(shape: (count: Int, dataLength: Int)) throws {
        let rig = start()
        var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53))
        guest.sendSYN()
        guest.sendACK()
        let query = Wire.dnsQuery(id: 0x5150, name: reverseName, type: 12)
        guest.sendData(Wire.be16(query.count) + query)
        let request = try #require(rig.host.resolutions.first)
        rig.core.nameResolved(
            token: request.token,
            result: DNSLookupResult(responseCode: 0, records: pointerRecords(count: shape.count, dataLength: shape.dataLength)))
        guest.collect()
        var rounds = 0
        while guest.received.count < 2 || guest.received.count < 2 + (Int(guest.received[0]) << 8 | Int(guest.received[1])), rounds < 400 {
            guest.sendACK()
            rounds += 1
        }
        let length = Int(guest.received[0]) << 8 | Int(guest.received[1])
        let message = Array(guest.received.dropFirst(2))
        #expect(message.count == length && length <= 65_535)
        let reader = try #require(DNSResponseReader(message), "the message must be well formed")
        #expect(reader.isTruncated)
        #expect(reader.answerCount == reader.answers.count && reader.answerCount < shape.count)
        #expect(length > 60_000, "the budget is used, not a fixed small cut-off")
    }

    @Test(arguments: oversizedAnswers)
    func anOversizedAnswerOverUDPIsAWellFormedTruncatedMessage(shape: (count: Int, dataLength: Int)) throws {
        let rig = start()
        rig.send(Wire.guestUDP(to: (Wire.gateway, 53), from: 41_000, Wire.dnsQuery(id: 0x5150, name: reverseName, type: 12)))
        let request = try #require(rig.host.resolutions.first)
        rig.core.nameResolved(
            token: request.token,
            result: DNSLookupResult(responseCode: 0, records: pointerRecords(count: shape.count, dataLength: shape.dataLength)))
        let response = try #require(rig.host.takeFrames().first)
        #expect(response.payload.count <= 512)
        let reader = try #require(DNSResponseReader(response.payload), "the message must be well formed")
        #expect(reader.isTruncated && reader.answerCount < shape.count)
    }

    @Test func theBudgetIsExactForBothRoutes() throws {
        let query = try parsedQuery()
        let fixed = 12 + query.rawQuestion.count
        for (limit, truncate) in [(512, true), (65_535, false)] {
            let message = DNSWire.response(to: query, code: 0, records: records(count: 100_000, dataLength: 4), truncateOverUDP: truncate)
            let reader = try #require(DNSResponseReader(message))
            #expect(reader.isTruncated)
            #expect(message.count <= limit && message.count + 16 > limit, "the next 16-byte record did not fit")
            #expect(reader.answerCount == (message.count - fixed) / 16)
        }
    }

    @Test func aSmallAnswerIsNotTruncated() throws {
        let message = DNSWire.response(to: try parsedQuery(), code: 0, records: records(count: 3, dataLength: 4), truncateOverUDP: true)
        let reader = try #require(DNSResponseReader(message))
        #expect(!reader.isTruncated && reader.answerCount == 3)
    }

    @Test func aRecordWithAnUnencodableOwnerIsLeftOutNotRelabelled() throws {
        let query = try parsedQuery()
        let overlong = DNSRecord(name: String(repeating: "a", count: 64) + ".test", type: 1, ttl: 60, data: [1, 2, 3, 4])
        let longName = (0..<10).map { _ in String(repeating: "b", count: 30) }.joined(separator: ".")
        let tooLong = DNSRecord(name: longName, type: 1, ttl: 60, data: [1, 2, 3, 4])
        let good = DNSRecord(name: "host.test", type: 1, ttl: 60, data: [5, 6, 7, 8])
        let message = DNSWire.response(to: query, code: 0, records: [overlong, tooLong, good])
        let reader = try #require(DNSResponseReader(message))
        #expect(reader.answerCount == 1 && !reader.isTruncated)
        #expect(Array(message.suffix(4)) == [5, 6, 7, 8])
    }
}

struct DNSCollectorTests {
    typealias Collector = DNSServiceQuery.Collector

    @Test func theCollectorStopsAtItsRecordBudget() {
        let collector = Collector()
        for _ in 0..<1_000 where collector.hasRoom(forDataOf: 4) { collector.append(records(count: 1, dataLength: 4)[0]) }
        #expect(collector.records.count == Collector.maximumRecords)
    }

    @Test func theCollectorStopsAtItsByteBudget() {
        let collector = Collector()
        for _ in 0..<1_000 where collector.hasRoom(forDataOf: 1_000) { collector.append(records(count: 1, dataLength: 1_000)[0]) }
        #expect(collector.dataBytes <= Collector.maximumDataBytes && collector.dataBytes > Collector.maximumDataBytes - 1_000)
        #expect(!Collector().hasRoom(forDataOf: Collector.maximumDataBytes + 1))
    }
}

/// Seeded: a failure names its seed and iteration, so it reproduces.
struct UserNetDNSFuzzTests {
    private static let seed: UInt64 = 0xD15_C0DE_5EED

    private static let ownerNames: [String] = [
        "host.test", "", ".", "a", "other.example", String(repeating: "a", count: 63) + ".test",
        String(repeating: "a", count: 64) + ".test", (0..<9).map { _ in String(repeating: "c", count: 40) }.joined(separator: "."),
        "caf\u{E9}.test", "a..b", "host.test.",
    ]

    /// Well-formed record data for a PTR answer: the root, a short name and the longest name.
    private static let validNames = [nameData(length: 1), DNSWire.encodeName("a.test") ?? [], nameData(length: 255)]

    /// A result of random shape. Given `question`, three records in four answer it (owner, type and well-formed data), so
    /// that the proxy has something to pass on and the big messages are really built.
    private static func randomResult(_ random: inout XorShift, answering question: (name: String, type: UInt16)? = nil)
        -> DNSLookupResult
    {
        let counts = [0, 1, 2, 5, 40, 300, 1_000, 5_000, 70_000]
        let sizes = [0, 1, 4, 16, 255, 256, 1_000, 40_000, 65_535, 70_000]
        let count = counts[random.below(counts.count)]
        // Keep one result under a few megabytes: the point is the shape, not the allocation.
        let size = min(sizes[random.below(sizes.count)], 4_000_000 / max(count, 1))
        var recordList: [DNSRecord] = []
        recordList.reserveCapacity(count)
        let shared = [UInt8](repeating: UInt8(truncatingIfNeeded: random.next()), count: size)
        for _ in 0..<count {
            let length = random.below(4) == 0 ? random.below(size + 1) : size
            let ttl = UInt32(truncatingIfNeeded: random.next())
            if let question, random.below(4) != 0 {
                recordList.append(DNSRecord(name: question.name, type: question.type, ttl: ttl, data: validNames[random.below(3)]))
            } else {
                recordList.append(
                    DNSRecord(
                        name: ownerNames[random.below(ownerNames.count)], type: UInt16(truncatingIfNeeded: random.next()), ttl: ttl,
                        data: length == size ? shared : Array(shared.prefix(length))))
            }
        }
        let code = UInt8(truncatingIfNeeded: random.next())
        return DNSLookupResult(responseCode: question != nil && random.below(4) != 0 ? DNSCode.noError : code, records: recordList)
    }

    @Test func anyResolverResultYieldsAWellFormedMessageWithinTheLimit() throws {
        var random = XorShift(state: Self.seed)
        let query = try parsedQuery()
        for iteration in 0..<120 {
            let result = Self.randomResult(&random)
            for (limit, truncate) in [(512, true), (65_535, false)] {
                let message = DNSWire.response(to: query, code: result.responseCode, records: result.records, truncateOverUDP: truncate)
                #expect(message.count <= limit, "seed \(Self.seed) iteration \(iteration)")
                #expect(DNSResponseReader(message) != nil, "seed \(Self.seed) iteration \(iteration): not well formed")
                #expect(message[3] & 0x0F == result.responseCode & 0x0F)
            }
        }
    }

    @Test func anyResolverResultIsDeliveredOverUDPAndTCPWithoutTrapping() throws {
        var random = XorShift(state: Self.seed &+ 1)
        let rig = CoreRig()
        rig.learnGuest()
        var guest = GuestConnection(rig: rig, to: (Wire.gateway, 53))
        guest.sendSYN()
        guest.sendACK()
        for iteration in 0..<24 {
            let result = Self.randomResult(&random, answering: (reverseName, DNSCode.typePTR))
            rig.send(Wire.guestUDP(to: (Wire.gateway, 53), from: 41_000, Wire.dnsQuery(id: 1, name: reverseName, type: 12)))
            let udp = try #require(rig.host.resolutions.last)
            rig.core.nameResolved(token: udp.token, result: result)
            let frame = try #require(rig.host.takeFrames().first { $0.proto == IPProtocol.udp })
            #expect(frame.payload.count <= 512 && DNSResponseReader(frame.payload) != nil, "seed \(Self.seed &+ 1) iteration \(iteration)")

            let query = Wire.dnsQuery(id: 2, name: reverseName, type: 12)
            let before = guest.received.count
            guest.sendData(Wire.be16(query.count) + query)
            let tcp = try #require(rig.host.resolutions.last)
            rig.core.nameResolved(token: tcp.token, result: result)
            guest.collect()
            var rounds = 0
            func isComplete() -> Bool {
                guard guest.received.count >= before + 2 else { return false }
                let length = Int(guest.received[before]) << 8 | Int(guest.received[before + 1])
                return guest.received.count >= before + 2 + length
            }
            while !isComplete(), rounds < 400 {
                guest.sendACK()
                rounds += 1
            }
            let message = Array(guest.received.dropFirst(before + 2))
            #expect(message.count <= 65_535 && DNSResponseReader(message) != nil, "seed \(Self.seed &+ 1) iteration \(iteration)")
        }
    }
}
