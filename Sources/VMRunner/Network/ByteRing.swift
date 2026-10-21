/// A fixed-capacity FIFO of bytes that never reallocates: socket reads land directly in its free space, and
/// segments are copied out of it by offset (for retransmission the bytes stay until acknowledged).
@safe
final class ByteRing {
    private let storage: RawBuffer
    let capacity: Int
    private var head = 0
    /// Bytes currently held.
    private(set) var count = 0

    init(capacity: Int) {
        storage = RawBuffer(capacity: capacity)
        self.capacity = storage.capacity
    }

    var freeSpace: Int { capacity - count }
    var isEmpty: Bool { count < 1 }

    /// The largest contiguous run of free space at the tail (to read a socket into); call ``commit(_:)`` after.
    func writableRegion() -> MutableByteView {
        let tail = (head + count) % capacity
        let length = min(freeSpace, capacity - tail)
        return storage.mutableView.slice(from: tail, length: length) ?? .empty
    }

    /// Marks `length` bytes of the region last returned by ``writableRegion()`` as filled.
    func commit(_ length: Int) {
        count += min(max(length, 0), freeSpace)
    }

    /// Copies `bytes` to the tail. All or nothing: returns `false` (storing nothing) when they do not fit.
    func append(_ bytes: ByteView) -> Bool {
        guard bytes.count <= freeSpace else { return false }
        var done = 0
        while done < bytes.count {
            let region = writableRegion()
            let piece = min(region.count, bytes.count - done)
            guard piece > 0, let chunk = bytes.slice(from: done, length: piece), region.copy(chunk, to: 0) else { return false }
            commit(piece)
            done += piece
        }
        return true
    }

    /// Up to `limit` bytes starting `offset` bytes after the head, as one contiguous view. Shorter than `limit`
    /// when the run wraps around the end of the storage; call again at `offset + view.count` for the rest.
    func contiguous(from offset: Int, limit: Int) -> ByteView {
        guard offset >= 0, offset < count, limit > 0 else { return .empty }
        let start = (head + offset) % capacity
        let length = min(limit, count - offset, capacity - start)
        return storage.mutableView.readable.slice(from: start, length: length) ?? .empty
    }

    /// Drops `length` bytes from the head.
    func discard(_ length: Int) {
        let dropped = min(max(length, 0), count)
        head = (head + dropped) % capacity
        count -= dropped
        if isEmpty { head = 0 }
    }

    func removeAll() {
        head = 0
        count = 0
    }
}

/// Recycles rings so flow churn does not allocate: a flow takes one when it first needs buffering and gives it
/// back when the buffer drains or the flow ends. At most `maxIdle` rings are kept.
final class RingPool {
    private let ringCapacity: Int
    private let maxIdle: Int
    private var idle: [ByteRing] = []

    init(ringCapacity: Int, maxIdle: Int = 64) {
        self.ringCapacity = ringCapacity
        self.maxIdle = maxIdle
        idle.reserveCapacity(maxIdle)
    }

    func acquire() -> ByteRing {
        idle.popLast() ?? ByteRing(capacity: ringCapacity)
    }

    func release(_ ring: ByteRing) {
        ring.removeAll()
        if idle.count < maxIdle { idle.append(ring) }
    }
}
