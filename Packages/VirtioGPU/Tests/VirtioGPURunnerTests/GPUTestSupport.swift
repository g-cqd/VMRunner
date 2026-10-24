@testable import VirtioGPURunnerCore

/// A small deterministic generator (SplitMix64), so a random test fails the same way on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The bytes of a request: a header, then each field as a little-endian 32-bit word, then `tail`.
func request(
    _ type: UInt32, flags: UInt32 = 0, fence: UInt64 = 0, context: UInt32 = 0, ring: UInt8 = 0, words: [UInt32] = [],
    tail: [UInt8] = []
) -> [UInt8] {
    var writer = ByteWriter(capacity: 64)
    writer.u32(type)
    writer.u32(flags)
    writer.u64(fence)
    writer.u32(context)
    writer.u8(ring)
    writer.zeros(3)
    for word in words { writer.u32(word) }
    return writer.bytes + tail
}

func request(_ type: GPUCommandType, words: [UInt32] = [], tail: [UInt8] = []) -> [UInt8] {
    request(type.rawValue, words: words, tail: tail)
}

/// Memory entries as an attach-backing request carries them.
func entryBytes(_ entries: [(address: UInt64, length: UInt32)]) -> [UInt8] {
    var writer = ByteWriter(capacity: entries.count * 16)
    for entry in entries {
        writer.u64(entry.address)
        writer.u32(entry.length)
        writer.u32(0)
    }
    return writer.bytes
}

/// A transfer request: rectangle, 64-bit offset, resource.
func transfer(_ rect: GPURect, offset: UInt64, resource: UInt32) -> [UInt8] {
    let words = [
        rect.x, rect.y, rect.width, rect.height, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), resource, 0,
    ]
    return request(.transferToHost2D, words: words)
}

/// Reads the little-endian word at `offset` of an answer.
func word(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
}
