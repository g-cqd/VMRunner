/// A cursor over a copy of guest bytes that reads little-endian integers and returns `nil` instead of reading past the end.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The bytes not read yet.
    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
        offset += 4
        return value
    }

    mutating func u64() -> UInt64? {
        guard let low = u32(), let high = u32() else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    /// Moves past `count` bytes; `false`, and no move, when fewer remain.
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }
}

/// Appends little-endian integers to a byte array, for the device's answers.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func u32(_ value: UInt32) {
        for index in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value))
        u32(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func zeros(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }
}
