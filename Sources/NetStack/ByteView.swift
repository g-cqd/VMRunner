import Foundation

/// Whether `[offset, offset + length)` lies inside `[0, count)` (written so it cannot overflow).
private func window(_ offset: Int, _ length: Int, fitsIn count: Int) -> Bool {
    offset >= 0 && length >= 0 && offset <= count && length <= count - offset
}

/// Why a wire structure could not be read or accepted. Parsers are typed-throws (`throws(PacketError)`) so the
/// error path never boxes an existential and never allocates.
enum PacketError: Error, Hashable, Sendable {
    /// Fewer bytes than the structure needs.
    case truncated
    /// Internally inconsistent (bad length field, impossible header size, version mismatch...).
    case malformed
    /// A checksum did not verify.
    case checksum
    /// Well formed but outside what this stack handles (IPv6, VLAN tags, ...).
    case unsupported
}

/// A read-only window onto bytes owned by somebody else: a receive buffer, a ring, a test array.
///
/// This is the packet path's replacement for `[UInt8]` and `ArraySlice`: creating, slicing and reading a view
/// never allocates and never copies. All reads are bounds-checked here, so the packet parsers built on top of it are
/// ordinary safe Swift; the one unsafe fact (the memory is alive) is stated, not hidden:
///
/// - **A view is only valid while the owner of the memory is.** Never store one beyond the call that received it.
///   Parsed headers keep their payload as a view, so they are scoped the same way.
@safe
struct ByteView {
    @unsafe fileprivate let base: UnsafeRawPointer?
    /// Number of readable bytes.
    let count: Int

    /// A view of nothing.
    static var empty: Self { unsafe Self(base: nil, count: 0) }

    /// Wraps raw memory. The caller guarantees `bytes` stays valid for as long as the view (and anything cut
    /// from it) is used.
    @unsafe
    init(unsafeBytes bytes: UnsafeRawBufferPointer) {
        unsafe self.base = bytes.baseAddress
        self.count = bytes.count
    }

    private init(base: UnsafeRawPointer?, count: Int) {
        unsafe self.base = base
        self.count = count
    }

    var isEmpty: Bool { count < 1 }

