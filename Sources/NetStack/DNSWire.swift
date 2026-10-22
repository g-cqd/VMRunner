import Foundation

/// DNS record types and response codes used by the proxy.
enum DNSCode {
    static let typeA: UInt16 = 1
    static let typeCNAME: UInt16 = 5
    static let typePTR: UInt16 = 12
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
package struct DNSLookupResult: Sendable, Hashable {
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
    /// Type, class, TTL and data length of a record, after its owner name.
    private static let recordHeaderLength = 10
    private static let maximumNameLength = 255
    /// What plain UDP carries without EDNS0 (RFC 1035 section 2.3.4).
    static let maximumUDPResponse = 512
    /// What the 16-bit length prefix of DNS over TCP allows.
    static let maximumMessage = 65_535

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

    /// Encodes a name as length-prefixed labels; `nil` if a label is empty or over 63 bytes, or the encoding exceeds
    /// the 255 bytes a name may take.
    static func encodeName(_ name: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".", omittingEmptySubsequences: false) where !(label.isEmpty && name.isEmpty) {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count <= 63 else { return nil }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
            guard bytes.count < maximumNameLength else { return nil }
        }
        bytes.append(0)
        return bytes
    }

    /// The dotted, lower-case name in `data` when it is exactly one uncompressed name of printable ASCII labels (no dot
    /// or space inside a label, no control byte), at most 255 bytes encoded; `nil` for anything else. What a CNAME or
    /// PTR record may carry through to the guest: a resolver's record data is not trusted to be a name.
    static func decodeName(_ data: [UInt8]) -> String? {
        guard data.count <= maximumNameLength else { return nil }
        var labels: [String] = []
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            if length == 0 { return offset + 1 == data.count ? labels.joined(separator: ".") : nil }
            let end = offset + 1 + length
            guard length <= 63, end < data.count else { return nil }  // a terminator must follow the label
            let label = data[(offset + 1)..<end]
            guard label.allSatisfy({ (0x21...0x7E).contains($0) && $0 != 0x2E }), let text = String(bytes: label, encoding: .utf8)
            else { return nil }
            labels.append(text.lowercased())
            offset = end
        }
        return nil
    }

    /// Builds the response to `query`.
    ///
    /// One byte budget covers both routes: header, question and answers never exceed 65,535 bytes (the DNS-over-TCP
    /// length prefix is 16 bits), or 512 when `truncateOverUDP` is set. Records are appended until the next one does
    /// not fit; then TC is set and the answer count is the number actually written. A record whose owner name cannot
    /// be encoded is left out, not relabelled.
    ///
    /// - Parameters:
    ///   - query: The question being answered; its id, flags and question section are echoed.
    ///   - code: The response code.
    ///   - records: Answer records, in order (a CNAME chain first).
    ///   - truncateOverUDP: Apply the 512-byte limit of plain UDP (no EDNS0 is offered) so the guest retries over TCP.
    /// - Returns: The complete DNS message, at most 65,535 bytes.
    static func response(to query: DNSQuery, code: UInt8, records: [DNSRecord] = [], truncateOverUDP: Bool = false) -> [UInt8] {
        let limit = truncateOverUDP ? maximumUDPResponse : maximumMessage
        // `parseQuery` bounds a question to 259 bytes; one that could not fit is not echoed, so the budget never goes negative.
        let question = headerLength + query.rawQuestion.count <= limit ? query.rawQuestion : []
        var budget = limit - headerLength - question.count
        var body: [UInt8] = []
        var answers = 0
        var truncated = false
        for record in records {
            guard let owner = record.name == query.name ? [0xC0, 0x0C] : encodeName(record.name) else { continue }
            let size = owner.count + recordHeaderLength + record.data.count
            guard size <= budget else {
                truncated = true
                break
            }
            budget -= size
            body += owner
            appendBigEndian16(Int(record.type), to: &body)
            appendBigEndian16(Int(DNSCode.classIN), to: &body)
            appendBigEndian16(Int(record.ttl >> 16), to: &body)
            appendBigEndian16(Int(record.ttl & 0xFFFF), to: &body)
            appendBigEndian16(record.data.count, to: &body)  // at most `budget`, so below 65,536
            body += record.data
            answers += 1  // at most 65,535 / 12, so it fits the 16-bit count
        }
        let flags: UInt16 =
            0x8000 | (query.flags & 0x7800) | (query.flags & 0x0100) | 0x0080 | (truncated ? 0x0200 : 0)
            | UInt16(code & 0xF)
        var message: [UInt8] = []
        message.reserveCapacity(headerLength + question.count + body.count)
        appendBigEndian16(Int(query.id), to: &message)
        appendBigEndian16(Int(flags), to: &message)
        appendBigEndian16(question.isEmpty ? 0 : 1, to: &message)
        appendBigEndian16(answers, to: &message)
        message += [0, 0, 0, 0]
        message += question
        message += body
        return message
    }

    /// Appends the low 16 bits of `value`, high byte first. Masking instead of narrowing: it cannot trap.
    private static func appendBigEndian16(_ value: Int, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
}
