/// The Internet checksum (RFC 1071): the complement of the folded ones'-complement sum of 16-bit words.
enum InternetChecksum {
    /// Folds carries into 16 bits and complements. A value of `0` over a block that includes its own checksum
    /// field means the block is intact.
    static func finish(_ sum: UInt64) -> UInt16 {
        var folded = sum
        while folded > 0xFFFF { folded = (folded & 0xFFFF) &+ (folded >> 16) }
        return ~UInt16(truncatingIfNeeded: folded)
    }

    /// The checksum of `bytes` alone.
    static func checksum(_ bytes: ByteView) -> UInt16 {
        finish(bytes.onesComplementSum())
    }

    /// The pseudo-header contribution for TCP and UDP over IPv4 (RFC 793 section 3.1).
    static func pseudoHeaderSum(source: UInt32, destination: UInt32, proto: UInt8, length: Int) -> UInt64 {
        UInt64(source >> 16) &+ UInt64(source & 0xFFFF) &+ UInt64(destination >> 16) &+ UInt64(destination & 0xFFFF)
            &+ UInt64(proto) &+ UInt64(length)
    }
}
