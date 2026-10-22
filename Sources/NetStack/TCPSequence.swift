/// Modular comparisons of 32-bit TCP sequence numbers (RFC 793: "a is before b" within half the space).
enum TCPSequence {
    static func lessThan(_ lhs: UInt32, _ rhs: UInt32) -> Bool { Int32(bitPattern: lhs &- rhs) < 0 }
    static func lessOrEqual(_ lhs: UInt32, _ rhs: UInt32) -> Bool { Int32(bitPattern: lhs &- rhs) <= 0 }
    static func greaterThan(_ lhs: UInt32, _ rhs: UInt32) -> Bool { Int32(bitPattern: lhs &- rhs) > 0 }

    /// Signed distance `to - from` (positive when `to` is ahead).
    static func distance(from: UInt32, to: UInt32) -> Int { Int(Int32(bitPattern: to &- from)) }
}
