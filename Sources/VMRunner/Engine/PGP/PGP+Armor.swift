import Foundation

extension PGP {
    /// A cleartext-signed message taken apart: what was signed and the binary signature that follows it.
    struct ClearSigned: Equatable, Sendable {
        /// The algorithms the `Hash:` header names.
        var hashNames: Set<String>
        /// The signed text as people read it: dash escapes undone, trailing blanks cut, lines joined by `\n`, and no
        /// line break after the last line.
        var text: [UInt8]
        /// The signed text as the signature covers it: the same lines joined by `\r\n`.
        var canonicalText: [UInt8]
        /// The packets decoded from the armored signature.
        var signature: [UInt8]
    }

    /// The ASCII armor around signatures (RFC 4880 section 6), read strictly: one block, no stray text, exact framing.
    enum Armor {
        private static let signatureLabel = "SIGNATURE"
        private static let messageLabel = "SIGNED MESSAGE"

        /// The packets inside an armored detached signature. The input is nothing but that one block (blank lines may
        /// surround it).
        static func decodeSignature(_ armored: [UInt8]) throws(Failure) -> [UInt8] {
            let lines = try splitLines(armored)
            var index = skipBlank(lines, from: 0)
            let payload = try block(labelled: signatureLabel, in: lines, at: &index)
            guard skipBlank(lines, from: index) == lines.count else { throw .malformedArmor("text after the signature") }
            return payload
        }

        /// Splits a cleartext-signed message into its text and signature.
        static func decodeClearSigned(_ document: [UInt8]) throws(Failure) -> ClearSigned {
            let lines = try splitLines(document)
            var index = skipBlank(lines, from: 0)
            guard index < lines.count, isBoundary("BEGIN PGP \(messageLabel)", lines[index]) else {
                throw .malformedArmor("no cleartext signature header")
            }
            index += 1
            var hashNames: Set<String> = []
            while index < lines.count, !trimmed(lines[index]).isEmpty {
                guard let names = headerValue(lines[index], named: "Hash") else { throw .malformedArmor("unknown header in the message") }
                hashNames.formUnion(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                index += 1
            }
            guard !hashNames.isEmpty, index < lines.count else { throw .malformedArmor("no Hash header") }
            index += 1

            var text: [[UInt8]] = []
            while index < lines.count, !isBoundary("BEGIN PGP \(signatureLabel)", lines[index]) {
                text.append(trimmedTrailingBlanks(try unescaped(lines[index])))
                index += 1
            }
            let signature = try block(labelled: signatureLabel, in: lines, at: &index)
            guard skipBlank(lines, from: index) == lines.count else { throw .malformedArmor("text after the signature") }
            return ClearSigned(
                hashNames: hashNames, text: Array(text.joined(separator: [UInt8(ascii: "\n")])),
                canonicalText: Array(text.joined(separator: [UInt8(ascii: "\r"), UInt8(ascii: "\n")])), signature: signature)
        }

        // MARK: Lines

        /// The lines of `bytes` without their `\n` or `\r\n`. A carriage return anywhere else is refused: a reader and a signer that
        /// disagree about it would sign and verify different text.
        private static func splitLines(_ bytes: [UInt8]) throws(Failure) -> [[UInt8]] {
            var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Array($0) }
            if lines.last?.isEmpty == true { lines.removeLast() }
            for index in lines.indices {
                if lines[index].last == UInt8(ascii: "\r") { lines[index].removeLast() }
                guard !lines[index].contains(UInt8(ascii: "\r")) else { throw .malformedArmor("a stray carriage return") }
            }
            return lines
        }

        private static func isBlank(_ byte: UInt8) -> Bool { byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }

        private static func trimmedTrailingBlanks(_ line: [UInt8]) -> [UInt8] {
            var end = line.count
            while end > 0, isBlank(line[end - 1]) { end -= 1 }
            return Array(line[..<end])
        }

        private static func trimmed(_ line: [UInt8]) -> [UInt8] {
            Array(trimmedTrailingBlanks(line).drop { isBlank($0) })
        }

        private static func skipBlank(_ lines: [[UInt8]], from start: Int) -> Int {
            var index = start
            while index < lines.count, trimmed(lines[index]).isEmpty { index += 1 }
            return index
        }

        /// Whether `line` is `-----<label>-----`, ignoring trailing blanks.
        private static func isBoundary(_ label: String, _ line: [UInt8]) -> Bool {
            trimmedTrailingBlanks(line) == Array("-----\(label)-----".utf8)
        }