    /// Runs `body` with a view of `array`'s storage; the view must not escape `body`.
    @discardableResult
    static func withBytes<R, E: Error>(of array: [UInt8], _ body: (Self) throws(E) -> R) throws(E) -> R {
        // Safe: the view's lifetime is bounded by `withUnsafeBytes`, and `body` must not keep it.
        let outcome: Result<R, E> = array.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Result<R, E> in
            do throws(E) {
                return .success(try body(unsafe Self(unsafeBytes: raw)))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// The sub-window `[offset, offset + length)`, or `nil` when it does not fit.
    func slice(from offset: Int, length: Int) -> Self? {
        guard window(offset, length, fitsIn: count) else { return nil }
        // Pointer arithmetic stays inside the checked bounds above.
        guard let base = unsafe base else { return .empty }
        return unsafe Self(base: base + offset, count: length)
    }

    /// The sub-window from `offset` to the end, or `nil` when `offset` is out of range.
    func suffix(from offset: Int) -> Self? {
        slice(from: offset, length: count - offset)
    }

    /// The first `length` bytes (all of them if the view is shorter).
    func prefix(_ length: Int) -> Self {
        slice(from: 0, length: min(max(length, 0), count)) ?? .empty
    }

    subscript(offset: Int) -> UInt8? {
        guard offset >= 0, offset < count, let base = unsafe base else { return nil }
        // In bounds by the guard above.
        return unsafe base.load(fromByteOffset: offset, as: UInt8.self)
    }

    /// One byte; `throws(.truncated)` past the end.
    func u8(at offset: Int) throws(PacketError) -> UInt8 {
        guard let byte = self[offset] else { throw .truncated }
        return byte
    }

    /// A big-endian (network order) 16-bit integer.
    func be16(at offset: Int) throws(PacketError) -> UInt16 {
        guard offset >= 0, offset <= count - 2, let base = unsafe base else { throw .truncated }
        // In bounds by the guard above; `loadUnaligned` because headers are not aligned.
        return UInt16(bigEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    /// A big-endian 32-bit integer.
    func be32(at offset: Int) throws(PacketError) -> UInt32 {
        guard offset >= 0, offset <= count - 4, let base = unsafe base else { throw .truncated }
        // In bounds by the guard above.
        return UInt32(bigEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// A big-endian 48-bit integer (a MAC address).
    func be48(at offset: Int) throws(PacketError) -> UInt64 {
        (UInt64(try be16(at: offset)) << 32) | UInt64(try be32(at: offset + 2))
    }

    /// The unfolded ones'-complement sum of the bytes read as network-order 16-bit words (an odd last byte is
    /// padded with zero). Fold and complement it with ``InternetChecksum/finish(_:)``.
    func onesComplementSum() -> UInt64 {
        guard !isEmpty, let base = unsafe base else { return 0 }
        var sum: UInt64 = 0
        var offset = 0
        while offset <= count - 8 {
            // In bounds: `offset + 8 <= count`.
            let word = UInt64(bigEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            // Two 32-bit halves, each a pair of network-order words; the carries fold in `finish`.
            sum &+= (word >> 32) &+ (word & 0xFFFF_FFFF)
            offset += 8
        }
        while offset <= count - 2 {
            // In bounds: `offset + 2 <= count`.
            sum &+= UInt64(UInt16(bigEndian: unsafe base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            offset += 2
        }
        if offset < count {
            // The odd trailing byte is the high half of a zero-padded word.
            sum &+= UInt64(unsafe base.load(fromByteOffset: offset, as: UInt8.self)) << 8
        }
        return sum
    }

    /// A copy of the bytes. Allocates; for tests, logging and the (rare) paths that need to keep data.
    func array() -> [UInt8] {
        guard !isEmpty, let base = unsafe base else { return [] }
        // `count` bytes are readable from `base`.
        return unsafe Array(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Calls `body` for the raw bytes; used by the few wrappers that hand memory to the kernel.
    func withUnsafeBytes<R, E: Error>(_ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
        try unsafe body(UnsafeRawBufferPointer(start: base, count: count))
    }
}

/// A writable window onto bytes owned by somebody else, with the same validity rule as ``ByteView``.
@safe
struct MutableByteView {
    @unsafe private let base: UnsafeMutableRawPointer?
    let count: Int

    /// A view of nothing.
    static var empty: Self { unsafe Self(base: nil, count: 0) }

    /// Wraps raw memory; the caller guarantees it outlives every use.
    @unsafe
    init(unsafeBytes bytes: UnsafeMutableRawBufferPointer) {
        unsafe self.base = bytes.baseAddress
        self.count = bytes.count
    }

    private init(base: UnsafeMutableRawPointer?, count: Int) {
        unsafe self.base = base
        self.count = count
    }

    var isEmpty: Bool { count < 1 }

    /// A read-only view of the same bytes.
    var readable: ByteView {
        unsafe ByteView(unsafeBytes: UnsafeRawBufferPointer(start: base, count: count))
    }

    func slice(from offset: Int, length: Int) -> Self? {
        guard let part = readable.slice(from: offset, length: length) else { return nil }
        // The bytes came from this view's own mutable memory, so handing back mutable access to them is sound.
        return unsafe Self(base: UnsafeMutableRawPointer(mutating: part.base), count: part.count)
    }

    /// Stores one byte; returns `false` (and stores nothing) when out of range.
    @discardableResult
    func store(_ value: UInt8, at offset: Int) -> Bool {
        guard offset >= 0, offset < count, let base = unsafe base else { return false }
        // In bounds by the guard above.
        unsafe base.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
        return true
    }

    @discardableResult
    func storeBE16(_ value: UInt16, at offset: Int) -> Bool {
        guard offset >= 0, offset <= count - 2, let base = unsafe base else { return false }
        // In bounds by the guard above.
        unsafe base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt16.self)
        return true
    }

    @discardableResult
    func storeBE32(_ value: UInt32, at offset: Int) -> Bool {
        guard offset >= 0, offset <= count - 4, let base = unsafe base else { return false }
        // In bounds by the guard above.
        unsafe base.storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self)
        return true
    }

    /// Copies `source` to `offset`; returns `false` (copying nothing) when it does not fit.
    @discardableResult
    func copy(_ source: ByteView, to offset: Int) -> Bool {
        guard offset >= 0, offset <= count, source.count <= count - offset else { return false }
        guard !source.isEmpty, let base = unsafe base else { return true }
        unsafe source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // Destination range checked above; `memmove` tolerates the rare overlap of a ring copied onto itself.
            if let from = raw.baseAddress { unsafe memmove(base + offset, from, raw.count) }
        }
        return true
    }

    /// Sets `length` bytes from `offset` to `value`.
    func fill(_ value: UInt8, from offset: Int, length: Int) {
        guard offset >= 0, length > 0, offset <= count, length <= count - offset, let base = unsafe base else { return }
        // Range checked above.
        unsafe memset(base + offset, Int32(value), length)
    }

    /// Calls `body` with the raw bytes; used by the few wrappers that let the kernel fill memory.
    func withUnsafeMutableBytes<R, E: Error>(_ body: (UnsafeMutableRawBufferPointer) throws(E) -> R) throws(E) -> R {
        try unsafe body(UnsafeMutableRawBufferPointer(start: base, count: count))
    }
}

/// Owned, fixed-size memory that views are cut from. The buffer is zero-initialized once and never resized.
@safe
final class RawBuffer {
    @unsafe private let storage: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int) {
        let size = max(capacity, 1)
        // Allocated here, freed in deinit; zeroed so views never expose uninitialized memory.
        unsafe storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        unsafe storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        self.capacity = size
    }

    deinit {
        // Matches the allocation in `init`.
        unsafe storage.deallocate()
    }

    /// A writable view of the whole buffer. Valid while this object is alive.
    var mutableView: MutableByteView {
        unsafe MutableByteView(unsafeBytes: UnsafeMutableRawBufferPointer(start: storage, count: capacity))
    }

    /// A read-only view of the first `length` bytes. Valid while this object is alive.
    func view(length: Int) -> ByteView {
        mutableView.readable.prefix(length)
    }
}
