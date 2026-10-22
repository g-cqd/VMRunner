/// Sequential big-endian writer into a fixed buffer, used to assemble every frame the stack sends.
///
/// Writing past the end never traps and never writes: it sets ``overflowed``, and the caller discards the frame.
/// Frame buffers are sized for the configured MTU, so overflow indicates a logic error, not an input problem.
@safe
struct FrameWriter {
    private let target: MutableByteView
    /// Bytes written so far.
    private(set) var count = 0
    /// Whether a write did not fit.
    private(set) var overflowed = false

    init(_ target: MutableByteView) {
        self.target = target
    }

    /// Everything written so far.
    var written: ByteView {
        target.readable.prefix(count)
    }

    mutating func u8(_ value: UInt8) {
        record(target.store(value, at: count), advance: 1)
    }

    mutating func be16(_ value: UInt16) {
        record(target.storeBE16(value, at: count), advance: 2)
    }

    mutating func be32(_ value: UInt32) {
        record(target.storeBE32(value, at: count), advance: 4)
    }

    /// A 48-bit big-endian value (MAC address).
    mutating func be48(_ value: UInt64) {
        be16(UInt16(truncatingIfNeeded: value >> 32))
        be32(UInt32(truncatingIfNeeded: value))
    }

    mutating func bytes(_ view: ByteView) {
        record(target.copy(view, to: count), advance: view.count)
    }

    mutating func zeros(_ length: Int) {
        guard length >= 0, length <= target.count - count else {
            overflowed = true
            return
        }
        target.fill(0, from: count, length: length)
        count += length
    }

    /// Overwrites two bytes already written at `offset`.
    mutating func patchBE16(_ value: UInt16, at offset: Int) {
        guard offset >= 0, offset + 2 <= count else {
            overflowed = true
            return
        }
        target.storeBE16(value, at: offset)
    }

    /// The ones'-complement sum of the bytes from `start` to the current end.
    func sum(from start: Int) -> UInt64 {
        target.readable.slice(from: start, length: count - start)?.onesComplementSum() ?? 0
    }

    private mutating func record(_ ok: Bool, advance: Int) {
        if ok { count += advance } else { overflowed = true }
    }
}
