/// A first-in, first-out byte buffer of fixed capacity. It never grows: a producer either takes what fits
/// (``append(_:)``) or lets the oldest bytes go (``appendDroppingOldest(_:)``), so memory is bounded whatever the peers do.
struct ByteFIFO {
    private var storage: [UInt8]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        let size = max(capacity, 1)
        storage = [UInt8](repeating: 0, count: size)
        self.capacity = size
    }

    var free: Int { capacity - count }
    var isEmpty: Bool { count < 1 }

    /// Stores as much of `bytes` as fits and returns how many it took.
    @discardableResult
    mutating func append(_ bytes: ArraySlice<UInt8>) -> Int {
        let taken = min(bytes.count, free)
        guard taken > 0 else { return 0 }
        let tail = (head + count) % capacity
        let firstRun = min(taken, capacity - tail)
        storage.replaceSubrange(tail..<(tail + firstRun), with: bytes.prefix(firstRun))
        if taken > firstRun {
            let rest = bytes.dropFirst(firstRun).prefix(taken - firstRun)
            storage.replaceSubrange(0..<rest.count, with: rest)
        }
        count += taken
        return taken
    }

    /// Stores all of `bytes`; room is made by discarding the oldest bytes. Returns how many bytes were discarded
    /// (older ones, or the front of `bytes` itself when it is larger than the capacity).
    @discardableResult
    mutating func appendDroppingOldest(_ bytes: ArraySlice<UInt8>) -> Int {
        if bytes.count >= capacity {
            let dropped = count + bytes.count - capacity
            removeAll()
            append(bytes.suffix(capacity))
            return dropped
        }
        let dropped = max(bytes.count - free, 0)
        discardFront(dropped)
        append(bytes)
        return dropped
    }

    /// Every byte held, oldest first.
    func contents() -> [UInt8] {
        let firstRun = min(count, capacity - head)
        return Array(storage[head..<(head + firstRun)]) + storage[0..<(count - firstRun)]
    }

    /// Writes the longest run of bytes at the front that is contiguous in memory (nothing when empty) to `descriptor`.
    func writeFront(to descriptor: Int32) -> TransferResult {
        let run = min(count, capacity - head)
        return storage.withUnsafeBytes { raw in
            // The run lies inside `storage`: `head + run <= capacity`.
            unsafe ConsoleSocket.write(descriptor, UnsafeRawBufferPointer(rebasing: raw[head..<(head + run)]))
        }
    }

    mutating func discardFront(_ length: Int) {
        let dropped = min(max(length, 0), count)
        head = (head + dropped) % capacity
        count -= dropped
        if isEmpty { head = 0 }
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}