        /// The value of an armor header line `name: value`, or nil for any other line.
        private static func headerValue(_ line: [UInt8], named name: String) -> String? {
            guard let text = String(bytes: trimmedTrailingBlanks(line), encoding: .utf8), text.hasPrefix("\(name): ") else { return nil }
            return String(text.dropFirst(name.count + 2))
        }

        /// Undoes dash escaping: `- ` at the start of a line stands for `-`. Any other line starting with a dash would
        /// be a boundary line the signer should have escaped, so it is refused.
        private static func unescaped(_ line: [UInt8]) throws(Failure) -> [UInt8] {
            guard line.first == UInt8(ascii: "-") else { return line }
            guard line.count >= 2, line[1] == UInt8(ascii: " ") else { throw .malformedArmor("an unescaped line starting with a dash") }
            return Array(line.dropFirst(2))
        }

        // MARK: Blocks

        /// The bytes of the armor block labelled `PGP <label>` that starts at `index`; `index` moves past its end line.
        private static func block(labelled label: String, in lines: [[UInt8]], at index: inout Int) throws(Failure) -> [UInt8] {
            guard index < lines.count, isBoundary("BEGIN PGP \(label)", lines[index]) else {
                throw .malformedArmor("no \(label.lowercased()) block")
            }
            index += 1
            // Armor headers (`Version: ...`) end at a blank line; a block without any has the blank line only.
            while index < lines.count, !trimmed(lines[index]).isEmpty {
                guard lines[index].contains(UInt8(ascii: ":")) else { throw .malformedArmor("a line that is not an armor header") }
                index += 1
            }
            index += 1

            var encoded: [UInt8] = []
            var crc: UInt32?
            while index < lines.count, !isBoundary("END PGP \(label)", lines[index]) {
                let line = trimmedTrailingBlanks(lines[index])
                index += 1
                if line.first == UInt8(ascii: "=") {
                    guard crc == nil, let decoded = Base64.decode(Array(line.dropFirst())), decoded.count == 3 else {
                        throw .malformedArmor("a bad checksum line")
                    }
                    crc = UInt32(decoded[0]) << 16 | UInt32(decoded[1]) << 8 | UInt32(decoded[2])
                } else {
                    guard crc == nil else { throw .malformedArmor("data after the checksum line") }
                    encoded += line
                }
            }
            guard index < lines.count else { throw .malformedArmor("the block has no end line") }
            index += 1
            guard let payload = Base64.decode(encoded), !payload.isEmpty else { throw .malformedArmor("the data is not base64") }
            if let crc, crc != crc24(payload) { throw .armorChecksum }
            return payload
        }

        /// The CRC-24 of RFC 4880 section 6.1, a byte at a time through `crc24Table`.
        static func crc24(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xB7_04CE
            for byte in bytes {
                crc = ((crc << 8) & 0xFF_FFFF) ^ crc24Table[Int(((crc >> 16) ^ UInt32(byte)) & 0xFF)]
            }
            return crc
        }

        /// Entry `i` is what eight steps of the bitwise CRC-24 leave of the byte `i` in the top byte of the register.
        private static let crc24Table: [UInt32] = (0..<256).map { index in
            var crc = UInt32(index) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x100_0000 != 0 { crc ^= 0x186_4CFB }
            }
            return crc & 0xFF_FFFF
        }
    }

    /// Canonical base64 (RFC 4648 section 4): the standard alphabet, padding where needed, nothing else.
    enum Base64 {
        /// The bytes `text` encodes, or nil if it has a character outside the alphabet, misplaced or missing padding, or
        /// leftover bits that are not zero.
        static func decode(_ text: [UInt8]) -> [UInt8]? {
            guard text.count.isMultiple(of: 4) else { return nil }
            var padding = 0
            while padding < 2, text.count > padding, text[text.count - 1 - padding] == UInt8(ascii: "=") { padding += 1 }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.count / 4 * 3)
            var accumulator: UInt32 = 0
            var bits = 0
            for character in text.dropLast(padding) {
                guard let value = value(of: character) else { return nil }
                accumulator = accumulator << 6 | UInt32(value)
                bits += 6
                if bits >= 8 {
                    bits -= 8
                    bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                    accumulator &= (1 << UInt32(bits)) - 1
                }
            }
            guard accumulator == 0 else { return nil }
            return bytes
        }

        private static func value(of character: UInt8) -> UInt8? {
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): character - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): character - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0") + 52
            case UInt8(ascii: "+"): 62
            case UInt8(ascii: "/"): 63
            default: nil
            }
        }
    }
}
