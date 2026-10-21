import Foundation

/// DNS record types and response codes used by the proxy.
enum DNSCode {
    static let typeA: UInt16 = 1
    static let typeCNAME: UInt16 = 5
    static let typeAAAA: UInt16 = 28
    static let classIN: UInt16 = 1
    static let noError: UInt8 = 0
    static let serverFailure: UInt8 = 2
    static let nameError: UInt8 = 3
    static let notImplemented: UInt8 = 4
    static let refused: UInt8 = 5
}

/// One resource record as the proxy passes it between resolver and guest.
struct DNSRecord: Sendable, Hashable {
    /// Owner name, lower-case, no trailing dot.
    var name: String
    var type: UInt16
    var ttl: UInt32
    /// Record data in uncompressed wire form (4 bytes for A; an encoded name for CNAME).
    var data: [UInt8]
}

/// What a resolver returns for one question.
struct DNSLookupResult: Sendable, Hashable {
    var responseCode: UInt8
    var records: [DNSRecord]

    init(responseCode: UInt8, records: [DNSRecord] = []) {
        self.responseCode = responseCode
        self.records = records
    }
}

/// A parsed question. Only single-question queries are supported (every real resolver sends one).
struct DNSQuery {
    var id: UInt16
    var flags: UInt16
    /// Lower-case, no trailing dot; empty for the root.
    var name: String
    var type: UInt16
    var queryClass: UInt16
    /// The question section exactly as the guest sent it, echoed in the response.
    var rawQuestion: [UInt8]

    var opcode: UInt8 { UInt8((flags >> 11) & 0xF) }
}

/// DNS message encoding and decoding (RFC 1035). Allocates freely: DNS is per-lookup, not per-packet.
enum DNSWire {
    private static let headerLength = 12
    private static let maximumUDPResponse = 512

    /// Parses a query message.
    /// - Throws: ``PacketError/truncated``; ``PacketError/malformed`` for a response (QR set), a question count other
    ///   than one, a compressed or over-long name.
    static func parseQuery(_ message: ByteView) throws(PacketError) -> DNSQuery {
        let flags = try message.be16(at: 2)
        guard flags & 0x8000 == 0, try message.be16(at: 4) == 1 else { throw .malformed }
        var offset = headerLength
        var labels: [String] = []
        var nameBytes = 0
        while true {
            let length = Int(try message.u8(at: offset))
            if length == 0 {
                offset += 1
                break
            }
            guard length <= 63 else { throw .malformed }  // also rejects compression pointers (0xC0...)
            guard let label = message.slice(from: offset + 1, length: length) else { throw .truncated }
            nameBytes += length + 1
            guard nameBytes <= 255 else { throw .malformed }
            // Bytes that are not UTF-8 give an empty label, which the policy check later rejects as malformed.
            labels.append((String(bytes: label.array(), encoding: .utf8) ?? "").lowercased())
            offset += 1 + length
        }
        let type = try message.be16(at: offset)
        let queryClass = try message.be16(at: offset + 2)
        guard let raw = message.slice(from: headerLength, length: offset + 4 - headerLength) else { throw .truncated }
        return DNSQuery(
            id: try message.be16(at: 0), flags: flags, name: labels.joined(separator: "."), type: type, queryClass: queryClass,
            rawQuestion: raw.array())
    }

    /// Encodes a name as length-prefixed labels; `nil` if a label is empty or over 63 bytes.
    static func encodeName(_ name: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".", omittingEmptySubsequences: false) where !(label.isEmpty && name.isEmpty) {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count <= 63 else { return nil }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        return bytes
    }

    /// Builds the response to `query`.
    ///
    /// - Parameters:
    ///   - query: The question being answered; its id, flags and question section are echoed.
    ///   - code: The response code.
    ///   - records: Answer records, in order (a CNAME chain first).
    ///   - truncateOverUDP: When the message would exceed 512 bytes, drop the answers and set TC so the guest retries
    ///     over TCP (no EDNS0 is offered, so 512 is the limit).
    /// - Returns: The complete DNS message.
    static func response(to query: DNSQuery, code: UInt8, records: [DNSRecord] = [], truncateOverUDP: Bool = false) -> [UInt8] {
        var body: [UInt8] = []
        var answers = 0
        for record in records {
            let owner = record.name == query.name ? [0xC0, 0x0C] : (encodeName(record.name) ?? [0xC0, 0x0C])
            body += owner
            body += [UInt8(record.type >> 8), UInt8(record.type & 0xFF), 0, 1]
            body += [UInt8(record.ttl >> 24), UInt8((record.ttl >> 16) & 0xFF), UInt8((record.ttl >> 8) & 0xFF), UInt8(record.ttl & 0xFF)]
            body += [UInt8(record.data.count >> 8), UInt8(record.data.count & 0xFF)]
            body += record.data
            answers += 1
        }
        let truncated = truncateOverUDP && headerLength + query.rawQuestion.count + body.count > maximumUDPResponse
        if truncated {
            body = []
            answers = 0
        }
        let flags: UInt16 =
            0x8000 | (query.flags & 0x7800) | (query.flags & 0x0100) | 0x0080 | (truncated ? 0x0200 : 0)
            | UInt16(code & 0xF)
        var message: [UInt8] = [UInt8(query.id >> 8), UInt8(query.id & 0xFF), UInt8(flags >> 8), UInt8(flags & 0xFF)]
        message += [0, 1, UInt8(answers >> 8), UInt8(answers & 0xFF), 0, 0, 0, 0]
        message += query.rawQuestion
        message += body
        return message
    }
}
